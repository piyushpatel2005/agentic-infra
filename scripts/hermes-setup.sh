#!/usr/bin/env bash
# One-time interactive setup & configuration script for OCI Hermes Agent.
# Configures LLM model providers (OpenRouter, NVIDIA NIM, OpenAI/ChatGPT),
# Telegram messaging integration, and installs personal/official Hermes skills
# (e.g. official/creative/excalidraw).
#
# Usage:
#   Interactive:      sudo /usr/local/bin/hermes-setup.sh
#   Or from workspace: ./scripts/hermes-setup.sh
#   Non-interactive:   ./scripts/hermes-setup.sh --openrouter-key "sk-or-..." --telegram-token "..." --telegram-users "..."
set -euo pipefail

HERMES_USER_NAME="${HERMES_USER:-hermes}"
HERMES_HOME_DIR=$(getent passwd "$HERMES_USER_NAME" 2>/dev/null | cut -d: -f6 || echo "/home/${HERMES_USER_NAME}")
HERMES_DIR="${HERMES_HOME_DIR}/.hermes"
ENV_FILE="${HERMES_DIR}/.env"
CONFIG_FILE="${HERMES_DIR}/config.yaml"

log() { echo -e "\033[1;34m[hermes-setup]\033[0m $*"; }
warn() { echo -e "\033[1;33m[hermes-setup:warn]\033[0m $*" >&2; }
success() { echo -e "\033[1;32m[hermes-setup:success]\033[0m $*"; }

# Helper to run commands as the hermes user with correct environment & PATH
run_as_hermes() {
  local cmd="$1"
  if [ "$(id -un)" = "$HERMES_USER_NAME" ]; then
    bash -lc "export PATH=\"\$HOME/.local/bin:\$HOME/.hermes/hermes-agent/venv/bin:\$HOME/.hermes/bin:\$PATH\"; ${cmd}"
  else
    runuser -u "$HERMES_USER_NAME" -- bash -lc "export PATH=\"\$HOME/.local/bin:\$HOME/.hermes/hermes-agent/venv/bin:\$HOME/.hermes/bin:\$PATH\"; ${cmd}"
  fi
}

# Helper to run root/systemctl commands
run_as_root() {
  local cmd="$1"
  if [ "$(id -u)" -eq 0 ]; then
    eval "$cmd"
  else
    sudo bash -c "$cmd"
  fi
}

# Helper to update or append KEY=VALUE in .env
update_env_var() {
  local key="$1"
  local val="$2"
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Escape delimiter for sed
    local escaped_val
    escaped_val=$(printf '%s\n' "$val" | sed -e 's/[\/&]/\\&/g')
    sed -i "s/^${key}=.*/${key}=\"${escaped_val}\"/" "$ENV_FILE"
  else
    echo "${key}=\"${val}\"" >> "$ENV_FILE"
  fi
}

# Parse CLI arguments
ARG_OPENROUTER_KEY=""
ARG_NVIDIA_NIM_KEY=""
ARG_OPENAI_KEY=""
ARG_TELEGRAM_TOKEN=""
ARG_TELEGRAM_USERS=""
ARG_DEFAULT_PROVIDER=""
ARG_DEFAULT_MODEL=""
ARG_SKILLS=""
ARG_ENABLE_SYNCTHING=""
NON_INTERACTIVE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --openrouter-key) ARG_OPENROUTER_KEY="$2"; shift 2 ;;
    --nvidia-nim-key) ARG_NVIDIA_NIM_KEY="$2"; shift 2 ;;
    --telegram-token) ARG_TELEGRAM_TOKEN="$2"; shift 2 ;;
    --telegram-users) ARG_TELEGRAM_USERS="$2"; shift 2 ;;
    --default-provider) ARG_DEFAULT_PROVIDER="$2"; shift 2 ;;
    --default-model) ARG_DEFAULT_MODEL="$2"; shift 2 ;;
    --skills) ARG_SKILLS="$2"; shift 2 ;;
    --enable-syncthing) ARG_ENABLE_SYNCTHING=true; shift 1 ;;
    --skip-syncthing) ARG_ENABLE_SYNCTHING=false; shift 1 ;;
    --non-interactive|-y) NON_INTERACTIVE=true; shift 1 ;;
    -h|--help)
      cat <<'EOF'
Usage: hermes-setup.sh [OPTIONS]

Options:
  --openrouter-key <key>     OpenRouter API Key
  --nvidia-nim-key <key>     NVIDIA NIM API Key
  --telegram-token <token>   Telegram Bot Token (from @BotFather)
  --telegram-users <ids>     Allowed Telegram User IDs (comma-separated)
  --default-provider <prov>  Default provider (openrouter, nvidia_nim)
  --default-model <model>    Default model identifier (e.g. openrouter/auto)
  --skills <skills_list>     Comma-separated list of skills to install (optional; syncs via Syncthing)
  --enable-syncthing         Install and enable Syncthing service for peer-to-peer sync
  --skip-syncthing           Skip Syncthing installation and configuration
  --non-interactive, -y      Skip interactive prompts and use provided arguments
  -h, --help                 Show this help message
EOF
      exit 0
      ;;
    *)
      warn "Unknown option: $1"
      shift 1
      ;;
  esac
done

echo "============================================================"
echo "           OCI Hermes Agent Setup & Integration Helper      "
echo "============================================================"
echo ""

if [ ! -d "$HERMES_DIR" ]; then
  warn "Hermes directory ${HERMES_DIR} not found. Creating..."
  mkdir -p "$HERMES_DIR"
fi

if [ ! -f "$ENV_FILE" ]; then
  touch "$ENV_FILE"
fi

# ------------------------------------------------------------
# 1. Tailscale & Dashboard Access
# ------------------------------------------------------------
log "Step 1: Checking Tailscale & Dashboard Access..."

if command -v tailscale >/dev/null 2>&1; then
  if ! tailscale status >/dev/null 2>&1; then
    if [ "$NON_INTERACTIVE" = false ]; then
      echo ""
      echo "--- Tailscale Connection ---"
      echo "Tailscale is installed but not connected."
      read -r -p "Enter Tailscale Auth Key (or press Enter for interactive browser login): " input_ts
      if [ -n "$input_ts" ]; then
        run_as_root "tailscale up --ssh --hostname=hermes-oci --authkey='${input_ts}' --accept-dns=false" || true
      else
        run_as_root "tailscale up --ssh --hostname=hermes-oci --accept-dns=false" || true
      fi
    fi
  else
    success "Tailscale is connected: $(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName' 2>/dev/null || echo 'active')"
  fi

  # Ensure Tailscale HTTPS serve is active for the dashboard
  run_as_root "tailscale serve --bg --https=443 http://127.0.0.1:9119 2>/dev/null || true"
fi

# Ensure dashboard credentials exist in .env
cur_dash_user=$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
if [ -z "$cur_dash_user" ]; then
  log "Generating dashboard credentials..."
  update_env_var "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "admin"
  update_env_var "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "$(openssl rand -base64 16)"
  update_env_var "HERMES_DASHBOARD_BASIC_AUTH_SECRET" "$(openssl rand -base64 32)"
fi

# ------------------------------------------------------------
# 2. LLM Provider Credentials
# ------------------------------------------------------------
log "Step 2: Configuring LLM Providers & API Keys..."

openrouter_key="$ARG_OPENROUTER_KEY"
nvidia_key="$ARG_NVIDIA_NIM_KEY"

if [ "$NON_INTERACTIVE" = false ]; then
  # Read existing keys if present
  cur_or=$(grep -E '^OPENROUTER_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  cur_nim=$(grep -E '^NVIDIA_NIM_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)

  echo ""
  echo "--- [1/2] OpenRouter API Key ---"
  [ -n "$cur_or" ] && echo "Current: ${cur_or:0:8}...${cur_or: -4}"
  read -r -p "Enter OpenRouter API Key (press Enter to keep current): " input_or
  [ -n "$input_or" ] && openrouter_key="$input_or" || openrouter_key="$cur_or"

  echo ""
  echo "--- [2/2] NVIDIA NIM API Key ---"
  [ -n "$cur_nim" ] && echo "Current: ${cur_nim:0:8}...${cur_nim: -4}"
  read -r -p "Enter NVIDIA NIM API Key (press Enter to keep current): " input_nim
  [ -n "$input_nim" ] && nvidia_key="$input_nim" || nvidia_key="$cur_nim"
fi

[ -n "$openrouter_key" ] && update_env_var "OPENROUTER_API_KEY" "$openrouter_key"
[ -n "$nvidia_key" ] && update_env_var "NVIDIA_NIM_API_KEY" "$nvidia_key"

# Configure default model/provider if specified
if [ -n "$ARG_DEFAULT_PROVIDER" ]; then
  log "Setting default provider to ${ARG_DEFAULT_PROVIDER}..."
  run_as_hermes "hermes config set model.provider '${ARG_DEFAULT_PROVIDER}'"
fi

if [ -n "$ARG_DEFAULT_MODEL" ]; then
  log "Setting default model to ${ARG_DEFAULT_MODEL}..."
  run_as_hermes "hermes config set model.default '${ARG_DEFAULT_MODEL}'"
fi

# ------------------------------------------------------------
# 3. Telegram Gateway Setup
# ------------------------------------------------------------
log "Step 3: Configuring Telegram Integration..."

tg_token="$ARG_TELEGRAM_TOKEN"
tg_users="$ARG_TELEGRAM_USERS"

if [ "$NON_INTERACTIVE" = false ]; then
  cur_tg_tok=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  cur_tg_usr=$(grep -E '^TELEGRAM_ALLOWED_USERS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)

  echo ""
  [ -n "$cur_tg_tok" ] && echo "Current Telegram Token: ${cur_tg_tok:0:10}..."
  read -r -p "Enter Telegram Bot Token from @BotFather (or Enter to keep): " input_tg_tok
  [ -n "$input_tg_tok" ] && tg_token="$input_tg_tok" || tg_token="$cur_tg_tok"

  [ -n "$cur_tg_usr" ] && echo "Current Allowed Users: ${cur_tg_usr}"
  read -r -p "Enter Allowed Telegram User ID(s) (comma-separated, e.g. 123456789): " input_tg_usr
  [ -n "$input_tg_usr" ] && tg_users="$input_tg_usr" || tg_users="$cur_tg_usr"
fi

if [ -n "$tg_token" ]; then
  update_env_var "TELEGRAM_BOT_TOKEN" "$tg_token"
  [ -n "$tg_users" ] && update_env_var "TELEGRAM_ALLOWED_USERS" "$tg_users"
  
  log "Enabling telegram in hermes config..."
  run_as_hermes "hermes config set telegram.enabled true"
fi

# ------------------------------------------------------------
# 4. Installing Skills
# ------------------------------------------------------------
log "Step 4: Installing Skills (Optional)..."

skills_to_install="$ARG_SKILLS"
if [ "$NON_INTERACTIVE" = false ]; then
  echo ""
  echo "--- Skill Installation ---"
  echo "Note: If you are using Syncthing, your skills will sync automatically from your Mac."
  read -r -p "Enter skills to install (comma-separated, or press Enter to skip): " input_skills
  [ -n "$input_skills" ] && skills_to_install="$input_skills"
fi

if [ -n "$skills_to_install" ]; then
  IFS=',' read -r -a skill_array <<< "$skills_to_install"
  for skill_entry in "${skill_array[@]}"; do
    skill=$(echo "$skill_entry" | xargs)
    [ -z "$skill" ] && continue
    log "Installing skill: ${skill}..."
    # Support both 'hermes skills install' and 'hermes skill install'
    if run_as_hermes "hermes skills install ${skill} 2>/dev/null || hermes skill install ${skill}"; then
      success "Successfully installed ${skill}"
    else
      warn "Skill install for ${skill} returned non-zero; verifying directory..."
    fi
  done
else
  log "Skipping skill installation (will sync via Syncthing / local skills)."
fi

# ------------------------------------------------------------
# 4. Multi-Device Sync (Syncthing)
# ------------------------------------------------------------
log "Step 4: Configuring Multi-Device Sync (Syncthing)..."

setup_syncthing="$ARG_ENABLE_SYNCTHING"
if [ "$NON_INTERACTIVE" = false ] && [ -z "$setup_syncthing" ]; then
  echo ""
  echo "--- Peer-to-Peer Sync (Syncthing) ---"
  echo "Syncs skills, profiles, sessions, and memories between your local Mac and OCI."
  read -r -p "Enable Syncthing daemon for ${HERMES_USER_NAME}? [Y/n]: " input_sync
  if [[ "$input_sync" =~ ^[Nn] ]]; then
    setup_syncthing=false
  else
    setup_syncthing=true
  fi
fi

syncthing_device_id=""
if [ "$setup_syncthing" = true ]; then
  if ! command -v syncthing >/dev/null 2>&1; then
    log "Installing syncthing package via apt..."
    run_as_root "apt-get update -qq && apt-get install -y -qq syncthing"
  fi

  # Create default .stignore in ~/.hermes if not present
  STIGNORE_FILE="${HERMES_DIR}/.stignore"
  if [ ! -f "$STIGNORE_FILE" ]; then
    log "Creating default ignore list (${STIGNORE_FILE})..."
    cat >"$STIGNORE_FILE" <<'STIGNORE'
// 1. Never sync lock files, sockets, PIDs, or active SQLite DBs (causes conflicts)
(?d)*.lock
(?d)*.sock
(?d)*.pid
(?d)*.db
(?d)*.db-shm
(?d)*.db-wal
(?d)*.sync-conflict-*

// 2. Never sync machine-specific runtimes, tools, caches, backups, or logs
(?d)cache
(?d)audio_cache
(?d)image_cache
(?d)logs
(?d)*.log
(?d)backups
(?d).curator_backups
(?d)tools
(?d)environments
(?d)installs
(?d)source-checks
(?d)plugin-update-checks
(?d)terminal-sessions
(?d)hermes-agent
(?d)bin
(?d)node
(?d)runtime
(?d)sandboxes
(?d)desktop
(?d)desktop-plugins
(?d)models_dev_cache.*
(?d)provider_models_cache.json
(?d)context_length_cache.yaml
(?d)processes.json
(?d)spawn-ledger.json
(?d)gateway*

// 3. WHITELIST: Only sync skills, profiles, memories, sessions, and persona
!/skills
!/skills/**
!/profiles
!/profiles/**
!/memories
!/memories/**
!/sessions
!/sessions/**
!/SOUL.md
!/active_profile

// 4. Ignore all other root files (.env, auth.json, internal databases)
*
STIGNORE
  fi

  log "Enabling and starting syncthing@${HERMES_USER_NAME}.service..."
  run_as_root "systemctl enable --now syncthing@${HERMES_USER_NAME}.service 2>/dev/null || true"
  run_as_root "systemctl restart syncthing@${HERMES_USER_NAME}.service 2>/dev/null || true"

  # Allow service a moment to initialize device keys
  sleep 2
  syncthing_device_id=$(run_as_hermes "syncthing --device-id 2>/dev/null" || true)
fi

# ------------------------------------------------------------
# 5. File Ownership & Permissions
# ------------------------------------------------------------
log "Step 5: Ensuring secure file permissions..."

if [ "$(id -u)" -eq 0 ]; then
  chown -R "${HERMES_USER_NAME}:${HERMES_USER_NAME}" "${HERMES_HOME_DIR}/.hermes"
  chmod 600 "$ENV_FILE"
  [ -f "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE"
else
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  [ -f "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE" 2>/dev/null || true
fi

# ------------------------------------------------------------
# 6. Service Restarts & Health Check
# ------------------------------------------------------------
log "Step 6: Verifying configuration & reloading services..."

run_as_hermes "hermes doctor --fix 2>/dev/null || true"

if [ -n "$tg_token" ]; then
  log "Enabling and restarting hermes-gateway.service..."
  run_as_root "systemctl enable --now hermes-gateway.service 2>/dev/null || true"
  run_as_root "systemctl restart hermes-gateway.service 2>/dev/null || true"
fi

log "Restarting hermes-dashboard.service..."
run_as_root "systemctl restart hermes-dashboard.service 2>/dev/null || true"

echo ""
echo "============================================================"
success "Hermes setup and configuration complete!"
echo "============================================================"
echo ""
echo "Summary of configured components:"
echo " - Environment: ${ENV_FILE}"
echo " - Skills: $(run_as_hermes "hermes skill list 2>/dev/null || hermes skills list 2>/dev/null || echo 'Checked'")"
if [ -n "$tg_token" ]; then
  echo " - Telegram Gateway: Active (Allowed Users: ${tg_users:-all})"
fi
if [ "$setup_syncthing" = true ]; then
  echo " - Syncthing: Active (Service: syncthing@${HERMES_USER_NAME}.service)"
  [ -n "$syncthing_device_id" ] && echo "   Device ID: ${syncthing_device_id}"
  echo "   Documentation: see docs/syncthing.md for pairing steps."
fi
echo ""
