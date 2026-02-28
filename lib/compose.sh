#!/usr/bin/env bash
# lib/compose.sh — Docker Compose overlay builder and compose command wrappers
# Depends on: colors.sh (print_error, print_info)
# CRITICAL: Never write a custom docker-compose.yml — always use official GoClaw overlays

GOCLAW_REPO_URL="${GOCLAW_REPO_URL:-https://github.com/nextlevelbuilder/goclaw.git}"

# --- Overlay Builder ---
# build_overlay_args <goclaw_dir> <mode> <features>
# Populates global GOCLAW_OVERLAY_ARGS array with -f flags for docker compose.
#   mode:     "managed" | "standalone"
#   features: comma-separated subset of "ui,otel,sandbox,tailscale"
build_overlay_args() {
  local goclaw_dir="$1" mode="$2" features="${3:-}"

  GOCLAW_OVERLAY_ARGS=("-f" "${goclaw_dir}/docker-compose.yml")

  [[ "$mode" == "managed" ]]         && GOCLAW_OVERLAY_ARGS+=("-f" "${goclaw_dir}/docker-compose.managed.yml")
  [[ "$mode" == "standalone" ]]      && GOCLAW_OVERLAY_ARGS+=("-f" "${goclaw_dir}/docker-compose.standalone.yml")
  [[ "$features" == *"ui"* ]]        && GOCLAW_OVERLAY_ARGS+=("-f" "${goclaw_dir}/docker-compose.selfservice.yml")
  [[ "$features" == *"otel"* ]]      && GOCLAW_OVERLAY_ARGS+=("-f" "${goclaw_dir}/docker-compose.otel.yml")
  [[ "$features" == *"sandbox"* ]]   && GOCLAW_OVERLAY_ARGS+=("-f" "${goclaw_dir}/docker-compose.sandbox.yml")
  [[ "$features" == *"tailscale"* ]] && GOCLAW_OVERLAY_ARGS+=("-f" "${goclaw_dir}/docker-compose.tailscale.yml")

  # Validate that base overlay files exist
  local f; for f in "${GOCLAW_OVERLAY_ARGS[@]}"; do
    [[ "$f" == "-f" ]] && continue
    if [[ ! -f "$f" ]]; then
      print_error "Overlay file not found: $f"
      print_info  "Ensure GoClaw repo is fully cloned: ${GOCLAW_REPO_URL}"
      return 1
    fi
  done
  return 0
}

# --- Internal: base docker compose command for a stack ---
# _dc <stack> <goclaw_dir> <mode> <features>  → populates GOCLAW_OVERLAY_ARGS and prints project args
_dc_base() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}"
  build_overlay_args "$goclaw_dir" "$mode" "$features" || return 1
  # Return: caller uses: docker compose --project-name "goclaw-${stack}" "${GOCLAW_OVERLAY_ARGS[@]}" ...
}

# --- compose_up <stack> <goclaw_dir> <mode> <features> <env_file> ---
# Runs docker compose up -d --build with official overlays.
compose_up() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}" env_file="$5"
  _dc_base "$stack" "$goclaw_dir" "$mode" "$features" || return 1

  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    --env-file "$env_file" \
    up -d --build
}

# --- compose_down <stack> <goclaw_dir> <mode> <features> [remove_volumes:false] ---
compose_down() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}" volumes="${5:-false}"
  _dc_base "$stack" "$goclaw_dir" "$mode" "$features" || return 1

  local vol_flag=()
  [[ "$volumes" == "true" ]] && vol_flag=("--volumes")

  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    down "${vol_flag[@]}"
}

# --- compose_restart <stack> <goclaw_dir> <mode> <features> [service] ---
# If service specified, restart only that container; otherwise restart all.
compose_restart() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}" service="${5:-}"
  _dc_base "$stack" "$goclaw_dir" "$mode" "$features" || return 1

  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    restart ${service:+"$service"}
}

# --- compose_logs <stack> <goclaw_dir> <mode> <features> [service:goclaw] [follow:true] ---
compose_logs() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}"
  local service="${5:-goclaw}" follow="${6:-true}"
  _dc_base "$stack" "$goclaw_dir" "$mode" "$features" || return 1

  local follow_flag=()
  [[ "$follow" == "true" ]] && follow_flag=("-f")

  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    logs "${follow_flag[@]}" "$service"
}

# --- compose_ps <stack> <goclaw_dir> <mode> <features> ---
# Prints service status table as JSON.
compose_ps() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}"
  _dc_base "$stack" "$goclaw_dir" "$mode" "$features" || return 1

  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    ps --format json 2>/dev/null || \
  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    ps  # fallback: human-readable if JSON not supported
}

# --- compose_upgrade <stack> <goclaw_dir> <mode> <features> <env_file> ---
# Runs DB migration via official upgrade overlay, then rebuilds all services.
compose_upgrade() {
  local stack="$1" goclaw_dir="$2" mode="$3" features="${4:-}" env_file="$5"
  _dc_base "$stack" "$goclaw_dir" "$mode" "$features" || return 1

  local upgrade_overlay="${goclaw_dir}/docker-compose.upgrade.yml"
  if [[ ! -f "$upgrade_overlay" ]]; then
    print_error "Upgrade overlay not found: ${upgrade_overlay}"
    return 1
  fi

  # Step 1: run one-shot DB migration container
  docker compose \
    --project-name "goclaw-${stack}" \
    "${GOCLAW_OVERLAY_ARGS[@]}" \
    -f "$upgrade_overlay" \
    --env-file "$env_file" \
    run --rm upgrade || {
    print_error "Database migration failed for stack '${stack}'"
    return 1
  }

  # Step 2: rebuild and restart services with new image
  compose_up "$stack" "$goclaw_dir" "$mode" "$features" "$env_file"
}
