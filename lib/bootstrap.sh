#!/usr/bin/env bash
# lib/bootstrap.sh — Post-provision: agent seeding, welcome dispatch
# Depends on: colors.sh, stack.sh (stack_dir, stack_health_check, state_read), secrets.sh

# WIZARD_DIR must be set by wizard.sh (directory containing wizard.sh itself)
WIZARD_DIR="${WIZARD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- Main bootstrap: provision agent + restart + health check ---
# bootstrap_agent <stack> <agent_key> <agent_name> <channels_json>
#                 <soul_file> <identity_file> [user_file]
bootstrap_agent() {
  local stack="$1" agent_key="$2" agent_name="$3" channels_json="$4"
  local soul_file="$5" identity_file="$6" user_file="${7:-}"

  local api_port; api_port=$(state_read "$stack" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['ports']['api'])")
  local gw_token; gw_token=$(secret_get "$stack" "GOCLAW_GATEWAY_TOKEN")

  # Provision via Python script (create agent + seed files + channel instances)
  local result
  result=$(python3 "${WIZARD_DIR}/scripts/provision-agent.py" \
    --action create \
    --port   "$api_port" \
    --token  "$gw_token" \
    --agent-name "$agent_name" \
    --agent-key  "$agent_key" \
    --soul-file      "$soul_file" \
    --identity-file  "$identity_file" \
    ${user_file:+--user-file "$user_file"} \
    --channels-json  "$channels_json" 2>&1) || {
    print_error "Agent provisioning failed: ${result}"
    return 1
  }

  # PR #29: ContextFileInterceptor cache invalidated server-side on agents.files.set.
  # docker restart no longer needed — files are served immediately after seed.
  print_success "Agent '${agent_name}' provisioned and active"
}

# --- Welcome message dispatcher ---
# send_welcome <stack> <channels_json> <agent_name>
send_welcome() {
  local stack="$1" channels_json="$2" agent_name="$3"
  local channel_types
  channel_types=$(echo "$channels_json" | \
    python3 -c "import sys,json; [print(c['type']+'|'+json.dumps(c['credentials'])+'|'+','.join(c.get('owner_ids',[]))) for c in json.load(sys.stdin)]" 2>/dev/null)

  while IFS='|' read -r ch_type creds_json owner_ids_csv; do
    [[ -z "$ch_type" ]] && continue
    case "$ch_type" in
      telegram) send_welcome_telegram "$creds_json" "$agent_name" "$owner_ids_csv" ;;
      discord)  send_welcome_discord  "$agent_name" ;;
      lark)     : ;;      # Lark: proactive DM requires complex setup; skip silently
      zalo)     : ;;      # Zalo OA: user-initiated flow only
      whatsapp) : ;;      # WhatsApp bridge: user-initiated only
    esac
  done <<< "$channel_types"
}

# send_welcome_telegram <creds_json> <agent_name> <owner_ids_csv>
# Sends a welcome message to each owner via Telegram Bot API.
send_welcome_telegram() {
  local creds_json="$1" agent_name="$2" owner_ids_csv="$3"
  local bot_token
  bot_token=$(echo "$creds_json" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
  [[ -z "$bot_token" ]] && return

  local msg="${agent_name} is online and ready! Send me a message to get started. 🤖"
  local uid
  IFS=',' read -ra uid_arr <<< "$owner_ids_csv"
  for uid in "${uid_arr[@]}"; do
    [[ -z "$uid" ]] && continue
    curl -sf --max-time 10 \
      "https://api.telegram.org/bot${bot_token}/sendMessage" \
      -d "chat_id=${uid}" \
      -d "text=${msg}" \
      >/dev/null 2>&1 || true  # non-fatal: user can message first
  done
}

# send_welcome_discord <agent_name>
# Discord bots cannot DM without a shared server context; print info only.
send_welcome_discord() {
  print_info "Discord bot '${1}' is ready. Start a conversation from your server."
}

# --- Telegram @username → numeric ID resolution ---
# resolve_telegram_id <bot_token> <username_or_id>
# If input starts with @, resolve via Bot API getChat.
# Prints resolved numeric ID, or original input if resolution fails.
resolve_telegram_id() {
  local token="$1" input="$2"
  if [[ "$input" == @* ]]; then
    local username="${input#@}"
    local resp
    resp=$(curl -sf --max-time 10 \
      "https://api.telegram.org/bot${token}/getChat?chat_id=@${username}" 2>/dev/null) || true
    if [[ -n "$resp" ]]; then
      local resolved
      resolved=$(echo "$resp" | \
        python3 -c "import sys,json; r=json.load(sys.stdin); print(r['result']['id'])" 2>/dev/null) || true
      if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return 0
      fi
    fi
    print_warn "Could not resolve @${username} — enter your numeric Telegram user ID instead."
  fi
  echo "$input"
}

# --- Deprovision agent (delete channels first, then agent) ---
# deprovision_agent <stack> <agent_key>
deprovision_agent() {
  local stack="$1" agent_key="$2"
  local api_port; api_port=$(state_read "$stack" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['ports']['api'])")
  local gw_token; gw_token=$(secret_get "$stack" "GOCLAW_GATEWAY_TOKEN")

  python3 "${WIZARD_DIR}/scripts/provision-agent.py" \
    --action delete \
    --port  "$api_port" \
    --token "$gw_token" \
    --agent-key "$agent_key" 2>&1 || true
  # PR #29: no restart needed — cache invalidated server-side on agents.files.set
}
