#!/usr/bin/env bash
# lib/commands.sh — Stack management: add-agent, remove-agent, channels add,
#   start, stop, restart, status, logs, upgrade, uninstall
# Depends on: stack.sh, compose.sh, bootstrap.sh, flows.sh (step_channels, collect_channel_creds)

# ── Common helpers ─────────────────────────────────────────────────────────────
validate_stack_exists() {
  [[ -f "$(stack_dir "${1:-$STACK}")/state.json" ]] && return 0
  print_error "Stack '${1:-$STACK}' not found. Run: bash wizard.sh install --name ${1:-$STACK}"; exit 1
}

_load_stack_state() {
  _state=$(state_read "$STACK")
  _mode=$(echo "$_state"     | python3 -c "import sys,json;print(json.load(sys.stdin).get('mode','managed'))")
  _features=$(echo "$_state" | python3 -c "import sys,json;print(','.join(json.load(sys.stdin).get('features',[])))")
  _goclaw_dir="$(stack_dir "$STACK")/goclaw"
  _api_port=$(echo "$_state" | python3 -c "import sys,json;print(json.load(sys.stdin)['ports']['api'])")
  # Restore OWNER_IDS from state.json so stack_generate_env writes GOCLAW_OWNER_IDS correctly
  # on every start/restart/upgrade — not just the initial install.
  OWNER_IDS=$(echo "$_state" | python3 -c "import sys,json;print(','.join(json.load(sys.stdin).get('owner_ids',[])))" 2>/dev/null || true)
  export OWNER_IDS
}

# ── Add agent ─────────────────────────────────────────────────────────────────
cmd_add_agent() {
  validate_stack_exists; _load_stack_state; secrets_load "$STACK"

  stack_health_check "$STACK" "$_api_port" 3 2 || {
    print_error "Stack not running. Start first: bash wizard.sh start --name ${STACK}"; exit 1; }
  prompt_progress "Warming up LLM..." stack_warmup_llm "$STACK" "$_api_port" "$GOCLAW_GATEWAY_TOKEN" || true
  prompt_note "New agent" "Each agent needs its OWN bot tokens (a different bot per agent)"

  step_channels

  prompt_text AGENT_NAME "Agent name" "" ""
  prompt_text AGENT_PURPOSE "What does ${AGENT_NAME} do?" "" ""
  prompt_text AGENT_PERSONALITY "Personality / tone (optional — Enter to skip)" "" ""
  prompt_text AGENT_LANGUAGE "Response language" "English" ""
  AGENT_KEY=$(derive_agent_key "$AGENT_NAME"); export AGENT_PERSONALITY AGENT_LANGUAGE
  print_step "Agent key: ${AGENT_KEY}"
  prompt_text OWNER_NAME "Your name (so the agent knows who you are — Enter to skip)" "" ""
  prompt_text OWNER_LANG "Your language" "English" ""
  export OWNER_NAME OWNER_LANG

  local agents_dir; agents_dir="$(stack_dir "$STACK")/agents/${AGENT_KEY}"
  mkdir -p "$agents_dir"
  prompt_progress "Generating ${AGENT_NAME}'s identity..." \
    python3 "${WIZARD_DIR}/scripts/identity-wizard.py" \
      --mode add-agent --port "$_api_port" --token "$GOCLAW_GATEWAY_TOKEN" --model "default" \
      --agent-name "$AGENT_NAME" --agent-purpose "$AGENT_PURPOSE" \
      --agent-personality "${AGENT_PERSONALITY:-}" --agent-language "${AGENT_LANGUAGE:-English}" \
      --owner-name "${OWNER_NAME:-}" --owner-language "${OWNER_LANG:-English}" \
      --output-dir "$agents_dir" --templates-dir "${WIZARD_DIR}/templates"

  local user_file_arg=""; [[ -f "${agents_dir}/USER.md" ]] && user_file_arg="${agents_dir}/USER.md"
  prompt_progress "Provisioning ${AGENT_NAME}..." \
    bootstrap_agent "$STACK" "$AGENT_KEY" "$AGENT_NAME" "$CHANNELS_JSON" \
      "${agents_dir}/SOUL.md" "${agents_dir}/IDENTITY.md" "${user_file_arg:-}"

  local agent_entry; agent_entry=$(python3 -c "
import json, datetime
ch = json.loads(r'''${CHANNELS_JSON}''')
print(json.dumps({'key':'${AGENT_KEY}','name':'${AGENT_NAME}','type':'predefined',
  'channels':[c['type'] for c in ch],'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}))" 2>/dev/null)
  [[ -n "$agent_entry" ]] && state_update_agents "$STACK" "$agent_entry"
  prompt_outro "$(printf '%s is live!\n  Manage: bash wizard.sh status --name %s' "$AGENT_NAME" "$STACK")"
}

# ── Reseed agent identity (non-destructive: updates SOUL.md/IDENTITY.md in-place) ──────
cmd_reseed_agent() {
  validate_stack_exists; _load_stack_state; secrets_load "$STACK"

  # Select agent if not specified
  if [[ -z "${AGENT_KEY:-}" ]]; then
    local agent_arr; mapfile -t agent_arr < <(echo "$_state" | \
      python3 -c "import sys,json;[print(a['key']) for a in json.load(sys.stdin).get('agents',[])]" 2>/dev/null)
    [[ ${#agent_arr[@]} -eq 0 ]] && { print_error "No agents found in stack '${STACK}'"; exit 1; }
    if [[ ${#agent_arr[@]} -eq 1 ]]; then
      AGENT_KEY="${agent_arr[0]}"
    else
      local empty_hints=()
      prompt_select AGENT_KEY "Which agent to reseed?" agent_arr empty_hints
    fi
  fi

  local AGENT_NAME; AGENT_NAME=$(echo "$_state" | python3 -c \
    "import sys,json; a=next((x for x in json.load(sys.stdin).get('agents',[]) if x['key']=='${AGENT_KEY}'),None); print(a['name'] if a else '${AGENT_KEY}')" 2>/dev/null)

  stack_health_check "$STACK" "$_api_port" 3 2 || {
    print_error "Stack not running. Start first: bash wizard.sh start --name ${STACK}"; exit 1; }

  prompt_progress "Warming up LLM..." stack_warmup_llm "$STACK" "$_api_port" "$GOCLAW_GATEWAY_TOKEN" || true

  prompt_text AGENT_PURPOSE "What does ${AGENT_NAME} do?" "" ""
  prompt_text AGENT_PERSONALITY "Personality / tone (optional — Enter to skip)" "" ""
  prompt_text AGENT_LANGUAGE "Response language" "English" ""
  prompt_text OWNER_NAME "Your name (so the agent knows who you are — Enter to skip)" "" ""
  prompt_text OWNER_LANG "Your language" "English" ""

  local agents_dir; agents_dir="$(stack_dir "$STACK")/agents/${AGENT_KEY}"
  mkdir -p "$agents_dir"

  prompt_progress "Regenerating ${AGENT_NAME}'s identity..." \
    python3 "${WIZARD_DIR}/scripts/identity-wizard.py" \
      --mode add-agent --port "$_api_port" --token "$GOCLAW_GATEWAY_TOKEN" --model "default" \
      --agent-name "$AGENT_NAME" --agent-purpose "$AGENT_PURPOSE" \
      --agent-personality "${AGENT_PERSONALITY:-}" --agent-language "${AGENT_LANGUAGE:-English}" \
      --owner-name "${OWNER_NAME:-}" --owner-language "${OWNER_LANG:-English}" \
      --output-dir "$agents_dir" --templates-dir "${WIZARD_DIR}/templates"

  local user_file_arg=""; [[ -f "${agents_dir}/USER.md" ]] && user_file_arg="${agents_dir}/USER.md"
  prompt_progress "Updating ${AGENT_NAME}'s files (no delete/recreate)..." \
    python3 "${WIZARD_DIR}/scripts/provision-agent.py" \
      --action update-files --port "$_api_port" --token "$GOCLAW_GATEWAY_TOKEN" \
      --agent-key "$AGENT_KEY" \
      --soul-file     "${agents_dir}/SOUL.md" \
      --identity-file "${agents_dir}/IDENTITY.md" \
      ${user_file_arg:+--user-file "$user_file_arg"}

  # PR #29: cache invalidated server-side on agents.files.set — no restart needed
  print_success "Agent '${AGENT_NAME}' identity updated — owner profile now in SOUL.md"
}

# ── Remove agent ──────────────────────────────────────────────────────────────
cmd_remove_agent() {
  validate_stack_exists
  [[ -n "${AGENT_KEY:-}" ]] || { print_error "Missing --agent-key"; exit 1; }
  local confirm; prompt_confirm confirm "Remove agent '${AGENT_KEY}' and all its channels?" false
  [[ "$confirm" == "true" ]] || { print_info "Cancelled"; exit 0; }
  secrets_load "$STACK"
  prompt_progress "Removing ${AGENT_KEY}..." deprovision_agent "$STACK" "$AGENT_KEY"
  rm -rf "$(stack_dir "$STACK")/agents/${AGENT_KEY}"
  state_remove_agent "$STACK" "$AGENT_KEY"
  print_success "Agent '${AGENT_KEY}' removed"
}

# ── Channels add ──────────────────────────────────────────────────────────────
cmd_channels_add() {
  validate_stack_exists; _load_stack_state; secrets_load "$STACK"

  # Agent selection
  if [[ -z "${AGENT_KEY:-}" ]]; then
    local agent_arr; mapfile -t agent_arr < <(echo "$_state" | \
      python3 -c "import sys,json;[print(a['key']) for a in json.load(sys.stdin).get('agents',[])]" 2>/dev/null)
    if [[ ${#agent_arr[@]} -eq 1 ]]; then
      AGENT_KEY="${agent_arr[0]}"
    else
      local empty_hints=()
      prompt_select AGENT_KEY "Which agent?" agent_arr empty_hints
    fi
  fi

  # Existing channels
  local existing; existing=$(echo "$_state" | python3 -c "
import sys,json
a=next((x for x in json.load(sys.stdin).get('agents',[]) if x['key']=='${AGENT_KEY}'),None)
print(','.join(a.get('channels',[])) if a else '')" 2>/dev/null)

  # Build available list
  local avail_types=() avail_labels=() avail_hints=()
  local i; for (( i=0; i<${#CHANNEL_TYPES[@]}; i++ )); do
    [[ "$existing" != *"${CHANNEL_TYPES[$i]}"* ]] && \
      avail_types+=("${CHANNEL_TYPES[$i]}") && \
      avail_labels+=("${CHANNEL_LABELS[$i]}") && \
      avail_hints+=("${CHANNEL_HINTS[$i]}")
  done
  [[ ${#avail_types[@]} -eq 0 ]] && { print_info "All channels already configured for ${AGENT_KEY}"; exit 0; }

  local sel_label; prompt_select sel_label "Channel to add" avail_labels avail_hints
  local ch_type=""; local j
  for (( j=0; j<${#avail_labels[@]}; j++ )); do
    [[ "${avail_labels[$j]}" == "$sel_label" ]] && ch_type="${avail_types[$j]}" && break
  done

  collect_channel_creds "$ch_type"  # sets _ch_creds_json
  prompt_progress "Adding ${ch_type}..." \
    python3 "${WIZARD_DIR}/scripts/provision-agent.py" \
      --action add-channel --port "$_api_port" --token "$GOCLAW_GATEWAY_TOKEN" \
      --agent-key "$AGENT_KEY" --channels-json "[${_ch_creds_json}]"
  # PR #29: no restart needed

  local updated; updated=$(state_read "$STACK" | python3 -c "
import sys,json; state=json.load(sys.stdin)
for a in state.get('agents',[]):
    if a.get('key')==sys.argv[1] and sys.argv[2] not in a.get('channels',[]):
        a.setdefault('channels',[]).append(sys.argv[2])
print(json.dumps(state,indent=2))" "$AGENT_KEY" "$ch_type")
  [[ -n "$updated" ]] && state_write "$STACK" "$updated"
  print_success "${ch_type} added to ${AGENT_KEY}"
}

# ── Start / Stop / Restart ────────────────────────────────────────────────────
cmd_start() {
  validate_stack_exists; _load_stack_state; secrets_load "$STACK"
  build_overlay_args "$_goclaw_dir" "$_mode" "$_features" || return 1
  local env_file; env_file=$(stack_generate_env "$STACK")
  trap "stack_cleanup_env '$STACK'" EXIT
  docker compose --project-name "goclaw-${STACK}" "${GOCLAW_OVERLAY_ARGS[@]}" --env-file "$env_file" up -d
  print_success "Stack '${STACK}' started"
}

cmd_stop() {
  validate_stack_exists; _load_stack_state
  build_overlay_args "$_goclaw_dir" "$_mode" "$_features" || return 1
  docker compose --project-name "goclaw-${STACK}" "${GOCLAW_OVERLAY_ARGS[@]}" stop
  print_success "Stack '${STACK}' stopped (volumes preserved)"
}

cmd_restart() {
  validate_stack_exists; _load_stack_state
  compose_restart "$STACK" "$_goclaw_dir" "$_mode" "$_features"
  print_success "Stack '${STACK}' restarted"
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
  validate_stack_exists; _load_stack_state
  printf "\n  ${BOLD}Stack: ${STACK}${NC}\n\n"
  printf "  %-36s %s\n" "SERVICE" "STATUS"; printf "  %-36s %s\n" "-------" "------"
  local svc_json; svc_json=$(compose_ps "$STACK" "$_goclaw_dir" "$_mode" "$_features" 2>/dev/null || echo "[]")
  echo "$svc_json" | python3 -c "
import sys,json
try: data=json.load(sys.stdin)
except: data=[]
if not isinstance(data,list): data=[]
for s in data:
    name=s.get('Name',s.get('Service','?'))
    st=s.get('State',s.get('Status','?'))
    health=s.get('Health','')
    badge='\033[32m\u2713\033[0m' if st=='running' else '\033[31m\u2717\033[0m'
    status=f'{st} ({health})' if health else st
    print(f'  {badge} {name:<36} {status}')
" 2>/dev/null

  printf "\n  ${BOLD}Agents:${NC}\n"
  echo "$_state" | python3 -c "
import sys,json
for a in json.load(sys.stdin).get('agents',[]):
    print(f\"  \u2022 {a['name']} ({a['key']}) \u2014 {', '.join(a.get('channels',[]))}\")
"
  printf "\n"
  echo "$_state" | python3 -c "
import sys,json; p=json.load(sys.stdin).get('ports',{})
print(f'  Gateway:   http://127.0.0.1:{p.get(\"api\",\"?\")}')
print(f'  Dashboard: http://127.0.0.1:{p.get(\"ui\",\"?\")}')
"; printf "\n"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
cmd_logs() {
  validate_stack_exists; _load_stack_state
  compose_logs "$STACK" "$_goclaw_dir" "$_mode" "$_features" "${1:-goclaw}"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
cmd_upgrade() {
  validate_stack_exists; _load_stack_state; secrets_load "$STACK"
  prompt_progress "Pulling latest GoClaw..." git -C "$_goclaw_dir" pull --ff-only
  local env_file; env_file=$(stack_generate_env "$STACK")
  trap "stack_cleanup_env '$STACK'" EXIT
  prompt_progress "Running DB migrations..." compose_upgrade "$STACK" "$_goclaw_dir" "$_mode" "$_features" "$env_file"
  prompt_progress "Health check..." stack_health_check "$STACK" "$_api_port" 20 5
  local ver; ver=$(git -C "$_goclaw_dir" describe --tags --always 2>/dev/null || echo "latest")
  local updated; updated=$(echo "$_state" | python3 -c "
import sys,json; s=json.load(sys.stdin); s['version']='${ver}'; print(json.dumps(s,indent=2))")
  [[ -n "$updated" ]] && state_write "$STACK" "$updated"
  print_success "Stack '${STACK}' upgraded to ${ver}"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
  validate_stack_exists; _load_stack_state
  if [[ "${YES:-false}" != "true" ]]; then
    local confirm; prompt_confirm confirm "Uninstall stack '${STACK}'? Services will stop." false
    [[ "$confirm" == "true" ]] || { print_info "Cancelled"; exit 0; }
  fi
  local wipe_vols=false
  [[ "${YES:-false}" != "true" ]] && prompt_confirm wipe_vols "Wipe database volumes? (irreversible)" false
  prompt_progress "Stopping stack..." compose_down "$STACK" "$_goclaw_dir" "$_mode" "$_features" "$wipe_vols"
  rm -rf "$(stack_dir "$STACK")"
  print_success "Stack '${STACK}' uninstalled"
}
