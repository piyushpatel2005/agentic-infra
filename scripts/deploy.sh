#!/usr/bin/env bash
# ==============================================================================
# Central Deployment & Provisioning Orchestrator for OCI Hermes Agent
# ==============================================================================
# Usage:
#   ./scripts/deploy.sh                # Deploys all services & runs setup on hermes-oci
#   ./scripts/deploy.sh --webhook      # Only deploy & restart the GitHub Webhook service
#   ./scripts/deploy.sh --setup        # Only sync & run hermes-setup.sh
#   ./scripts/deploy.sh --host user@ip # Specify a custom remote host
# ==============================================================================

set -euo pipefail

REMOTE_HOST="hermes-oci"
DO_SYNC_ALL=true
DO_RUN_SETUP=false
DO_RESTART_WEBHOOK=true
DO_CHECK_STATUS=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h)
      REMOTE_HOST="$2"
      shift 2
      ;;
    --webhook|-w)
      DO_SYNC_ALL=true
      DO_RUN_SETUP=false
      DO_RESTART_WEBHOOK=true
      shift
      ;;
    --setup|-s)
      DO_SYNC_ALL=true
      DO_RUN_SETUP=true
      DO_RESTART_WEBHOOK=false
      shift
      ;;
    --all|-a)
      DO_SYNC_ALL=true
      DO_RUN_SETUP=true
      DO_RESTART_WEBHOOK=true
      shift
      ;;
    --help)
      cat <<'EOF'
Usage: ./scripts/deploy.sh [OPTIONS]

Options:
  --all, -a            Deploy all scripts/services, run hermes-setup.sh, and restart webhook
  --webhook, -w        Deploy & restart GitHub Webhook service only
  --setup, -s          Sync scripts and run interactive hermes-setup.sh on remote VM
  --host, -h <target>  Target SSH host (default: hermes-oci)
  --help               Show this help message
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

echo "================================================================="
echo "   Hermes Agent Central Deployer -> Target: ${REMOTE_HOST}"
echo "================================================================="

# ------------------------------------------------------------------------------
# 1. Sync Scripts & Systemd Units
# ------------------------------------------------------------------------------
if [ "$DO_SYNC_ALL" = true ]; then
  echo ""
  echo "[Step 1/3] Syncing scripts and systemd unit files to ${REMOTE_HOST}..."

  # Create remote directories
  ssh "${REMOTE_HOST}" "mkdir -p /home/hermes/scripts /tmp/hermes-systemd"

  # Sync all executable scripts
  scp "${REPO_ROOT}/scripts/hermes-github-webhook.py" "${REMOTE_HOST}:/home/hermes/scripts/hermes-github-webhook.py"
  scp "${REPO_ROOT}/scripts/hermes-setup.sh" "${REMOTE_HOST}:/tmp/hermes-setup.sh"
  scp "${REPO_ROOT}/scripts/rotate-provider.sh" "${REMOTE_HOST}:/tmp/rotate-provider.sh"
  scp "${REPO_ROOT}/scripts/hermes-backup.sh" "${REMOTE_HOST}:/tmp/hermes-backup.sh"
  scp "${REPO_ROOT}/scripts/git-mirror.sh" "${REMOTE_HOST}:/tmp/git-mirror.sh"
  scp "${REPO_ROOT}/scripts/check-backup-freshness.sh" "${REMOTE_HOST}:/tmp/check-backup-freshness.sh"

  # Sync systemd unit files
  scp "${REPO_ROOT}/systemd/"* "${REMOTE_HOST}:/tmp/hermes-systemd/"

  # Install scripts to /usr/local/bin and systemd units to /etc/systemd/system/
  ssh -t "${REMOTE_HOST}" "
    chmod +x /home/hermes/scripts/*.py 2>/dev/null || true
    sudo cp /tmp/hermes-setup.sh /usr/local/bin/hermes-setup.sh
    sudo cp /tmp/rotate-provider.sh /usr/local/bin/rotate-provider.sh
    sudo cp /tmp/hermes-backup.sh /usr/local/bin/hermes-backup.sh
    sudo cp /tmp/git-mirror.sh /usr/local/bin/git-mirror.sh
    sudo cp /tmp/check-backup-freshness.sh /usr/local/bin/check-backup-freshness.sh
    sudo chmod 755 /usr/local/bin/*.sh 2>/dev/null || true

    sudo cp /tmp/hermes-systemd/* /etc/systemd/system/
    sudo systemctl daemon-reload
  "
  echo "✓ Scripts & systemd units successfully synced and reloaded."
fi

# ------------------------------------------------------------------------------
# 2. Run Interactive Hermes Setup (Optional / Toggled via --setup or --all)
# ------------------------------------------------------------------------------
if [ "$DO_RUN_SETUP" = true ]; then
  echo ""
  echo "[Step 2/3] Running hermes-setup.sh on ${REMOTE_HOST}..."
  ssh -t "${REMOTE_HOST}" "sudo /usr/local/bin/hermes-setup.sh"
fi

# ------------------------------------------------------------------------------
# 3. Deploy & Restart Webhook Service
# ------------------------------------------------------------------------------
if [ "$DO_RESTART_WEBHOOK" = true ]; then
  echo ""
  echo "[Step 3/3] Enabling and restarting hermes-github-webhook.service..."
  ssh -t "${REMOTE_HOST}" "
    sudo systemctl enable --now hermes-github-webhook.service
    sudo systemctl restart hermes-github-webhook.service
  "
fi

# ------------------------------------------------------------------------------
# Status Verification
# ------------------------------------------------------------------------------
if [ "$DO_CHECK_STATUS" = true ]; then
  echo ""
  echo "--- Active Services Status on ${REMOTE_HOST} ---"
  ssh "${REMOTE_HOST}" "
    systemctl is-active hermes-github-webhook.service >/dev/null && echo '✓ hermes-github-webhook.service : ACTIVE' || echo '✗ hermes-github-webhook.service : INACTIVE'
    systemctl is-active hermes-dashboard.service >/dev/null && echo '✓ hermes-dashboard.service      : ACTIVE' || echo '✗ hermes-dashboard.service      : INACTIVE'
    systemctl is-active hermes-gateway.service >/dev/null && echo '✓ hermes-gateway.service        : ACTIVE' || echo '- hermes-gateway.service        : STOPPED (Telegram)'
  "
fi

echo ""
echo "================================================================="
echo "   Deployment Complete!"
echo "================================================================="
