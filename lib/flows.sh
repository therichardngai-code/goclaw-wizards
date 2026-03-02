#!/usr/bin/env bash
# lib/flows.sh — QuickStart flow: preflight, step functions, launch sequence
# Depends on: flow-data.sh, colors.sh, wizard-ui.sh, secrets.sh, ports.sh,
#             compose.sh, stack.sh, bootstrap.sh

# ── Preflight: deps + existing stack detection ────────────────────────────────
preflight() {
  detect_all
  check_all_deps || { print_error "Fix missing dependencies and retry."; exit 1; }

  local stack_d; stack_d=$(stack_dir "$STACK")
  if [[ -f "${stack_d}/state.json" ]]; then
    print_warn "Stack '${STACK}' already exists."
    local opts=("Reinstall (keep secrets)" "Add another agent" "Cancel")
    local choice; prompt_select choice "What would you like to do?" opts
    case "$choice" in
      "Reinstall (keep secrets)") ;;           # continue to install
      "Add another agent") cmd_add_agent; exit 0 ;;
      "Cancel") print_info "Cancelled."; exit 0 ;;
    esac
  fi

  if secrets_exist "$STACK"; then
    REUSE_SECRETS=true
    print_info "Existing secrets will be reused (preserves database data)"
  fi
}

# ── Step 1: Provider selection ────────────────────────────────────────────────
step_provider() {
  local selected_label
  prompt_select selected_label "LLM provider" PROVIDER_LABELS PROVIDER_HINTS
  local idx; idx=$(index_of "$selected_label" PROVIDER_LABELS)
  PROVIDER="${PROVIDERS[$idx]}"
  local env_key="${PROVIDER_ENV[$idx]}"

  # Check env var: GOCLAW_{PROVIDER}_API_KEY
  local env_var="GOCLAW_${env_key}_API_KEY"
  API_KEY="${!env_var:-}"
  if [[ -z "$API_KEY" ]]; then
    prompt_secret API_KEY "${selected_label} API key"
  else
    print_info "Using ${selected_label} key from env (${env_var})"
  fi

  MODEL="${PROVIDER_MODELS[$idx]}"
  prompt_text MODEL "Model name" "$MODEL" ""
}

# ── Step 2: Channel credential collection ────────────────────────────────────
# collect_channel_creds <ch_type> — sets global _ch_creds_json
collect_channel_creds() {
  local ch_type="$1"
  # Split $'\n'-delimited help string into array lines
  local IFS=$'\n'; read -r -d '' -a _help_lines <<< "${CHANNEL_HELP[$ch_type]}" || true
  prompt_note "${ch_type^} setup" "${_help_lines[@]}"

  local token app_id app_secret bridge_url owner_id
  case "$ch_type" in
    telegram)
      prompt_secret token "Telegram bot token"
      prompt_text owner_id "Your Telegram user ID (or @username)" "" ""
      owner_id=$(resolve_telegram_id "$token" "$owner_id")
      _ch_creds_json="{\"type\":\"telegram\",\"credentials\":{\"token\":\"${token}\"},\"owner_ids\":[\"${owner_id}\"]}"
      ;;
    discord)
      prompt_secret token "Discord bot token"
      prompt_text owner_id "Your Discord user ID" "" ""
      _ch_creds_json="{\"type\":\"discord\",\"credentials\":{\"token\":\"${token}\"},\"owner_ids\":[\"${owner_id}\"]}"
      ;;
    lark)
      prompt_text app_id "Lark App ID" "" ""
      prompt_secret app_secret "Lark App Secret"
      prompt_text owner_id "Your Lark user ID" "" ""
      _ch_creds_json="{\"type\":\"lark\",\"credentials\":{\"app_id\":\"${app_id}\",\"app_secret\":\"${app_secret}\"},\"owner_ids\":[\"${owner_id}\"]}"
      ;;
    zalo)
      prompt_secret token "Zalo OA token"
      prompt_text owner_id "Your Zalo user ID" "" ""
      _ch_creds_json="{\"type\":\"zalo\",\"credentials\":{\"token\":\"${token}\"},\"owner_ids\":[\"${owner_id}\"]}"
      ;;
    whatsapp)
      prompt_text bridge_url "WhatsApp bridge URL" "http://localhost:3001" ""
      prompt_text owner_id "Your WhatsApp user ID" "" ""
      _ch_creds_json="{\"type\":\"whatsapp\",\"credentials\":{\"bridge_url\":\"${bridge_url}\"},\"owner_ids\":[\"${owner_id}\"]}"
      ;;
  esac
}

step_channels() {
  local selected_labels
  prompt_multiselect selected_labels "Messaging channels" CHANNEL_LABELS CHANNEL_HINTS 1
  CHANNELS_JSON="["; local first=true
  local label; for label in $selected_labels; do
    local idx; idx=$(index_of "$label" CHANNEL_LABELS)
    collect_channel_creds "${CHANNEL_TYPES[$idx]}"
    [[ "$first" == "true" ]] && first=false || CHANNELS_JSON+=","
    CHANNELS_JSON+="$_ch_creds_json"
  done
  CHANNELS_JSON+="]"
}

# ── Step 3: Agent identity ────────────────────────────────────────────────────
step_agent() {
  prompt_text AGENT_NAME "Agent name" "" ""
  prompt_text AGENT_PURPOSE "What does ${AGENT_NAME} do?" "" ""
  prompt_text AGENT_PERSONALITY "Personality / tone (optional — Enter to skip)" "" ""
  prompt_text AGENT_LANGUAGE "Response language" "English" ""
  AGENT_KEY=$(derive_agent_key "$AGENT_NAME")
  export AGENT_PERSONALITY AGENT_LANGUAGE
  print_step "Agent key: ${AGENT_KEY}"
}

step_owner() {
  prompt_text OWNER_NAME "Your name (so the agent knows who you are — Enter to skip)" "" ""
  prompt_text OWNER_LANG "Your language" "English" ""
  export OWNER_NAME OWNER_LANG
}

# ── Step: Web Dashboard admin ID ──────────────────────────────────────────────
# Separate from channel owner_ids — admin can see ALL agents + ALL conversations.
# Default: first owner_id entered during channel setup (most likely the operator).
step_admin() {
  local _default_id
  _default_id=$(echo "${CHANNELS_JSON:-[]}" | python3 -c "
import sys, json
for ch in json.load(sys.stdin):
    ids = ch.get('owner_ids', [])
    if ids and ids[0]:
        print(ids[0]); break
" 2>/dev/null || echo "")

  prompt_note "Web Dashboard Admin" \
    "The admin ID grants full access to the Web Dashboard (view ALL agents + ALL conversations)." \
    "Enter YOUR ID — the person running this wizard — not your end-users' IDs."
  prompt_text OWNER_IDS "Your admin user ID (Telegram / Discord / etc.)" "$_default_id" ""
  export OWNER_IDS
}

# ── Confirm summary before launch ─────────────────────────────────────────────
confirm_summary() {
  local ch_types; ch_types=$(echo "$CHANNELS_JSON" | \
    python3 -c "import sys,json; print(', '.join(c['type'] for c in json.load(sys.stdin)))" 2>/dev/null)
  printf "\n  ${CYAN}┌${NC}  ${BOLD}Ready to install${NC}\n  ${CYAN}│${NC}\n"
  printf "  ${CYAN}│${NC}  Provider:  %s  (model: %s)\n"    "$PROVIDER"   "$MODEL"
  printf "  ${CYAN}│${NC}  Channels:  %s\n"                 "${ch_types:-?}"
  printf "  ${CYAN}│${NC}  Agent:     %s  (key: %s)\n"     "$AGENT_NAME" "$AGENT_KEY"
  printf "  ${CYAN}│${NC}  Admin ID:  %s\n"                "${OWNER_IDS:-?}"
  printf "  ${CYAN}│${NC}  Mode:      %s  |  Features: %s\n" "$MODE"     "${FEATURES:-none}"
  printf "  ${CYAN}│${NC}  Gateway:   http://127.0.0.1:%s\n"  "$PORT_API"
  [[ "$FEATURES" == *"ui"* ]] && printf "  ${CYAN}│${NC}  Dashboard: http://127.0.0.1:%s\n" "$PORT_UI"
  printf "  ${CYAN}│${NC}\n"
  local ok; prompt_confirm ok "Launch stack?" true
  [[ "$ok" == "true" ]] || { print_info "Cancelled."; exit 0; }
}

# ── Launch sequence ───────────────────────────────────────────────────────────
launch_stack() {
  local goclaw_dir; goclaw_dir="$(stack_dir "$STACK")/goclaw"
  local agents_dir; agents_dir="$(stack_dir "$STACK")/agents/${AGENT_KEY}"

  prompt_progress "Cloning GoClaw source..." stack_clone_or_pull "$STACK"

  if [[ "${REUSE_SECRETS:-false}" == "true" ]]; then
    secrets_load "$STACK"
  else
    generate_stack_secrets "$STACK"
  fi
  export GOCLAW_GATEWAY_TOKEN GOCLAW_ENCRYPTION_KEY POSTGRES_PASSWORD
  [[ -n "${FLAG_GATEWAY_TOKEN:-}"  ]] && GOCLAW_GATEWAY_TOKEN="$FLAG_GATEWAY_TOKEN"
  [[ -n "${FLAG_ENCRYPTION_KEY:-}" ]] && GOCLAW_ENCRYPTION_KEY="$FLAG_ENCRYPTION_KEY"
  [[ -n "${FLAG_GATEWAY_PORT:-}"   ]] && PORT_API="$FLAG_GATEWAY_PORT"

  # OWNER_IDS must be set before this point — either by step_admin() (interactive)
  # or by map_flags_to_config() (non-interactive). It is NOT derived from CHANNELS_JSON
  # because channel owner_ids = who can DM the bot, which is different from
  # GOCLAW_OWNER_IDS = who gets Web Dashboard admin access (sees ALL agents + conversations).
  local env_file; env_file=$(stack_generate_env "$STACK")
  trap "stack_cleanup_env '${STACK}'" EXIT

  prompt_progress "Starting Docker stack..." \
    compose_up "$STACK" "$goclaw_dir" "$MODE" "$FEATURES" "$env_file"

  prompt_progress "Waiting for gateway..." \
    stack_health_check "$STACK" "$PORT_API" 20 5 || {
    print_error "Health check failed. Run: bash wizard.sh doctor --name ${STACK}"
    local _st; _st=$(docker inspect "goclaw-${STACK}-goclaw-1" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$_st" != "running" ]]; then
      printf "  ${DIM}Gateway logs (last 20 lines):${NC}\n"
      docker logs --tail 20 "goclaw-${STACK}-goclaw-1" 2>&1 | sed 's/^/  │  /' || true
    fi
    exit 1; }

  prompt_progress "Warming up LLM gateway..." \
    stack_warmup_llm "$STACK" "$PORT_API" "$GOCLAW_GATEWAY_TOKEN" || true

  mkdir -p "$agents_dir"
  prompt_progress "Generating ${AGENT_NAME}'s identity..." \
    python3 "${WIZARD_DIR}/scripts/identity-wizard.py" \
      --mode install --port "$PORT_API" --token "$GOCLAW_GATEWAY_TOKEN" --model "$MODEL" \
      --agent-name "$AGENT_NAME" --agent-purpose "$AGENT_PURPOSE" \
      --agent-personality "${AGENT_PERSONALITY:-}" --agent-language "${AGENT_LANGUAGE:-English}" \
      --owner-name "${OWNER_NAME:-}" --owner-language "${OWNER_LANG:-English}" \
      --output-dir "$agents_dir" --templates-dir "${WIZARD_DIR}/templates"

  # Write initial state.json (ports + meta) NOW — bootstrap_agent reads ports.api from it
  state_write "$STACK" "$(build_state_json)"

  local user_file_arg=""; [[ -f "${agents_dir}/USER.md" ]] && user_file_arg="${agents_dir}/USER.md"
  prompt_progress "Provisioning agent..." \
    bootstrap_agent "$STACK" "$AGENT_KEY" "$AGENT_NAME" "$CHANNELS_JSON" \
      "${agents_dir}/SOUL.md" "${agents_dir}/IDENTITY.md" "${user_file_arg:-}"

  send_welcome "$STACK" "$CHANNELS_JSON" "$AGENT_NAME"

  local agent_entry; agent_entry=$(python3 -c "
import json, datetime
ch = json.loads(r'''${CHANNELS_JSON}''')
print(json.dumps({'key':'${AGENT_KEY}','name':'${AGENT_NAME}','type':'predefined',
  'channels':[c['type'] for c in ch],'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}))" 2>/dev/null)
  [[ -n "$agent_entry" ]] && state_update_agents "$STACK" "$agent_entry"

  local _first_owner; _first_owner=$(echo "${OWNER_IDS:-}" | cut -d',' -f1)
  local _token_hint;  _token_hint="${GOCLAW_GATEWAY_TOKEN:0:8}…"
  local _secrets_path; _secrets_path="$(stack_dir "$STACK")/.secrets"
  prompt_outro "$(printf '%s is live!\n\n  Gateway:   http://127.0.0.1:%s\n  Dashboard: http://127.0.0.1:%s\n\n  Web UI Login:\n    User ID:       %s\n    Gateway Token: %s\n    (full token in: %s)\n\n  Add agent: bash wizard.sh add-agent --name %s\n  Diagnose:  bash wizard.sh doctor  --name %s' \
    "$AGENT_NAME" "$PORT_API" "$PORT_UI" \
    "${_first_owner:-(none)}" "$_token_hint" "$_secrets_path" \
    "$STACK" "$STACK")"
}

# ── QuickStart flow (default) ─────────────────────────────────────────────────
quickstart_flow() {
  prompt_intro "QuickStart Install  —  5 steps to a working AI agent"
  preflight; step_provider; step_channels; step_agent; step_owner; step_admin
  allocate_port_block "$STACK" || exit 1
  generate_stack_secrets "$STACK"
  confirm_summary; launch_stack
}

# ── Full flow placeholder (Phase 6) ──────────────────────────────────────────
full_flow() {
  local ff="${WIZARD_DIR}/lib/full-flow.sh"
  [[ -f "$ff" ]] && { source "$ff"; run_full_flow; return; }
  print_error "Full flow not yet available. Use --flow quickstart."
  exit 1
}

