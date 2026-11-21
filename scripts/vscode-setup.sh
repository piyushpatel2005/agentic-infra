#!/usr/bin/env bash
# ==============================================================================
# VS Code Web Server & Remote Coding Setup Script
# ==============================================================================
# Installs and configures code-server (browser-based VS Code) and the official
# VS Code CLI on the OCI Hermes VM with Python & Jupyter notebook support,
# secured over Tailscale HTTPS.
#
# Usage:
#   sudo /usr/local/bin/vscode-setup.sh         # Install only (do NOT start service)
#   sudo /usr/local/bin/vscode-setup.sh --start # Install AND immediately start service
# ==============================================================================

set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="/home/${HERMES_USER}"
WORKSPACE_DIR="${HERMES_HOME}/workspace"
INTERNAL_PORT="8000"
EXTERNAL_PORT="8443"
AUTH_MODE="none"
AUTH_PASSWORD=""
START_SERVICE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start|-s)
      START_SERVICE=true
      shift
      ;;
    --port|-p)
      INTERNAL_PORT="$2"
      shift 2
      ;;
    --external-port)
      EXTERNAL_PORT="$2"
      shift 2
      ;;
    --auth)
      AUTH_MODE="$2"
      shift 2
      ;;
    --password)
      AUTH_PASSWORD="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--start] [--port 8000] [--external-port 8443] [--auth none|password] [--password <secret>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() { echo "[vscode-setup] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "error: vscode-setup.sh must be run as root (sudo)" >&2
  exit 1
fi

# 1. Install code-server if not already installed
log "Step 1/7: Ensuring code-server is installed..."
if ! command -v code-server >/dev/null 2>&1; then
  log "Downloading and installing code-server..."
  curl -fsSL https://code-server.dev/install.sh | sh
else
  log "code-server is already installed ($(code-server --version | head -n1))."
fi

# 2. Install official VS Code CLI (for optional 'code tunnel' support)
log "Step 2/7: Ensuring official VS Code CLI is installed..."
if ! command -v code >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)
  if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    CLI_ARCH="cli-linux-arm64"
  else
    CLI_ARCH="cli-linux-x64"
  fi
  log "Downloading official VS Code CLI (${CLI_ARCH})..."
  curl -sL "https://update.code.visualstudio.com/latest/${CLI_ARCH}/stable" | tar -xz -C /usr/local/bin
  chmod +x /usr/local/bin/code
  log "VS Code CLI installed at /usr/local/bin/code."
else
  log "VS Code CLI is already installed ($(code --version | head -n1))."
fi

# 3. Configure code-server for hermes user
log "Step 3/7: Generating code-server configuration for user ${HERMES_USER}..."
CONFIG_DIR="${HERMES_HOME}/.config/code-server"
mkdir -p "${CONFIG_DIR}"

cat >"${CONFIG_DIR}/config.yaml" <<EOF
bind-addr: 127.0.0.1:${INTERNAL_PORT}
auth: ${AUTH_MODE}
cert: false
EOF

if [ "${AUTH_MODE}" = "password" ] && [ -n "${AUTH_PASSWORD}" ]; then
  echo "password: ${AUTH_PASSWORD}" >>"${CONFIG_DIR}/config.yaml"
fi

chown -R "${HERMES_USER}:${HERMES_USER}" "${HERMES_HOME}/.config"
chmod 700 "${CONFIG_DIR}"
chmod 600 "${CONFIG_DIR}/config.yaml"
mkdir -p "${WORKSPACE_DIR}"
chown -R "${HERMES_USER}:${HERMES_USER}" "${WORKSPACE_DIR}"

# 4. Install Python and Jupyter extensions for notebook support
log "Step 4/7: Installing Python & Jupyter extensions for code-server..."
runuser -u "${HERMES_USER}" -- code-server --install-extension ms-python.python >/dev/null 2>&1 || true
runuser -u "${HERMES_USER}" -- code-server --install-extension ms-toolsai.jupyter >/dev/null 2>&1 || true

# 5. Set up dedicated systemd service unit
log "Step 5/7: Configuring systemd service unit (code-server.service)..."
cat >/etc/systemd/system/code-server.service <<EOF
[Unit]
Description=VS Code Web Server (code-server)
After=network.target

[Service]
Type=exec
User=${HERMES_USER}
Group=${HERMES_USER}
WorkingDirectory=${WORKSPACE_DIR}
Environment=HOME=${HERMES_HOME}
Environment=PATH=/opt/jupyter-env/bin:${HERMES_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/code-server
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 6. Set up firewall rules for Tailscale and loopback
log "Step 6/7: Configuring iptables for internal port ${INTERNAL_PORT} and external port ${EXTERNAL_PORT}..."
iptables -C INPUT -i lo -p tcp --dport "${INTERNAL_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i lo -p tcp --dport "${INTERNAL_PORT}" -j ACCEPT
iptables -C INPUT -i tailscale0 -p tcp --dport "${EXTERNAL_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i tailscale0 -p tcp --dport "${EXTERNAL_PORT}" -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

# 7. Configure Tailscale Serve (if Tailscale is active)
if command -v tailscale >/dev/null 2>&1; then
  log "Step 7/7: Configuring Tailscale Serve for HTTPS access on port ${EXTERNAL_PORT}..."
  tailscale serve --bg --https="${EXTERNAL_PORT}" "http://127.0.0.1:${INTERNAL_PORT}" >/dev/null 2>&1 || true
fi

echo ""
echo "================================================================="
log "VS Code Server installation and configuration successfully completed!"
echo "================================================================="
echo " Service Name:   code-server.service"
echo " Internal Port:  ${INTERNAL_PORT} (127.0.0.1)"
echo " Tailscale Port: ${EXTERNAL_PORT} (HTTPS over Tailnet)"
echo " Config:         ${CONFIG_DIR}/config.yaml"
echo " Auth Mode:      ${AUTH_MODE}"
echo ""

if [ "$START_SERVICE" = true ]; then
  log "Starting code-server.service..."
  systemctl enable --now code-server.service
  systemctl status code-server.service --no-pager
else
  echo "Service was NOT started (as requested)."
  echo "To start the code-server service whenever you are ready, run:"
  echo "  sudo systemctl enable --now code-server.service"
  echo ""
  echo "To check its status:"
  echo "  sudo systemctl status code-server.service"
fi
echo "================================================================="
