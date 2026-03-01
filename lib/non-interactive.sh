#!/usr/bin/env bash
# lib/non-interactive.sh — Non-TTY mode, --reset logic, status --all
# Provides: validate_non_interactive_args, map_flags_to_config,
#           non_interactive_install, cmd_status_all, pre_install_reset
# Depends on: flow-data.sh (PROVIDERS, PROVIDER_MODELS, index_of, derive_agent_key),
#             stack.sh, flows.sh (launch_stack, allocate_port_block, generate_stack_secrets)

# ── Validate --non-interactive flags ─────────────────────────────────────────
validate_non_interactive_args() {
  if [[ "$ACCEPT_RISK" != "true" ]]; then
    echo "Error: --accept-risk is required with --non-interactive" >&2; exit 1
  fi

  # Env var fallbacks for each flag
  : "${FLAG_PROVIDER:=${GOCLAW_PROVIDER:-}}"
  : "${FLAG_API_KEY:=${GOCLAW_API_KEY:-}}"
  if [[ -n "$FLAG_PROVIDER" && -z "$FLAG_API_KEY" ]]; then
    local _env_key="GOCLAW_$(echo "$FLAG_PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"
    : "${FLAG_API_KEY:=${!_env_key:-}}"
  fi
  : "${FLAG_TELEGRAM_TOKEN:=${GOCLAW_TELEGRAM_TOKEN:-}}"
  : "${FLAG_DISCORD_TOKEN:=${GOCLAW_DISCORD_TOKEN:-}}"
  : "${FLAG_LARK_APP_ID:=${GOCLAW_LARK_APP_ID:-}}"
  : "${FLAG_LARK_APP_SECRET:=${GOCLAW_LARK_APP_SECRET:-}}"
  : "${FLAG_ZALO_TOKEN:=${GOCLAW_ZALO_TOKEN:-}}"
  : "${FLAG_WHATSAPP_URL:=${GOCLAW_WHATSAPP_BRIDGE_URL:-}}"
  : "${FLAG_OWNER_IDS:=${GOCLAW_OWNER_IDS:-}}"
  : "${FLAG_CHANNELS:=${GOCLAW_CHANNELS:-}}"
  : "${FLAG_OWNER_NAME:=${GOCLAW_OWNER_NAME:-}}"
  : "${FLAG_OWNER_LANG:=${GOCLAW_OWNER_LANG:-}}"

  local missing=()
  [[ -z "${FLAG_PROVIDER:-}"    ]] && missing+=("--provider (or GOCLAW_PROVIDER)")
  [[ -z "${FLAG_API_KEY:-}"     ]] && missing+=("--api-key (or GOCLAW_{PROVIDER}_API_KEY)")
  [[ -z "${FLAG_CHANNELS:-}"    ]] && missing+=("--channels (comma-separated)")
  [[ -z "${FLAG_AGENT_NAME:-}"  ]] && missing+=("--agent-name")
  [[ -z "${FLAG_AGENT_PURPOSE:-}" ]] && missing+=("--agent-purpose")
  [[ -z "${FLAG_OWNER_IDS:-}"   ]] && missing+=("--owner-ids")

  # Per-channel credential checks
  local ch; IFS=',' read -ra _chs <<< "${FLAG_CHANNELS:-}"
  for ch in "${_chs[@]}"; do
    case "$ch" in
      telegram) [[ -z "${FLAG_TELEGRAM_TOKEN:-}" ]] && missing+=("--telegram-token") ;;
      discord)  [[ -z "${FLAG_DISCORD_TOKEN:-}"  ]] && missing+=("--discord-token") ;;
      lark)     [[ -z "${FLAG_LARK_APP_ID:-}"    ]] && missing+=("--lark-app-id")
                [[ -z "${FLAG_LARK_APP_SECRET:-}" ]] && missing+=("--lark-app-secret") ;;
      zalo)     [[ -z "${FLAG_ZALO_TOKEN:-}"     ]] && missing+=("--zalo-token") ;;
      whatsapp) [[ -z "${FLAG_WHATSAPP_URL:-}"   ]] && missing+=("--whatsapp-url") ;;
    esac
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required flags for --non-interactive:" >&2
    printf "  %s\n" "${missing[@]}" >&2; exit 1
  fi
}

# ── Map flags → config variables ──────────────────────────────────────────────
map_flags_to_config() {
  PROVIDER="$FLAG_PROVIDER"; API_KEY="$FLAG_API_KEY"
  local idx; idx=$(index_of "$PROVIDER" PROVIDERS 2>/dev/null || echo "0")
  MODEL="${FLAG_MODEL:-${PROVIDER_MODELS[$idx]:-default}}"
  AGENT_NAME="$FLAG_AGENT_NAME"; AGENT_PURPOSE="$FLAG_AGENT_PURPOSE"
  AGENT_PERSONALITY="${FLAG_AGENT_PERSONALITY:-}"; AGENT_LANGUAGE="English"
  AGENT_KEY=$(derive_agent_key "$AGENT_NAME")
  OWNER_IDS="$FLAG_OWNER_IDS"
  OWNER_NAME="${FLAG_OWNER_NAME:-}"
  OWNER_LANG="${FLAG_OWNER_LANG:-English}"
  [[ -n "${FLAG_GATEWAY_TOKEN:-}"  ]] && export GOCLAW_GATEWAY_TOKEN="$FLAG_GATEWAY_TOKEN"
  [[ -n "${FLAG_ENCRYPTION_KEY:-}" ]] && export GOCLAW_ENCRYPTION_KEY="$FLAG_ENCRYPTION_KEY"
  [[ -n "${FLAG_GATEWAY_PORT:-}"   ]] && PORT_API="$FLAG_GATEWAY_PORT"

  # Build CHANNELS_JSON safely via python3
  CHANNELS_JSON=$(python3 -c "
import json, sys
channels = sys.argv[1].split(',')
owner_ids = sys.argv[2].split(',')
flags = json.loads(sys.argv[3])
out = []
for ch in channels:
    entry = {'type': ch, 'owner_ids': owner_ids}
    if   ch == 'telegram': entry['credentials'] = {'token': flags['tt']}
    elif ch == 'discord':  entry['credentials'] = {'token': flags['dt']}
    elif ch == 'lark':     entry['credentials'] = {'app_id': flags['lai'], 'app_secret': flags['las']}
    elif ch == 'zalo':     entry['credentials'] = {'token': flags['zt']}
    elif ch == 'whatsapp': entry['credentials'] = {'bridge_url': flags['wu']}
    out.append(entry)
print(json.dumps(out))" \
    "$FLAG_CHANNELS" "$FLAG_OWNER_IDS" \
    "{\"tt\":\"${FLAG_TELEGRAM_TOKEN:-}\",\"dt\":\"${FLAG_DISCORD_TOKEN:-}\",\
\"lai\":\"${FLAG_LARK_APP_ID:-}\",\"las\":\"${FLAG_LARK_APP_SECRET:-}\",\
\"zt\":\"${FLAG_ZALO_TOKEN:-}\",\"wu\":\"${FLAG_WHATSAPP_URL:-}\"}" 2>/dev/null || echo "[]")
  export PROVIDER API_KEY MODEL AGENT_NAME AGENT_PURPOSE AGENT_PERSONALITY AGENT_KEY CHANNELS_JSON OWNER_NAME OWNER_LANG
}

# ── Non-interactive install (no prompts, JSON output) ─────────────────────────
non_interactive_install() {
  validate_non_interactive_args
  map_flags_to_config

  # Suppress interactive output; redirect progress to stderr
  prompt_progress() { local _m="$1"; shift; echo "$_m" >&2; "$@"; }
  prompt_outro()    { :; }

  detect_all
  check_all_deps || { echo '{"ok":false,"error":"missing dependencies"}'; exit 1; }

  secrets_exist "$STACK" && REUSE_SECRETS=true
  allocate_port_block "$STACK" || { echo '{"ok":false,"error":"port allocation failed"}'; exit 1; }

  [[ -n "${FLAG_GATEWAY_PORT:-}" ]] && PORT_API="$FLAG_GATEWAY_PORT"
  generate_stack_secrets "$STACK"
  export GOCLAW_GATEWAY_TOKEN GOCLAW_ENCRYPTION_KEY POSTGRES_PASSWORD

  launch_stack

  local ui_url=""
  [[ "$FEATURES" == *"ui"* ]] && ui_url="http://127.0.0.1:${PORT_UI}"
  printf '{"ok":true,"gateway_url":"http://127.0.0.1:%s","dashboard_url":"%s"}\n' "$PORT_API" "$ui_url"
}

# ── Status --all ──────────────────────────────────────────────────────────────
cmd_status_all() {
  printf "\n  ${BOLD}All GoClaw Stacks${NC}\n\n"
  printf "  %-16s %-10s %-7s %s\n" "STACK" "STATUS" "AGENTS" "GATEWAY"
  printf "  %-16s %-10s %-7s %s\n" "-----" "------" "------" "-------"

  local found=false
  for stack_d in "${WIZARD_HOME}"/stacks/*/; do
    [[ -d "$stack_d" ]] || continue; found=true
    local name; name=$(basename "$stack_d")
    local state; state=$(cat "${stack_d}/state.json" 2>/dev/null || echo "{}")
    local api agents
    api=$(echo "$state"    | python3 -c "import sys,json;print(json.load(sys.stdin).get('ports',{}).get('api','?'))" 2>/dev/null || echo "?")
    agents=$(echo "$state" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('agents',[])))"            2>/dev/null || echo "0")
    local status="stopped"
    docker compose --project-name "goclaw-${name}" ps --format json 2>/dev/null | \
      python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: d=[]
exit(0 if isinstance(d,list) and any(s.get('State')=='running' for s in d) else 1)" 2>/dev/null \
      && status="running"
    local sc="${RED}"; [[ "$status" == "running" ]] && sc="${GREEN}"
    printf "  %-16s ${sc}%-10s${NC} %-7s http://127.0.0.1:%s\n" "$name" "$status" "$agents" "$api"
  done
  [[ "$found" == "false" ]] && printf "  (no stacks installed)\n"
  printf "\n"
}

# ── Pre-install reset (replaces wizard.sh stub) ───────────────────────────────
pre_install_reset() {
  local stack="$1" scope="${RESET_SCOPE:-config}"
  local stack_d; stack_d=$(stack_dir "$stack")
  case "$scope" in
    config)
      rm -f "${stack_d}/.secrets" "${stack_d}/state.json"
      print_info "Reset [config]: secrets + state cleared" ;;
    config+sessions)
      rm -f "${stack_d}/.secrets" "${stack_d}/state.json"
      rm -rf "${stack_d}/agents/"
      print_info "Reset [config+sessions]: secrets, state + agent files cleared" ;;
    full)
      rm -rf "$stack_d"
      print_info "Reset [full]: stack directory removed" ;;
    *)
      print_error "Unknown --reset-scope '${scope}'. Use: config | config+sessions | full"; exit 1 ;;
  esac
}
