#!/usr/bin/env bash
# lib/deps.sh — Dependency checks with OS-specific install hints
# Depends on: detect.sh (GOCLAW_DISTRO), colors.sh (print_error, print_warn, print_success)

# --- OS-specific install hints ---
# dep_install_hint <dep_name>
dep_install_hint() {
  local dep="$1" distro="${GOCLAW_DISTRO:-unknown}" os="${GOCLAW_OS:-linux}"

  case "$dep" in
    docker)
      case "$distro" in
        ubuntu|debian) echo "sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin" ;;
        fedora)        echo "sudo dnf install -y docker docker-compose-plugin && sudo systemctl enable --now docker" ;;
        arch)          echo "sudo pacman -S docker docker-compose && sudo systemctl enable --now docker" ;;
        alpine)        echo "sudo apk add docker docker-compose && sudo rc-update add docker && sudo service docker start" ;;
        macos)         echo "brew install --cask docker  # or download Docker Desktop from docker.com" ;;
        *)             echo "See https://docs.docker.com/engine/install/" ;;
      esac ;;
    git)
      case "$distro" in
        ubuntu|debian) echo "sudo apt-get install -y git" ;;
        fedora)        echo "sudo dnf install -y git" ;;
        arch)          echo "sudo pacman -S git" ;;
        alpine)        echo "sudo apk add git" ;;
        macos)         echo "brew install git  # or: xcode-select --install" ;;
        *)             echo "See https://git-scm.com/downloads" ;;
      esac ;;
    python3)
      case "$distro" in
        ubuntu|debian) echo "sudo apt-get install -y python3" ;;
        fedora)        echo "sudo dnf install -y python3" ;;
        arch)          echo "sudo pacman -S python" ;;
        alpine)        echo "sudo apk add python3" ;;
        macos)         echo "brew install python3" ;;
        *)             echo "See https://www.python.org/downloads/" ;;
      esac ;;
    openssl)
      case "$distro" in
        ubuntu|debian) echo "sudo apt-get install -y openssl" ;;
        fedora)        echo "sudo dnf install -y openssl" ;;
        arch)          echo "sudo pacman -S openssl" ;;
        alpine)        echo "sudo apk add openssl" ;;
        macos)         echo "brew install openssl" ;;
        *)             echo "See https://www.openssl.org/" ;;
      esac ;;
    curl)
      case "$distro" in
        ubuntu|debian) echo "sudo apt-get install -y curl" ;;
        fedora)        echo "sudo dnf install -y curl" ;;
        arch)          echo "sudo pacman -S curl" ;;
        alpine)        echo "sudo apk add curl" ;;
        macos)         echo "brew install curl" ;;
        *)             echo "See https://curl.se/download.html" ;;
      esac ;;
    ss|netstat|lsof) echo "Install iproute2 (Linux) or net-tools for port scanning" ;;
    *) echo "Install '$dep' via your system package manager" ;;
  esac
}

# --- Single dependency check ---
# check_dep <name> <min_version_string_or_empty> <install_hint_or_empty>
# Returns 0 if present, 1 if missing. Prints error with hint on failure.
check_dep() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    return 0
  fi
  print_error "Missing dependency: ${BOLD}${name}${NC}"
  local hint; hint=$(dep_install_hint "$name")
  [[ -n "$hint" ]] && print_step "Install: ${hint}"
  return 1
}

# --- Docker Compose v2 check ---
# Returns 0 if docker compose v2 plugin available, 1 otherwise
check_docker_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    # Verify it is actually v2 (output contains "v2" or major >= 2)
    local ver; ver=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    local major; major=$(echo "$ver" | cut -d. -f1)
    if [[ "${major:-0}" -ge 2 ]]; then
      return 0
    fi
  fi
  # Check if v1 binary exists (docker-compose hyphen) and warn
  if command -v docker-compose >/dev/null 2>&1; then
    print_warn "Found legacy 'docker-compose' (v1). GoClaw Wizard requires Docker Compose v2 plugin."
    print_step "Upgrade: sudo apt-get install docker-compose-plugin  # Ubuntu/Debian"
    print_step "         https://docs.docker.com/compose/migrate/"
  else
    print_error "Docker Compose v2 plugin not found."
    print_step "Install: $(dep_install_hint docker)"
  fi
  return 1
}

# --- All dependencies check ---
# check_all_deps
# Returns count of missing dependencies (0 = all good)
check_all_deps() {
  local missing=0

  print_step "Checking dependencies..."

  # Docker daemon
  check_dep "docker" || { missing=$(( missing + 1 )); }
  # Docker Compose v2 plugin
  check_docker_compose_v2 || { missing=$(( missing + 1 )); }
  # Git
  check_dep "git"     || { missing=$(( missing + 1 )); }
  # OpenSSL (for secret generation)
  check_dep "openssl" || { missing=$(( missing + 1 )); }
  # Python 3
  check_dep "python3" || { missing=$(( missing + 1 )); }
  # Curl (for health checks, Telegram API)
  check_dep "curl"    || { missing=$(( missing + 1 )); }

  # Port scanning tool (at least one required)
  if ! command -v ss >/dev/null 2>&1 && \
     ! command -v netstat >/dev/null 2>&1 && \
     ! command -v lsof >/dev/null 2>&1; then
    print_warn "No port scanner found (ss/netstat/lsof). Port conflict detection may not work."
    print_step "Install: sudo apt-get install iproute2  # Ubuntu/Debian"
  fi

  # Docker daemon running check
  if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    print_error "Docker daemon is not running."
    print_step "Start: sudo systemctl start docker  # Linux"
    print_step "       Open Docker Desktop           # macOS/Windows"
    missing=$(( missing + 1 ))
  fi

  if [[ $missing -eq 0 ]]; then
    print_success "All dependencies satisfied"
  else
    print_error "${missing} dependency check(s) failed"
  fi

  return $missing
}
