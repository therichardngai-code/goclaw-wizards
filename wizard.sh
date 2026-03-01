#!/usr/bin/env bash
# wizard.sh — GoClaw Wizard entry point. One-command AI gateway installer.
# Usage: bash wizard.sh [COMMAND] [OPTIONS]
# Requires: bash 4.3+, docker (compose v2), git, python3, curl, openssl
set -euo pipefail

WIZARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIZARD_VERSION="1.0.0"
export WIZARD_DIR WIZARD_VERSION

# Data directory — kept outside the wizard source tree.
# Override via env var WIZARD_HOME before running wizard.sh.
# Guard: if WIZARD_HOME somehow points inside WIZARD_DIR, reset to safe default.
WIZARD_HOME="${WIZARD_HOME:-${HOME}/.goclaw-wizard}"
[[ "$WIZARD_HOME" == "$WIZARD_DIR" || "$WIZARD_HOME" == "$WIZARD_DIR/"* ]] \
  && WIZARD_HOME="${HOME}/.goclaw-wizard"
export WIZARD_HOME

# Source all libraries (order matters: colors first, then deps)
for _lib in colors detect deps wizard-ui secrets ports compose stack bootstrap flow-data flows commands non-interactive; do
  # shellcheck source=/dev/null
  source "${WIZARD_DIR}/lib/${_lib}.sh"
done

# ── Defaults (overridden by parse_args) ──────────────────────────────────────
STACK="default"
FLOW="quickstart"
MODE="managed"
FEATURES="ui"
COMMAND="install"
NON_INTERACTIVE=false
ACCEPT_RISK=false
RESET=false
RESET_SCOPE="config"
YES=false
AGENT_KEY=""
REUSE_SECRETS=false
STATUS_ALL=false

# Non-interactive / flag-passthrough vars (all prefixed FLAG_)
FLAG_PROVIDER="" FLAG_API_KEY="" FLAG_MODEL="" FLAG_CHANNELS=""
FLAG_TELEGRAM_TOKEN="" FLAG_DISCORD_TOKEN=""
FLAG_LARK_APP_ID="" FLAG_LARK_APP_SECRET=""
FLAG_ZALO_TOKEN="" FLAG_WHATSAPP_URL=""
FLAG_OWNER_IDS="" FLAG_AGENT_NAME="" FLAG_AGENT_PURPOSE="" FLAG_AGENT_PERSONALITY=""
FLAG_OWNER_NAME="" FLAG_OWNER_LANG=""
FLAG_GATEWAY_PORT="" FLAG_GATEWAY_TOKEN="" FLAG_ENCRYPTION_KEY=""

# ── Argument Parsing ──────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)              STACK="$2";               shift 2 ;;
      --flow)              FLOW="$2";                shift 2 ;;
      --mode)              MODE="$2";                shift 2 ;;
      --features)          FEATURES="$2";            shift 2 ;;
      --agent-key)         AGENT_KEY="$2";           shift 2 ;;
      --reset-scope)       RESET_SCOPE="$2";         shift 2 ;;
      --provider)          FLAG_PROVIDER="$2";       shift 2 ;;
      --api-key)           FLAG_API_KEY="$2";        shift 2 ;;
      --model)             FLAG_MODEL="$2";          shift 2 ;;
      --channels)          FLAG_CHANNELS="$2";       shift 2 ;;
      --telegram-token)    FLAG_TELEGRAM_TOKEN="$2"; shift 2 ;;
      --discord-token)     FLAG_DISCORD_TOKEN="$2";  shift 2 ;;
      --lark-app-id)       FLAG_LARK_APP_ID="$2";   shift 2 ;;
      --lark-app-secret)   FLAG_LARK_APP_SECRET="$2";shift 2 ;;
      --zalo-token)        FLAG_ZALO_TOKEN="$2";     shift 2 ;;
      --whatsapp-url)      FLAG_WHATSAPP_URL="$2";   shift 2 ;;
      --owner-ids)         FLAG_OWNER_IDS="$2";      shift 2 ;;
      --agent-name)        FLAG_AGENT_NAME="$2";     shift 2 ;;
      --agent-purpose)     FLAG_AGENT_PURPOSE="$2";  shift 2 ;;
      --agent-personality) FLAG_AGENT_PERSONALITY="$2"; shift 2 ;;
      --owner-name)        FLAG_OWNER_NAME="$2";      shift 2 ;;
      --owner-language)    FLAG_OWNER_LANG="$2";      shift 2 ;;
      --gateway-port)      FLAG_GATEWAY_PORT="$2";   shift 2 ;;
      --gateway-token)     FLAG_GATEWAY_TOKEN="$2";  shift 2 ;;
      --encryption-key)    FLAG_ENCRYPTION_KEY="$2"; shift 2 ;;
      --non-interactive)   NON_INTERACTIVE=true;     shift ;;
      --accept-risk)       ACCEPT_RISK=true;         shift ;;
      --reset)             RESET=true;               shift ;;
      --yes|-y)            YES=true;                 shift ;;
      --help|-h)           show_help; exit 0 ;;
      --all)               STATUS_ALL=true;          shift ;;
      --repair)            DOCTOR_REPAIR=true;       shift ;;
      install|add-agent|remove-agent|reseed-agent|start|stop|restart|upgrade|uninstall|status|logs|doctor)
        COMMAND="$1"; shift ;;
      channels)
        COMMAND="channels"; shift ;;
      add)  # sub-command for: wizard.sh channels add
        COMMAND="channels-add"; shift ;;
      *) print_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done
}

# ── Help ─────────────────────────────────────────────────────────────────────
show_help() {
  printf "\n  ${BOLD}GoClaw Wizard${NC} v%s — One-command AI gateway installer\n\n" "$WIZARD_VERSION"
  printf "  ${BOLD}Usage:${NC}  bash wizard.sh [COMMAND] [OPTIONS]\n\n"
  printf "  ${BOLD}Commands:${NC}\n"
  printf "    install          Install a new GoClaw stack (default)\n"
  printf "    add-agent        Add an agent to an existing stack\n"
  printf "    remove-agent     Remove an agent (requires --agent-key)\n"
  printf "    reseed-agent     Regenerate agent identity files in-place (no data loss)\n"
  printf "    channels add     Add a channel to an existing agent\n"
  printf "    start|stop|restart|status|logs|upgrade|uninstall  Stack lifecycle\n"
  printf "    doctor           Diagnose stack health (--repair to auto-fix)\n\n"
  printf "  ${BOLD}Key Options:${NC}\n"
  printf "    --name NAME      Stack name (default: default)\n"
  printf "    --flow FLOW      quickstart|full (default: quickstart)\n"
  printf "    --non-interactive --accept-risk   Scripted/CI mode\n"
  printf "    --reset [--reset-scope config|config+sessions|full]  Clean reinstall\n\n"
  printf "  ${BOLD}Examples:${NC}\n"
  printf "    bash wizard.sh\n"
  printf "    bash wizard.sh install --name prod --flow full\n"
  printf "    bash wizard.sh add-agent --name prod\n"
  printf "    bash wizard.sh doctor --name prod --repair\n\n"
}

# ── Command Dispatcher ────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  setup_cancel_trap
  [[ "$NON_INTERACTIVE" != "true" ]] && print_banner

  case "$COMMAND" in
    install)
      [[ "$RESET" == "true" ]] && pre_install_reset "$STACK"
      if [[ "$NON_INTERACTIVE" == "true" ]]; then
        non_interactive_install
      else
        case "$FLOW" in
          quickstart) quickstart_flow ;;
          full)       full_flow ;;
          *) print_error "Unknown flow: ${FLOW}. Use: quickstart | full"; exit 1 ;;
        esac
      fi ;;
    add-agent)     cmd_add_agent ;;
    remove-agent)  cmd_remove_agent ;;
    reseed-agent)  cmd_reseed_agent ;;
    channels-add|channels) cmd_channels_add ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_restart ;;
    status)        [[ "$STATUS_ALL" == "true" ]] && cmd_status_all || cmd_status ;;
    logs)          cmd_logs ;;
    upgrade)       cmd_upgrade ;;
    uninstall)     cmd_uninstall ;;
    doctor)
      source "${WIZARD_DIR}/lib/doctor.sh" 2>/dev/null || true
      doctor_run "$STACK" "${DOCTOR_REPAIR:-false}" "$YES" ;;
    *) show_help; exit 1 ;;
  esac
}


main "$@"
