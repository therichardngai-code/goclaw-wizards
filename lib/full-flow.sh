#!/usr/bin/env bash
# lib/full-flow.sh — Full wizard flow: adds mode, features, personality, owner profile, port override
# Sourced lazily by flows.sh::full_flow() which calls run_full_flow().
# Depends on: flows.sh (preflight, step_provider, step_channels, confirm_summary, launch_stack)
#             flow-data.sh, wizard-ui.sh, ports.sh, secrets.sh

# ── Mode selection ────────────────────────────────────────────────────────────
step_mode() {
  local opts=("Managed (recommended)" "Standalone")
  local hints=("PostgreSQL + all features available" "File storage, basic features only")
  local selected; prompt_select selected "Deployment mode" opts hints
  if [[ "$selected" == "Standalone"* ]]; then
    MODE="standalone"; FEATURES=""
    print_info "Standalone mode: optional features not available"
  else
    MODE="managed"
  fi
}

# ── Feature selection (managed only) ─────────────────────────────────────────
step_features() {
  [[ "$MODE" != "managed" ]] && return
  local flabels=("Dashboard" "Observability" "Sandbox" "Tailscale")
  local fhints=("React dashboard (port ${PORT_UI:-3000})"
                "Jaeger tracing (port ${PORT_JAEGER:-16686})"
                "Docker code-execution isolation"
                "Tailscale mesh VPN")
  local selected; prompt_multiselect selected "Optional features" flabels fhints 0
  FEATURES=""
  local label; for label in $selected; do
    case "$label" in
      Dashboard)     [[ -n "$FEATURES" ]] && FEATURES+=","; FEATURES+="ui" ;;
      Observability) [[ -n "$FEATURES" ]] && FEATURES+=","; FEATURES+="otel" ;;
      Sandbox)       [[ -n "$FEATURES" ]] && FEATURES+=","; FEATURES+="sandbox" ;;
      Tailscale)     [[ -n "$FEATURES" ]] && FEATURES+=","; FEATURES+="tailscale" ;;
    esac
  done
  [[ "$FEATURES" == *"tailscale"* ]] && step_tailscale
  [[ "$FEATURES" == *"sandbox"* ]]   && step_sandbox_check
}

step_tailscale() {
  prompt_secret TS_AUTH_KEY "Tailscale auth key"
  prompt_text TS_HOSTNAME "Tailscale hostname" "goclaw-${STACK}" ""
  export TS_AUTH_KEY TS_HOSTNAME
}

step_sandbox_check() {
  if ! groups | grep -q docker; then
    print_warn "Current user not in docker group — sandbox may not work"
    print_info "Fix: sudo usermod -aG docker \$USER && newgrp docker"
  fi
  prompt_note "Sandbox build" "Will build openclaw-sandbox:bookworm-slim (~3 min first time)"
}

# ── Custom LLM base URL ───────────────────────────────────────────────────────
# stack_generate_env writes GOCLAW_{PROVIDER}_BASE_URL when CUSTOM_BASE_URL is exported.
step_custom_base_url() {
  local use_custom; prompt_confirm use_custom "Use custom LLM base URL? (proxy/self-hosted)" false
  if [[ "$use_custom" == "true" ]]; then
    prompt_text CUSTOM_BASE_URL "Custom base URL" "" ""
    export CUSTOM_BASE_URL
  fi
}

# ── Per-channel display names ─────────────────────────────────────────────────
step_channel_display_names() {
  local ch_types; ch_types=$(echo "$CHANNELS_JSON" | \
    python3 -c "import sys,json; print('\n'.join(c['type'] for c in json.load(sys.stdin)))" 2>/dev/null)
  [[ -z "$ch_types" ]] && return
  local ch; while IFS= read -r ch; do
    local dname; prompt_text dname "Display name for ${ch} account" "${AGENT_NAME} (${ch})" ""
    CHANNELS_JSON=$(echo "$CHANNELS_JSON" | python3 -c "
import sys, json
clist = json.load(sys.stdin)
for c in clist:
    if c['type'] == sys.argv[1]: c['display_name'] = sys.argv[2]
print(json.dumps(clist))" "$ch" "$dname")
  done <<< "$ch_types"
}

# ── Agent identity (full: adds personality + language) ────────────────────────
# Sets AGENT_PERSONALITY and AGENT_LANGUAGE (exported) — picked up by launch_stack
# via identity-wizard.py --agent-personality / --agent-language flags.
step_agent_full() {
  prompt_text AGENT_NAME "Agent name" "" ""
  prompt_text AGENT_PURPOSE "What does ${AGENT_NAME} do?" "" ""
  prompt_text AGENT_PERSONALITY "Personality / tone (optional — press Enter to skip)" "" ""
  prompt_text AGENT_LANGUAGE "Response language" "English" ""
  AGENT_KEY=$(derive_agent_key "$AGENT_NAME")
  export AGENT_PERSONALITY AGENT_LANGUAGE
  print_step "Agent key: ${AGENT_KEY}"
}

# ── Owner profile → USER.md ───────────────────────────────────────────────────
step_owner_profile() {
  prompt_text OWNER_NAME "Your name (agent will address you by this)" "" ""
  prompt_text OWNER_LANG "Your preferred language" "English" ""
  prompt_text OWNER_NOTES "Anything your agent should know about you? (optional)" "" ""
  export OWNER_NAME OWNER_LANG OWNER_NOTES
}

# ── API port override ─────────────────────────────────────────────────────────
validate_free_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]]               || { echo "Must be a number"; return 1; }
  [[ "$p" -ge 1024 && "$p" -le 65535 ]] || { echo "Must be 1024-65535"; return 1; }
  is_port_free "$p"                     || { echo "Port $p is in use"; return 1; }
}

step_port_override() {
  local override; prompt_confirm override "API port: ${PORT_API} — override?" false
  [[ "$override" == "true" ]] && prompt_text PORT_API "API port" "$PORT_API" "validate_free_port"
}

# ── Full flow entry point ─────────────────────────────────────────────────────
run_full_flow() {
  prompt_intro "Full Install — all configuration options"
  preflight
  step_mode
  step_features
  step_provider
  step_custom_base_url
  step_channels
  step_channel_display_names
  step_agent_full
  step_owner_profile
  allocate_port_block "$STACK" || exit 1
  generate_stack_secrets "$STACK"
  step_port_override
  confirm_summary
  launch_stack
}
