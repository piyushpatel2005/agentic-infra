#!/usr/bin/env bash
# ==============================================================================
# JupyterLab Exploration Environment Setup Script
# ==============================================================================
# Installs and configures a dedicated JupyterLab environment with data science
# libraries (numpy, pandas, matplotlib, seaborn, scipy) and token-free Tailscale
# access.
#
# NOTE: By default, this script performs all installation and configuration
# WITHOUT starting the service, allowing you to start it at your discretion.
#
# Usage:
#   sudo /usr/local/bin/jupyter-setup.sh         # Install only (do NOT start service)
#   sudo /usr/local/bin/jupyter-setup.sh --start # Install AND immediately start service
# ==============================================================================

set -euo pipefail

JUPYTER_VENV="/opt/jupyter-env"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="/home/${HERMES_USER}"
WORKSPACE_DIR="${HERMES_HOME}/workspace"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
START_SERVICE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start|-s)
      START_SERVICE=true
      shift
      ;;
    --venv)
      JUPYTER_VENV="$2"
      shift 2
      ;;
    --port)
      JUPYTER_PORT="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--start] [--venv /path/to/venv] [--port 8888]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() { echo "[jupyter-setup] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "error: jupyter-setup.sh must be run as root (sudo)" >&2
  exit 1
fi

# 1. Ensure required system packages
log "Step 1/6: Ensuring python3-venv and build prerequisites are installed..."
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip iptables-persistent

# 2. Set up Python virtual environment
log "Step 2/6: Creating Python virtual environment at ${JUPYTER_VENV}..."
mkdir -p "$(dirname "$JUPYTER_VENV")"
if [ ! -d "${JUPYTER_VENV}/bin" ]; then
  python3 -m venv "$JUPYTER_VENV"
fi

log "Installing JupyterLab and data exploration packages..."
"${JUPYTER_VENV}/bin/pip" install --upgrade --quiet pip setuptools wheel
"${JUPYTER_VENV}/bin/pip" install --quiet \
  jupyterlab \
  notebook \
  ipykernel \
  ipywidgets \
  numpy \
  pandas \
  matplotlib \
  seaborn \
  scipy

# Symlink binaries to /usr/local/bin for convenient CLI access
ln -sf "${JUPYTER_VENV}/bin/jupyter" /usr/local/bin/jupyter
ln -sf "${JUPYTER_VENV}/bin/jupyter-lab" /usr/local/bin/jupyter-lab

# 3. Configure JupyterLab for token/password-free Tailscale access
log "Step 3/6: Generating JupyterLab configuration for user ${HERMES_USER}..."
mkdir -p "${HERMES_HOME}/.jupyter"
mkdir -p "${WORKSPACE_DIR}"

cat >"${HERMES_HOME}/.jupyter/jupyter_lab_config.py" <<EOF
c = get_config()  # noqa

# Network and listener binding
c.ServerApp.ip = '127.0.0.1'
c.ServerApp.port = ${JUPYTER_PORT}
c.ServerApp.port_retries = 0
c.ServerApp.open_browser = False
c.ServerApp.allow_remote_access = True
c.ServerApp.root_dir = '${WORKSPACE_DIR}'

# Tailscale-authenticated environment: password/token-free access
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.disable_check_xsrf = True

# Default interface
c.LabApp.default_url = '/lab'
EOF

chown -R "${HERMES_USER}:${HERMES_USER}" "${HERMES_HOME}/.jupyter"
chmod 700 "${HERMES_HOME}/.jupyter"
chmod 600 "${HERMES_HOME}/.jupyter/jupyter_lab_config.py"
chown -R "${HERMES_USER}:${HERMES_USER}" "${WORKSPACE_DIR}"

# 4. Set up firewall rules
log "Step 4/6: Configuring iptables for port ${JUPYTER_PORT}..."
iptables -C INPUT -i lo -p tcp --dport "${JUPYTER_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i lo -p tcp --dport "${JUPYTER_PORT}" -j ACCEPT
iptables -C INPUT -i tailscale0 -p tcp --dport "${JUPYTER_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -i tailscale0 -p tcp --dport "${JUPYTER_PORT}" -j ACCEPT
netfilter-persistent save >/dev/null 2>&1 || true

# 5. Set up systemd service unit
log "Step 5/6: Configuring systemd service unit..."
cat >/etc/systemd/system/jupyterlab.service <<EOF
[Unit]
Description=JupyterLab Exploration Environment
After=network.target

[Service]
Type=simple
User=${HERMES_USER}
Group=${HERMES_USER}
WorkingDirectory=${WORKSPACE_DIR}
Environment=HOME=${HERMES_HOME}
Environment=PATH=${JUPYTER_VENV}/bin:${HERMES_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${JUPYTER_VENV}/bin/jupyter lab --config=${HERMES_HOME}/.jupyter/jupyter_lab_config.py
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 6. Configure Tailscale Serve (if Tailscale is active and service was requested to start)
if [ "$START_SERVICE" = true ] && command -v tailscale >/dev/null 2>&1; then
  log "Configuring Tailscale Serve for HTTPS access on port ${JUPYTER_PORT}..."
  # Clean up stale serve port 3100 if present
  tailscale serve --https=3100 off >/dev/null 2>&1 || true
  tailscale serve --bg --https="${JUPYTER_PORT}" "http://127.0.0.1:${JUPYTER_PORT}" >/dev/null 2>&1 || true
fi

echo ""
echo "================================================================="
log "JupyterLab installation and configuration successfully completed!"
echo "================================================================="
echo " Environment: ${JUPYTER_VENV}"
echo " Workspace:   ${WORKSPACE_DIR}"
echo " Config:      ${HERMES_HOME}/.jupyter/jupyter_lab_config.py"
echo " Port:        ${JUPYTER_PORT} (Loopback & Tailscale only)"
echo ""

if [ "$START_SERVICE" = true ]; then
  log "Starting jupyterlab.service..."
  systemctl enable --now jupyterlab.service
  systemctl status jupyterlab.service --no-pager
else
  echo "Service was NOT started (as requested)."
  echo "To start the JupyterLab service whenever you are ready, run:"
  echo "  sudo systemctl enable --now jupyterlab.service"
  echo ""
  echo "To check its status:"
  echo "  sudo systemctl status jupyterlab.service"
fi
echo "================================================================="
