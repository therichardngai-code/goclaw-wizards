#!/usr/bin/env bash
# lib/ports.sh — Port block allocation and conflict detection
# Depends on: nothing (uses ss/netstat/lsof + reads state.json via python3)
# Port blocks of size 10 starting at base ports: API=18790, UI=3000, PG=5432, JAEGER=16686

BLOCK_SIZE=10
BASE_API=18790
BASE_UI=3000
BASE_PG=5432
BASE_JAEGER=16686

WIZARD_HOME="${WIZARD_HOME:-${HOME}/.goclaw-wizard}"

# --- Check if a single port is free ---
# is_port_free <port>  → returns 0 if free, 1 if in use
is_port_free() {
  local port="$1"

  # Try ss first (iproute2, modern Linux)
  if command -v ss >/dev/null 2>&1; then
    ! ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    return 1
  fi

  # Fallback: netstat
  if command -v netstat >/dev/null 2>&1; then
    ! netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    return 1
  fi

  # Fallback: lsof
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    return 1
  fi

  # No port scanner available — assume free (warn only)
  return 0
}

# --- Check if all ports in a block are free ---
# _block_is_free <block_num>  → returns 0 if all 4 base ports + offset are free
_block_is_free() {
  local n="$1"
  is_port_free $(( BASE_API    + n * BLOCK_SIZE )) && \
  is_port_free $(( BASE_UI     + n * BLOCK_SIZE )) && \
  is_port_free $(( BASE_PG     + n * BLOCK_SIZE )) && \
  is_port_free $(( BASE_JAEGER + n * BLOCK_SIZE ))
}

# --- Find blocks already assigned to existing stacks ---
# Prints list of used block numbers (one per line)
find_used_blocks() {
  local stacks_dir="${WIZARD_HOME}/stacks"
  [[ -d "$stacks_dir" ]] || return 0

  for state_file in "${stacks_dir}"/*/state.json; do
    [[ -f "$state_file" ]] || continue
    python3 - "$state_file" <<'EOF' 2>/dev/null
import sys, json
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    block = s.get("port_block")
    if block is not None:
        print(block)
except Exception:
    pass
EOF
  done
}

# --- Allocate a port block for a stack ---
# allocate_port_block <stack_name>
# Sets: PORT_API, PORT_UI, PORT_PG, PORT_JAEGER, PORT_BLOCK
# Reuses existing block if stack already has one in state.json.
allocate_port_block() {
  local stack="$1"
  local state_file="${WIZARD_HOME}/stacks/${stack}/state.json"

  # Reuse if stack already has an assignment
  if [[ -f "$state_file" ]]; then
    local existing_block
    existing_block=$(python3 - "$state_file" <<'EOF' 2>/dev/null
import sys, json
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    b = s.get("port_block")
    if b is not None:
        print(b)
except Exception:
    pass
EOF
    )
    if [[ -n "$existing_block" ]]; then
      PORT_BLOCK="$existing_block"
      _set_ports_from_block "$existing_block"
      return 0
    fi
  fi

  # Find used blocks from other stacks
  local -a used_blocks
  readarray -t used_blocks < <(find_used_blocks | sort -n)

  # Find first free block (try up to block 20 = 20 stacks max)
  local n
  for n in $(seq 0 20); do
    # Skip if block number is already used by another stack
    local already_used=false
    local b; for b in "${used_blocks[@]:-}"; do
      [[ "$b" == "$n" ]] && already_used=true && break
    done
    [[ "$already_used" == "true" ]] && continue

    # Check if all ports in this block are actually free
    if _block_is_free "$n"; then
      PORT_BLOCK="$n"
      _set_ports_from_block "$n"
      return 0
    fi
  done

  print_error "No free port block found (tried blocks 0-20)"
  return 1
}

# --- Set port variables from block number ---
_set_ports_from_block() {
  local n="$1"
  PORT_API=$(( BASE_API    + n * BLOCK_SIZE ))
  PORT_UI=$(( BASE_UI      + n * BLOCK_SIZE ))
  PORT_PG=$(( BASE_PG      + n * BLOCK_SIZE ))
  PORT_JAEGER=$(( BASE_JAEGER + n * BLOCK_SIZE ))
  export PORT_BLOCK PORT_API PORT_UI PORT_PG PORT_JAEGER
}

# --- Read ports from existing state.json ---
# port_block_for_stack <stack_name>  → prints API|UI|PG|JAEGER
port_block_for_stack() {
  local state_file="${WIZARD_HOME}/stacks/${1}/state.json"
  [[ -f "$state_file" ]] || { echo ""; return 1; }

  python3 - "$state_file" <<'EOF' 2>/dev/null
import sys, json
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    p = s.get("ports", {})
    print(f"{p.get('api','?')}|{p.get('ui','?')}|{p.get('pg','?')}|{p.get('jaeger','?')}")
except Exception:
    pass
EOF
}

# --- Check for port conflicts with other processes ---
# check_port_conflicts <stack_name>  → prints conflicting ports (empty = no conflicts)
check_port_conflicts() {
  local state_file="${WIZARD_HOME}/stacks/${1}/state.json"
  [[ -f "$state_file" ]] || return 0

  local ports_raw; ports_raw=$(port_block_for_stack "$1")
  [[ -z "$ports_raw" ]] && return 0

  IFS='|' read -r p_api p_ui p_pg p_jaeger <<< "$ports_raw"

  local conflicts=()
  for port in "$p_api" "$p_ui" "$p_pg" "$p_jaeger"; do
    [[ "$port" == "?" ]] && continue
    is_port_free "$port" || conflicts+=("$port")
  done

  [[ ${#conflicts[@]} -gt 0 ]] && echo "${conflicts[*]}"
  return 0
}
