#!/usr/bin/env bash
# lib/doctor.sh — Stack health diagnostics: 7 check categories, --repair mode
# Sourced lazily by wizard.sh when `doctor` command is used.
# Depends on: colors.sh, stack.sh, secrets.sh, compose.sh, ports.sh, commands.sh (_load_stack_state)

DOCTOR_WARNINGS=0
DOCTOR_ERRORS=0
DOCTOR_LOG="${WIZARD_HOME:-${HOME}/.goclaw-wizard}/wizard.log"

# ── Output helper: pass|fail|warn|info|skip ───────────────────────────────────
doctor_check() {
  local status="$1" msg="$2" hint="${3:-}"
  case "$status" in
    pass) printf "  ${GREEN}✔${NC}  %s\n"          "$msg" ;;
    fail) printf "  ${RED}✗${NC}  %s\n"            "$msg"
          [[ -n "$hint" ]] && printf "    ${DIM}→ hint: %s${NC}\n" "$hint"
          (( DOCTOR_ERRORS++ )) ;;
    warn) printf "  ${YELLOW}⚠${NC}  %s\n"         "$msg"
          [[ -n "$hint" ]] && printf "    ${DIM}→ %s${NC}\n"       "$hint"
          (( DOCTOR_WARNINGS++ )) ;;
    info) printf "  ${CYAN}ℹ${NC}  %s\n"           "$msg" ;;
    skip) printf "  ${DIM}-  %s (skipped)${NC}\n"  "$msg" ;;
  esac
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${status}: ${msg}${hint:+ | hint: $hint}" >> "$DOCTOR_LOG"
}

# ── Repair helper ─────────────────────────────────────────────────────────────
doctor_repair() {
  local desc="$1" cmd="$2"
  [[ "$DOCTOR_REPAIR" != "true" ]] && return
  if [[ "$DOCTOR_YES" == "true" ]]; then
    eval "$cmd" && doctor_check pass "[repaired] ${desc}"
  else
    local ok; prompt_confirm ok "[repair] ${desc}?" true
    [[ "$ok" == "true" ]] && eval "$cmd" && doctor_check pass "[repaired] ${desc}"
  fi
}

# ── 1. Config & Secrets ───────────────────────────────────────────────────────
doctor_config_secrets() {
  local stack="$1" stack_d; stack_d=$(stack_dir "$stack")
  printf "\n  ${BOLD}Config & Secrets${NC}\n"

  local sf="${stack_d}/.secrets"
  if [[ ! -f "$sf" ]]; then
    doctor_check fail ".secrets missing" "re-run: bash wizard.sh install --name ${stack}"; return
  fi
  doctor_check pass ".secrets exists"

  local perms; perms=$(stat -c '%a' "$sf" 2>/dev/null || stat -f '%Lp' "$sf" 2>/dev/null || echo "?")
  if [[ "$perms" == "600" ]]; then
    doctor_check pass ".secrets permissions = 600"
  else
    doctor_check fail ".secrets permissions = ${perms}" "expected 600"
    doctor_repair "chmod 600 .secrets" "chmod 600 '${sf}'"
  fi

  # Source to check key lengths (same as secrets_load but in-place)
  local GOCLAW_GATEWAY_TOKEN="" GOCLAW_ENCRYPTION_KEY="" POSTGRES_PASSWORD=""
  # shellcheck source=/dev/null
  set -a; source "$sf" 2>/dev/null; set +a
  [[ ${#GOCLAW_GATEWAY_TOKEN} -eq 32 ]] && doctor_check pass "GATEWAY_TOKEN length = 32" || \
    doctor_check fail "GATEWAY_TOKEN length = ${#GOCLAW_GATEWAY_TOKEN}" "expected 32"
  [[ ${#GOCLAW_ENCRYPTION_KEY} -eq 64 ]] && doctor_check pass "ENCRYPTION_KEY length = 64" || \
    doctor_check fail "ENCRYPTION_KEY length = ${#GOCLAW_ENCRYPTION_KEY}" "expected 64"
  [[ -n "$POSTGRES_PASSWORD" ]] && doctor_check pass "POSTGRES_PASSWORD present" || \
    doctor_check fail "POSTGRES_PASSWORD missing" "re-run: bash wizard.sh install"
}

# ── 2. Services ───────────────────────────────────────────────────────────────
doctor_services() {
  local stack="$1"
  printf "\n  ${BOLD}Services${NC}\n"
  local svc_json; svc_json=$(compose_ps "$stack" "$_goclaw_dir" "$_mode" "$_features" 2>/dev/null) || {
    doctor_check skip "Cannot query services (stack not started?)"; return; }

  local parsed; parsed=$(echo "$svc_json" | python3 -c "
import sys, json
try: data = json.load(sys.stdin)
except: data = []
if not isinstance(data, list): data = []
for s in data:
    name  = s.get('Name', s.get('Service', '?'))
    state = s.get('State', s.get('Status', '?'))
    health= s.get('Health', '')
    ok    = 'pass' if state == 'running' else 'fail'
    hint  = 'check logs: wizard.sh logs' if ok == 'fail' else ''
    label = f'{name} {state}' + (f' ({health})' if health else '')
    print(f'{ok}|{label}|{hint}')
" 2>/dev/null)
  [[ -z "$parsed" ]] && { doctor_check skip "No services found or JSON not supported"; return; }
  while IFS='|' read -r st msg hint; do doctor_check "$st" "$msg" "$hint"; done <<< "$parsed"
}

# ── 3. Gateway Health ─────────────────────────────────────────────────────────
doctor_gateway() {
  local stack="$1" port="$2"
  printf "\n  ${BOLD}Gateway Health${NC}\n"

  local t0; t0=$(date +%s%3N 2>/dev/null || date +%s)
  if curl -sf --max-time 5 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    local t1; t1=$(date +%s%3N 2>/dev/null || date +%s)
    doctor_check pass "GET /health → 200 OK (${t1-$t0}ms)"
  else
    doctor_check fail "GET /health failed" "is the stack running? try: wizard.sh start --name ${stack}"
    return
  fi

  if curl -sf --max-time 10 -X POST "http://127.0.0.1:${port}/v1/chat/completions" \
    -H "Authorization: Bearer ${GOCLAW_GATEWAY_TOKEN:-}" -H "Content-Type: application/json" \
    -d '{"model":"default","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
    >/dev/null 2>&1; then
    doctor_check pass "LLM gateway reachable"
  else
    doctor_check warn "LLM /v1/chat/completions unreachable" "check API key configuration"
  fi

  timeout 3 bash -c "echo >/dev/tcp/127.0.0.1/${port}" 2>/dev/null && \
    doctor_check pass "WebSocket port ${port} connectable" || \
    doctor_check fail "WebSocket port ${port} not connectable"
}

# ── 4. Security ───────────────────────────────────────────────────────────────
doctor_security() {
  local stack="$1" port="$2"
  printf "\n  ${BOLD}Security${NC}\n"

  local ch_list; ch_list=$(python3 "${WIZARD_DIR}/scripts/provision-agent.py" \
    --action list-channels --port "$port" --token "${GOCLAW_GATEWAY_TOKEN:-}" 2>/dev/null) || {
    doctor_check skip "dm_policy check (gateway unreachable)"; ch_list=""; }

  if [[ -n "$ch_list" ]]; then
    local bad; bad=$(echo "$ch_list" | python3 -c "
import sys,json
try: data=json.load(sys.stdin)
except: data={}
bad=[c.get('name','?') for c in data.get('channels',[]) if c.get('config',{}).get('dm_policy')!='allowlist']
print(','.join(bad))" 2>/dev/null)
    [[ -z "$bad" ]] && doctor_check pass "dm_policy = allowlist on all channel instances" || \
      doctor_check fail "dm_policy not allowlist on: ${bad}"
  fi

  local sd; sd=$(stack_dir "$stack")
  local sp; sp=$(stat -c '%a' "${sd}/state.json" 2>/dev/null || stat -f '%Lp' "${sd}/state.json" 2>/dev/null || echo "?")
  [[ "$sp" == "600" ]] && doctor_check pass "state.json permissions = 600" || {
    doctor_check warn "state.json permissions = ${sp}" "expected 600"
    doctor_repair "chmod 600 state.json" "chmod 600 '${sd}/state.json'"; }

  if [[ -f "${sd}/.env" ]]; then
    doctor_check warn "Lingering .env found" "should be deleted after compose up"
    doctor_repair "remove stale .env" "rm -f '${sd}/.env'"
  else
    doctor_check pass "No lingering .env"
  fi
}

# ── 5. Agent Integrity ────────────────────────────────────────────────────────
doctor_agents() {
  local stack="$1"
  printf "\n  ${BOLD}Agent Integrity${NC}\n"
  local agents_base; agents_base="$(stack_dir "$stack")/agents"

  echo "$_state" | python3 -c "
import sys,json
for a in json.load(sys.stdin).get('agents',[]):
    print(f\"{a['key']}|{a['name']}|{','.join(a.get('channels',[]))}\")
" 2>/dev/null | while IFS='|' read -r key name channels; do
    local agent_d="${agents_base}/${key}"
    if [[ -f "${agent_d}/SOUL.md" && -f "${agent_d}/IDENTITY.md" ]]; then
      doctor_check pass "Agent '${name}' (${key}) — SOUL.md + IDENTITY.md seeded [${channels}]"
    else
      doctor_check fail "Agent '${name}' (${key}) — missing identity files" \
        "re-run: bash wizard.sh add-agent --name ${stack}"
    fi
  done
}

# ── 6. Versions ───────────────────────────────────────────────────────────────
doctor_versions() {
  local stack="$1"
  printf "\n  ${BOLD}Versions${NC}\n"

  local ver; ver=$(echo "$_state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
  doctor_check info "GoClaw: ${ver}"
  docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | \
    xargs -I{} doctor_check pass "Docker: {}" 2>/dev/null || doctor_check warn "Docker version undetected"
  python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 | \
    xargs -I{} doctor_check pass "Python: {}" 2>/dev/null || doctor_check warn "Python version undetected"

  local goclaw_d; goclaw_d="$(stack_dir "$stack")/goclaw"
  if [[ -f "${goclaw_d}/.git/FETCH_HEAD" ]]; then
    local mtime now days
    mtime=$(stat -c '%Y' "${goclaw_d}/.git/FETCH_HEAD" 2>/dev/null || stat -f '%m' "${goclaw_d}/.git/FETCH_HEAD" 2>/dev/null || echo 0)
    now=$(date +%s); days=$(( (now - mtime) / 86400 ))
    if [[ $days -gt 7 ]]; then
      doctor_check warn "GoClaw source: last pulled ${days}d ago" "run: wizard.sh upgrade --name ${stack}"
      doctor_repair "git pull GoClaw source" "git -C '${goclaw_d}' pull --ff-only"
    else
      doctor_check pass "GoClaw source: up to date (last pull ${days}d ago)"
    fi
  fi
}

# ── 7. Ports ─────────────────────────────────────────────────────────────────
doctor_ports() {
  local stack="$1"
  printf "\n  ${BOLD}Ports${NC}\n"

  local api_port; api_port=$(echo "$_state" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ports',{}).get('api','?'))" 2>/dev/null || echo "?")
  doctor_check info "Assigned API port: ${api_port}"

  local conflicts; conflicts=$(check_port_conflicts "$stack" 2>/dev/null || echo "")
  [[ -z "$conflicts" ]] && doctor_check pass "No port conflicts with other stacks" || \
    doctor_check fail "Port conflicts detected: ${conflicts}"
}

# ── Entry point ───────────────────────────────────────────────────────────────
doctor_run() {
  local stack="$1"
  DOCTOR_REPAIR="${2:-false}"; DOCTOR_YES="${3:-false}"
  DOCTOR_WARNINGS=0; DOCTOR_ERRORS=0

  mkdir -p "$(dirname "$DOCTOR_LOG")"
  : > "$DOCTOR_LOG"

  # Load state and secrets if stack exists
  STACK="$stack"
  if [[ -f "$(stack_dir "$stack")/state.json" ]]; then
    _load_stack_state
    secrets_load "$stack" 2>/dev/null || true
  else
    _state="{}"; _mode="managed"; _features=""; _goclaw_dir=""; _api_port=""
  fi

  doctor_config_secrets "$stack"
  if [[ -n "$_goclaw_dir" && -d "$_goclaw_dir" ]]; then
    doctor_services "$stack"
    [[ -n "$_api_port" ]] && doctor_gateway  "$stack" "$_api_port"
    [[ -n "$_api_port" ]] && doctor_security "$stack" "$_api_port"
  else
    doctor_check skip "Services (no stack deployed)"
    doctor_check skip "Gateway health (no stack deployed)"
    doctor_check skip "Security (no stack deployed)"
  fi
  doctor_agents   "$stack"
  doctor_versions "$stack"
  doctor_ports    "$stack"

  printf "\n  Summary: ${YELLOW}%d warnings${NC}, ${RED}%d errors${NC}\n" "$DOCTOR_WARNINGS" "$DOCTOR_ERRORS"
  [[ $DOCTOR_ERRORS -gt 0 && "$DOCTOR_REPAIR" != "true" ]] && \
    printf "  Run: ${BOLD}bash wizard.sh doctor --repair --name %s${NC}\n" "$stack"
  printf "\n"
}
