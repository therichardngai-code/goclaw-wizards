#!/usr/bin/env bash
# lib/wizard-ui.sh — Interactive prompt primitives (bash 4.3+ required for namerefs)
# Depends on: colors.sh (ANSI constants, print_spinner)

setup_cancel_trap() { trap '_wiz_cancel' INT; }
_wiz_cancel() { tput cnorm 2>/dev/null||true; printf "\n\n  Setup cancelled.\n\n"; exit 0; }

prompt_intro() { printf "\n  ${CYAN}┌${NC}  ${BOLD}%s${NC}\n  ${CYAN}│${NC}\n" "$1"; }
prompt_outro() { printf "  ${CYAN}│${NC}\n  ${GREEN}└${NC}  ${BOLD}%s${NC}\n\n" "$1"; }

# Read a single keypress (handles escape sequences for arrow keys)
_read_key() {
  local key rest
  IFS= read -r -s -n1 key 2>/dev/null
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -r -s -n2 -t 0.15 rest 2>/dev/null||true; key+="${rest:-}"
  fi
  printf '%s' "$key"
}

# Erase N lines above cursor
_erase_lines() {
  local i; for (( i=0; i<$1; i++ )); do tput cuu1 2>/dev/null; tput el 2>/dev/null; done
}

# prompt_select <var_name> <label> <opts_arr_name> [hints_arr_name]
# Arrow-key navigation; sets $var_name to chosen value.
prompt_select() {
  local _v="$1" _lbl="$2"; local -n _o="$3"; local -n _h="${4:-_pse}" 2>/dev/null
  declare -ga _pse=()
  local _s=0 _n=${#_o[@]}
  _psr() {
    printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}\n" "$_lbl"
    local i; for (( i=0; i<_n; i++ )); do
      local ht="${_h[$i]:-}"
      if [[ $i -eq $_s ]]; then
        printf "  ${CYAN}│${NC}  ${GREEN}❯ %-24s${NC}  ${DIM}%s${NC}\n" "${_o[$i]}" "$ht"
      else
        printf "  ${CYAN}│${NC}    %-24s   ${DIM}%s${NC}\n" "${_o[$i]}" "$ht"
      fi
    done
  }
  tput civis 2>/dev/null||true; _psr
  while true; do
    local k; k=$(_read_key)
    case "$k" in
      $'\x1b[A'|k) [[ $_s -gt 0 ]]       && (( _s-- )) || true ;;
      $'\x1b[B'|j) [[ $_s -lt $((_n-1)) ]] && (( _s++ )) || true ;;
      $'\x03') _wiz_cancel ;;
      '') break ;;
    esac
    _erase_lines $(( _n + 1 )); _psr
  done
  tput cnorm 2>/dev/null||true
  _erase_lines $(( _n + 1 ))
  printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}  ${GREEN}%s${NC}\n" "$_lbl" "${_o[$_s]}"
  printf -v "$_v" '%s' "${_o[$_s]}"
}

# prompt_multiselect <var_name> <label> <opts_arr_name> [hints_arr_name] [min_select]
# Space=toggle, printable chars=filter, Enter=confirm. Sets $var_name to space-separated values.
prompt_multiselect() {
  local _v="$1" _lbl="$2"; local -n _mo="$3"; local -n _mh="${4:-_mse}" 2>/dev/null
  declare -ga _mse=(); local _min="${5:-0}"
  local _n=${#_mo[@]}; local -a _sel=(); local i
  for (( i=0; i<_n; i++ )); do _sel[$i]=0; done
  local _cur=0 _flt="" _rl=0

  # Render menu to stdout directly (not piped)
  _msr() {
    printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}  ${DIM}(space=toggle, type to filter, enter=confirm)${NC}\n" "$_lbl"
    printf "  ${CYAN}│${NC}  Filter: ${YELLOW}%s${NC}\n" "$_flt"
    local vis=() i; for (( i=0; i<_n; i++ )); do
      local lc="${_mo[$i],,}" lf="${_flt,,}"
      [[ -z "$_flt" || "$lc" == *"$lf"* ]] && vis+=("$i")
    done
    local vi; for (( vi=0; vi<${#vis[@]}; vi++ )); do
      local idx="${vis[$vi]}" ht="${_mh[${vis[$vi]}]:-}"
      local mk="○" cl="$NC"; [[ "${_sel[$idx]}" -eq 1 ]] && mk="◉" && cl="$GREEN"
      if [[ $vi -eq $_cur ]]; then
        printf "  ${CYAN}│${NC}  ${GREEN}❯${NC} ${cl}%s %-22s${NC}  ${DIM}%s${NC}\n" "$mk" "${_mo[$idx]}" "$ht"
      else
        printf "  ${CYAN}│${NC}    ${cl}%s %-22s${NC}  ${DIM}%s${NC}\n" "$mk" "${_mo[$idx]}" "$ht"
      fi
    done
    local cnt=0; for i in "${_sel[@]}"; do cnt=$(( cnt + i )); done
    printf "  ${CYAN}│${NC}  ${DIM}%d selected${NC}\n" "$cnt"
  }
  # Count visible items (run in subshell to capture, does not render)
  _msr_count() {
    local vis=() i; for (( i=0; i<_n; i++ )); do
      local lc="${_mo[$i],,}" lf="${_flt,,}"
      [[ -z "$_flt" || "$lc" == *"$lf"* ]] && vis+=("$i")
    done
    echo "${#vis[@]}"
  }

  tput civis 2>/dev/null||true
  _msr; _rl=$(( $(_msr_count) + 3 ))
  while true; do
    local k; k=$(_read_key)
    local vis_now=(); local i; for (( i=0; i<_n; i++ )); do
      local lc="${_mo[$i],,}" lf="${_flt,,}"
      [[ -z "$_flt" || "$lc" == *"$lf"* ]] && vis_now+=("$i")
    done
    local nv=${#vis_now[@]}
    case "$k" in
      $'\x1b[A'|k) [[ $_cur -gt 0 ]]        && (( _cur-- )) || true ;;
      $'\x1b[B'|j) [[ $_cur -lt $((nv-1)) ]] && (( _cur++ )) || true ;;
      ' ') if [[ $nv -gt 0 && $_cur -lt $nv ]]; then
             local idx="${vis_now[$_cur]}"
             _sel[$idx]=$(( 1 - _sel[$idx] ))
           fi ;;
      $'\x7f'|$'\x08') [[ -n "$_flt" ]] && _flt="${_flt%?}" && _cur=0 ;;
      $'\x03') _wiz_cancel ;;
      '')
        local cnt=0; for i in "${_sel[@]}"; do cnt=$(( cnt + i )); done
        if [[ $cnt -ge $_min ]]; then break
        else printf "  ${YELLOW}⚠${NC}  Select at least %d option(s)\n" "$_min"; fi ;;
      [[:print:]]) _flt+="$k"; _cur=0 ;;
    esac
    _erase_lines "$_rl"; _msr; _rl=$(( $(_msr_count) + 3 ))
  done
  tput cnorm 2>/dev/null||true; _erase_lines "$_rl"
  local result="" i; for (( i=0; i<_n; i++ )); do
    [[ "${_sel[$i]}" -eq 1 ]] && result+="${_mo[$i]} "
  done
  printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}  ${GREEN}%s${NC}\n" "$_lbl" "${result% }"
  printf -v "$_v" '%s' "${result% }"
}

# prompt_text <var_name> <label> [default] [validate_fn]
prompt_text() {
  local _v="$1" _lbl="$2" _def="${3:-}" _val="${4:-}"
  printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}" "$_lbl"
  [[ -n "$_def" ]] && printf "  ${DIM}(default: %s)${NC}" "$_def"
  printf "\n  ${CYAN}│${NC}  "
  local _in; IFS= read -r _in 2>/dev/null; [[ -z "$_in" ]] && _in="$_def"
  if [[ -n "$_val" ]]; then
    local _err; _err=$("$_val" "$_in" 2>&1); local _rc=$?
    while [[ $_rc -ne 0 || -n "$_err" ]]; do
      printf "  ${RED}│${NC}  %s\n  ${CYAN}│${NC}  " "$_err"
      IFS= read -r _in 2>/dev/null; [[ -z "$_in" ]] && _in="$_def"
      _err=$("$_val" "$_in" 2>&1); _rc=$?
    done
  fi
  printf -v "$_v" '%s' "$_in"
}

# prompt_secret <var_name> <label>
prompt_secret() {
  printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}\n  ${CYAN}│${NC}  " "$2"
  local _in; stty -echo 2>/dev/null||true
  IFS= read -r _in 2>/dev/null; stty echo 2>/dev/null||true; printf "\n"
  printf -v "$1" '%s' "$_in"
}

# prompt_confirm <var_name> <label> [default:true|false]
prompt_confirm() {
  local _def="${3:-false}" _hint; [[ "$_def" == "true" ]] && _hint="Y/n" || _hint="y/N"
  printf "  ${CYAN}◇${NC}  ${BOLD}%s${NC}  ${DIM}(%s)${NC} " "$2" "$_hint"
  local _in; IFS= read -r _in 2>/dev/null; _in="${_in,,}"
  local _r="$_def"
  case "$_in" in y|yes) _r="true";; n|no) _r="false";; esac
  printf -v "$1" '%s' "$_r"
}

# prompt_note <title> [line1] [line2] ...
prompt_note() {
  local _t="$1"; shift
  printf "\n  ${CYAN}■${NC}  ${BOLD}Note: %s${NC}\n  ${CYAN}│${NC}\n" "$_t"
  local _l; for _l in "$@"; do printf "  ${CYAN}│${NC}  %s\n" "$_l"; done
  printf "  ${CYAN}│${NC}\n"
}

# prompt_progress <message> <command> [args...]
# Runs command in background with spinner. Returns command exit code.
prompt_progress() {
  local _msg="$1"; shift
  "$@" &
  print_spinner $! "$_msg"
}
