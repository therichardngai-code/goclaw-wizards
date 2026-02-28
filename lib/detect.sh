#!/usr/bin/env bash
# lib/detect.sh — OS, architecture, distro, and Docker group detection
# Depends on: nothing (reads /etc/os-release, uname, groups)
# Exports: GOCLAW_OS, GOCLAW_ARCH, GOCLAW_DISTRO, GOCLAW_DOCKER_GID

# --- OS Detection ---
# Sets GOCLAW_OS: linux | macos | wsl
detect_os() {
  case "$(uname -s)" in
    Darwin) GOCLAW_OS="macos" ;;
    Linux)
      # Check for WSL via /proc/version
      if [[ -f /proc/version ]] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
        GOCLAW_OS="wsl"
      else
        GOCLAW_OS="linux"
      fi
      ;;
    *) GOCLAW_OS="linux" ;;  # best-effort fallback
  esac
  export GOCLAW_OS
}

# --- Architecture Detection ---
# Sets GOCLAW_ARCH: amd64 | arm64
detect_arch() {
  case "$(uname -m)" in
    x86_64)           GOCLAW_ARCH="amd64" ;;
    aarch64|arm64)    GOCLAW_ARCH="arm64" ;;
    *)                GOCLAW_ARCH="amd64" ;;  # fallback
  esac
  export GOCLAW_ARCH
}

# --- Distro Detection ---
# Sets GOCLAW_DISTRO: ubuntu | debian | fedora | arch | alpine | macos | unknown
detect_distro() {
  if [[ "${GOCLAW_OS:-}" == "macos" ]]; then
    GOCLAW_DISTRO="macos"
    export GOCLAW_DISTRO
    return
  fi

  if [[ -f /etc/os-release ]]; then
    local id
    id=$(. /etc/os-release && echo "${ID:-unknown}")
    case "$id" in
      ubuntu)        GOCLAW_DISTRO="ubuntu" ;;
      debian)        GOCLAW_DISTRO="debian" ;;
      fedora|rhel|centos|rocky|alma) GOCLAW_DISTRO="fedora" ;;
      arch|manjaro)  GOCLAW_DISTRO="arch" ;;
      alpine)        GOCLAW_DISTRO="alpine" ;;
      *)             GOCLAW_DISTRO="unknown" ;;
    esac
  else
    GOCLAW_DISTRO="unknown"
  fi
  export GOCLAW_DISTRO
}

# --- Docker Group Detection ---
# Sets GOCLAW_DOCKER_GID: numeric GID of docker group, or empty if not found
detect_docker_group() {
  local gid
  gid=$(getent group docker 2>/dev/null | cut -d: -f3) || true
  GOCLAW_DOCKER_GID="${gid:-}"
  export GOCLAW_DOCKER_GID
}

# --- Combined Detection ---
detect_all() {
  detect_os
  detect_arch
  detect_distro
  detect_docker_group
}

# --- Helper: Check if user is in docker group ---
# Returns 0 if user can run docker without sudo
user_in_docker_group() {
  groups 2>/dev/null | grep -qw docker
}

# --- Helper: Check if running in CI ---
is_ci() {
  [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${JENKINS_URL:-}" ]]
}
