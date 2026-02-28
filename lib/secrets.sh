#!/usr/bin/env bash
# lib/secrets.sh — Cross-platform secret store: macOS Keychain > secret-tool > .secrets file
# Depends on: detect.sh (GOCLAW_OS), stack.sh (stack_dir)
# Key naming: goclaw-{stack}:{KEY_NAME}

SECRETS_BACKEND=""  # set by detect_secrets_backend()

# --- Backend Detection ---
# Sets SECRETS_BACKEND: keychain | secret-tool | file
detect_secrets_backend() {
  [[ -n "$SECRETS_BACKEND" ]] && return  # already detected

  if [[ "${GOCLAW_OS:-}" == "macos" ]]; then
    SECRETS_BACKEND="keychain"
  elif command -v secret-tool >/dev/null 2>&1; then
    SECRETS_BACKEND="secret-tool"
  else
    SECRETS_BACKEND="file"
  fi
  export SECRETS_BACKEND
}

# --- Secret Store ---
# secret_set <stack> <key> <value>
secret_set() {
  local stack="$1" key="$2" value="$3"
  detect_secrets_backend

  case "$SECRETS_BACKEND" in
    keychain)
      security add-generic-password \
        -a "goclaw-${stack}" -s "${key}" -w "${value}" -U \
        2>/dev/null || {
        # Fallback to file if keychain fails (e.g. permission prompt denied)
        _secret_file_set "$stack" "$key" "$value"
      }
      ;;
    secret-tool)
      printf '%s' "${value}" | \
        secret-tool store \
          --label "goclaw-${stack}:${key}" \
          service goclaw-wizard \
          account "${stack}:${key}" \
          2>/dev/null || {
        _secret_file_set "$stack" "$key" "$value"
      }
      ;;
    file)
      _secret_file_set "$stack" "$key" "$value"
      ;;
  esac
}

# --- Secret Retrieve ---
# secret_get <stack> <key>  → prints value or empty string
secret_get() {
  local stack="$1" key="$2"
  detect_secrets_backend

  case "$SECRETS_BACKEND" in
    keychain)
      local val
      val=$(security find-generic-password \
        -a "goclaw-${stack}" -s "${key}" -w 2>/dev/null) || true
      # Fallback to file if not in keychain
      if [[ -z "$val" ]]; then
        val=$(_secret_file_get "$stack" "$key")
      fi
      echo "$val"
      ;;
    secret-tool)
      local val
      val=$(secret-tool lookup \
        service goclaw-wizard \
        account "${stack}:${key}" 2>/dev/null) || true
      if [[ -z "$val" ]]; then
        val=$(_secret_file_get "$stack" "$key")
      fi
      echo "$val"
      ;;
    file)
      _secret_file_get "$stack" "$key"
      ;;
  esac
}

# --- File Backend Helpers ---
_secrets_file_path() {
  echo "${WIZARD_HOME:-${HOME}/.goclaw-wizard}/stacks/$1/.secrets"
}

_secret_file_set() {
  local stack="$1" key="$2" value="$3"
  local file; file=$(_secrets_file_path "$stack")
  mkdir -p "$(dirname "$file")"
  touch "$file" && chmod 600 "$file"

  # Replace existing key or append
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Use temp file for safe in-place edit (portable)
    local tmp; tmp="${file}.tmp"
    grep -v "^${key}=" "$file" > "$tmp" && mv "$tmp" "$file"
    chmod 600 "$file"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$file"
}

_secret_file_get() {
  local stack="$1" key="$2"
  local file; file=$(_secrets_file_path "$stack")
  [[ -f "$file" ]] || { echo ""; return; }
  grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | head -1
}

# --- Write All Secrets to .secrets File for Docker Compose ---
# secrets_write_file <stack>
# Writes current shell env secrets to .secrets file (chmod 600).
# Called right before docker compose up. Env vars must already be set.
secrets_write_file() {
  local stack="$1"
  local file; file=$(_secrets_file_path "$stack")
  mkdir -p "$(dirname "$file")"

  cat > "$file" <<EOF
GOCLAW_GATEWAY_TOKEN=$(secret_get "$stack" "GOCLAW_GATEWAY_TOKEN")
GOCLAW_ENCRYPTION_KEY=$(secret_get "$stack" "GOCLAW_ENCRYPTION_KEY")
POSTGRES_PASSWORD=$(secret_get "$stack" "POSTGRES_PASSWORD")
EOF
  chmod 600 "$file"
}

# --- Load All Secrets into Shell ---
# secrets_load <stack>  — sources .secrets file into current shell
secrets_load() {
  local file; file=$(_secrets_file_path "$1")
  if [[ -f "$file" ]]; then
    # shellcheck source=/dev/null
    set -a; source "$file"; set +a
  fi
}

# --- Check If Stack Has Core Secrets ---
# secrets_exist <stack>  → returns 0 if all 3 core secrets present
secrets_exist() {
  local stack="$1"
  local gt; gt=$(secret_get "$stack" "GOCLAW_GATEWAY_TOKEN")
  local ek; ek=$(secret_get "$stack" "GOCLAW_ENCRYPTION_KEY")
  local pp; pp=$(secret_get "$stack" "POSTGRES_PASSWORD")
  [[ -n "$gt" && -n "$ek" && -n "$pp" ]]
}

# --- Generate Core Secrets ---
# generate_stack_secrets <stack>  — creates GATEWAY_TOKEN, ENCRYPTION_KEY, POSTGRES_PASSWORD
# Skips generation if secrets already exist (reinstall reuse).
generate_stack_secrets() {
  local stack="$1"
  if secrets_exist "$stack"; then
    print_info "Reusing existing secrets for stack '${stack}'"
    return 0
  fi

  local gw_token; gw_token=$(openssl rand -hex 16)    # 32 hex chars
  local enc_key;  enc_key=$(openssl rand -hex 32)      # 64 hex chars
  local pg_pass;  pg_pass=$(openssl rand -hex 16)      # 32 hex chars

  secret_set "$stack" "GOCLAW_GATEWAY_TOKEN"  "$gw_token"
  secret_set "$stack" "GOCLAW_ENCRYPTION_KEY" "$enc_key"
  secret_set "$stack" "POSTGRES_PASSWORD"     "$pg_pass"

  # Export for use in current shell session
  export GOCLAW_GATEWAY_TOKEN="$gw_token"
  export GOCLAW_ENCRYPTION_KEY="$enc_key"
  export POSTGRES_PASSWORD="$pg_pass"
}
