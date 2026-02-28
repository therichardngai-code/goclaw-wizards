#!/usr/bin/env bash
# lib/stack.sh — GoClaw stack lifecycle: clone, .env, health, warmup, state.json
# Depends on: colors.sh, compose.sh, secrets.sh, ports.sh

WIZARD_HOME="${WIZARD_HOME:-${HOME}/.goclaw-wizard}"

stack_dir()      { echo "${WIZARD_HOME}/stacks/$1"; }
stack_env_file() { echo "${WIZARD_HOME}/stacks/$1/.env"; }

# --- Clone or Update GoClaw source (shallow) ---
stack_clone_or_pull() {
  local goclaw_dir; goclaw_dir="$(stack_dir "$1")/goclaw"
  if [[ -d "${goclaw_dir}/.git" ]]; then
    git -C "$goclaw_dir" pull --ff-only
  else
    mkdir -p "$(stack_dir "$1")"
    git clone --depth 1 "$GOCLAW_REPO_URL" "$goclaw_dir"
  fi
}

# --- Generate ephemeral .env for docker compose ---
# Reads exported shell vars: GOCLAW_GATEWAY_TOKEN, GOCLAW_ENCRYPTION_KEY,
# POSTGRES_PASSWORD, PORT_API/UI/PG/JAEGER, PROVIDER, API_KEY, MODEL,
# MODE, FEATURES, OWNER_IDS, CUSTOM_BASE_URL, TS_AUTH_KEY, TS_HOSTNAME
# Returns: path to generated .env (chmod 600)
stack_generate_env() {
  local stack="$1"
  local env_file; env_file=$(stack_env_file "$stack")
  mkdir -p "$(dirname "$env_file")"
  local prov_up; prov_up=$(echo "${PROVIDER:-custom}" | tr '[:lower:]' '[:upper:]')

  {
    echo "# GoClaw stack: ${stack} — $(date -u +%Y-%m-%dT%H:%M:%SZ) (ephemeral)"
    echo "GOCLAW_GATEWAY_TOKEN=${GOCLAW_GATEWAY_TOKEN:-}"
    echo "GOCLAW_ENCRYPTION_KEY=${GOCLAW_ENCRYPTION_KEY:-}"
    echo "GOCLAW_MODE=${MODE:-managed}"
    echo "GOCLAW_PORT=${PORT_API:-18790}"
    echo "GOCLAW_HOST=0.0.0.0"
    echo "GOCLAW_${prov_up}_API_KEY=${API_KEY:-}"
    echo "GOCLAW_MODEL=${MODEL:-default}"
    echo "GOCLAW_API_PORT=${PORT_API:-18790}"
    echo "GOCLAW_UI_PORT=${PORT_UI:-3000}"
    echo "GOCLAW_PG_PORT=${PORT_PG:-5432}"
    echo "GOCLAW_JAEGER_PORT=${PORT_JAEGER:-16686}"
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-}"
    echo "POSTGRES_PORT=${PORT_PG:-5432}"
    echo "GOCLAW_OWNER_IDS=${OWNER_IDS:-}"
    [[ -n "${CUSTOM_BASE_URL:-}" ]] && echo "GOCLAW_${prov_up}_BASE_URL=${CUSTOM_BASE_URL}"
    [[ -n "${TS_AUTH_KEY:-}" ]]     && echo "TAILSCALE_AUTHKEY=${TS_AUTH_KEY}"
    [[ -n "${TS_HOSTNAME:-}" ]]     && echo "TAILSCALE_HOSTNAME=${TS_HOSTNAME}"
  } > "$env_file"

  chmod 600 "$env_file"
  echo "$env_file"
}

# --- Delete ephemeral .env (call via EXIT trap) ---
stack_cleanup_env() {
  rm -f "$(stack_env_file "$1")"
}

# --- Health check: poll GET /health ---
# stack_health_check <stack> <port> [retries:20] [interval:5]
# Returns 0 on success, 1 on timeout or crashed container.
stack_health_check() {
  local stack="$1" port="$2" retries="${3:-20}" interval="${4:-5}"
  local i
  for (( i=1; i<=retries; i++ )); do
    curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
    local st; st=$(docker inspect "goclaw-${stack}-goclaw-1" \
      --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$st" =~ exited|dead ]]; then
      # Write directly to fd 2 — avoids spinner \r overwrite of print_error
      printf "\n  \033[0;31m✗\033[0m  Container goclaw-%s-goclaw-1 exited. Last logs:\n" "$stack" >&2
      docker logs --tail 20 "goclaw-${stack}-goclaw-1" 2>&1 | sed 's/^/  │  /' >&2 || true
      return 1
    fi
    sleep "$interval"
  done
  return 1
}

# --- LLM warmup: POST /v1/chat/completions (non-fatal) ---
stack_warmup_llm() {
  local port="$2" token="$3" i
  for (( i=1; i<=5; i++ )); do
    curl -sf --max-time 30 \
      -X POST "http://127.0.0.1:${port}/v1/chat/completions" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d '{"model":"default","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}' \
      >/dev/null 2>&1 && return 0
    sleep 10
  done
  print_warn "LLM warmup timed out — gateway may need more time."
  return 1
}

# --- State JSON R/W ---
state_read()      { local f; f="$(stack_dir "$1")/state.json"; [[ -f "$f" ]] && cat "$f" || echo "{}"; }
state_write()     { local d; d="$(stack_dir "$1")"; mkdir -p "$d"; echo "$2" > "${d}/state.json"; chmod 600 "${d}/state.json"; }
state_get_field() { state_read "$1" | python3 -c "import sys,json; print(json.load(sys.stdin).get('${2}',''))" 2>/dev/null; }

# state_update_agents <stack> <agent_json_object_string>
# Upserts agent (by key) into agents[] array in state.json.
state_update_agents() {
  local stack="$1" agent_json="$2"
  local updated
  updated=$(state_read "$stack" | python3 -c "
import sys, json
state = json.load(sys.stdin)
new = json.loads(sys.argv[1])
agents = [a for a in state.get('agents', []) if a.get('key') != new.get('key')]
agents.append(new)
state['agents'] = agents
print(json.dumps(state, indent=2))
" "$agent_json" 2>/dev/null)
  [[ -n "$updated" ]] && state_write "$stack" "$updated"
}

# state_remove_agent <stack> <agent_key>
state_remove_agent() {
  local updated
  updated=$(state_read "$1" | python3 -c "
import sys, json
state = json.load(sys.stdin)
state['agents'] = [a for a in state.get('agents', []) if a.get('key') != sys.argv[1]]
print(json.dumps(state, indent=2))
" "$2" 2>/dev/null)
  [[ -n "$updated" ]] && state_write "$1" "$updated"
}

# --- Build initial state.json string ---
# Uses exported vars: STACK, MODE, FEATURES, PORT_BLOCK, PORT_API/UI/PG/JAEGER
build_state_json() {
  local ver; ver=$(git -C "$(stack_dir "${STACK:-default}")/goclaw" describe --tags --always 2>/dev/null || echo "latest")
  python3 -c "
import json, datetime
print(json.dumps({
  'stack':        '${STACK:-default}',
  'version':      '${ver}',
  'mode':         '${MODE:-managed}',
  'features':     [x for x in '${FEATURES:-}'.split(',') if x],
  'port_block':   ${PORT_BLOCK:-0},
  'ports':        {'api': ${PORT_API:-18790}, 'ui': ${PORT_UI:-3000},
                   'pg': ${PORT_PG:-5432}, 'jaeger': ${PORT_JAEGER:-16686}},
  'agents':       [],
  'installed_at': datetime.datetime.utcnow().isoformat() + 'Z'
}, indent=2))
"
}
