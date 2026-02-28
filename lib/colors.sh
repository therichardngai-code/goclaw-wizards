#!/usr/bin/env bash
# lib/colors.sh — ANSI color constants, banner, spinner, and UI output primitives
# Depends on: nothing (pure output, no other lib deps)

# --- ANSI color constants ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'  # No Color / Reset

# --- Color support detection ---
color_enabled() {
  [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ "${NO_COLOR:-}" != "1" ]]
}

# Disable all colors when non-TTY or explicitly disabled
if ! color_enabled; then
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# --- Banner ---
print_banner() {
  local version="${WIZARD_VERSION:-1.0.0}"
  printf "\n${BOLD}${CYAN}"
  printf "  ╔═══════════════════════════════╗\n"
  printf "  ║     🦅  GoClaw Wizard         ║\n"
  printf "  ║     One-command AI installer  ║\n"
  printf "  ╚═══════════════════════════════╝${NC}\n"
  printf "  ${DIM}v%s${NC}\n\n" "$version"
}

# --- Spinner ---
# print_spinner <pid> <msg>
# Animates while $pid is running; prints ✔ or ✗ on completion.
print_spinner() {
  local pid="$1" msg="$2"
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local start=$SECONDS i=0

  if ! color_enabled; then
    printf "  ... %s\n" "$msg"
    wait "$pid"
    return $?
  fi

  tput civis 2>/dev/null || true  # hide cursor

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}%s${NC}  %s " "${frames[$((i % 10))]}" "$msg"
    i=$(( i + 1 ))
    sleep 0.1
  done

  local elapsed=$(( SECONDS - start ))
  wait "$pid"
  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    printf "\r  ${GREEN}✔${NC}  %s  ${DIM}(%ds)${NC}\n" "$msg" "$elapsed"
  else
    printf "\r  ${RED}✗${NC}  %s\n" "$msg"
  fi

  tput cnorm 2>/dev/null || true  # restore cursor
  return $exit_code
}

# --- Note box ---
# print_note <title> <body...> (body lines as remaining args or single newline-separated string)
print_note() {
  local title="$1"; shift
  printf "\n  ${CYAN}■${NC}  ${BOLD}Note: %s${NC}\n" "$title"
  printf "  ${CYAN}│${NC}\n"
  while IFS= read -r line; do
    printf "  ${CYAN}│${NC}  %s\n" "$line"
  done <<< "$*"
  printf "  ${CYAN}│${NC}\n"
}

# --- Status line helpers ---
print_success() { printf "  ${GREEN}✔${NC}  %s\n" "$*"; }
print_error()   { printf "  ${RED}✗${NC}  %s\n" "$*" >&2; }
print_warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
print_info()    { printf "  ${CYAN}ℹ${NC}  %s\n" "$*"; }
print_step()    { printf "  ${CYAN}│${NC}  %s\n" "$*"; }
