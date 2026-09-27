#!/usr/bin/env bash
# Deploy or update the Hermes GitHub Webhook service on OCI VM
# Usage: ./scripts/deploy-webhook.sh [remote_host] (default: hermes-oci)

set -euo pipefail

REMOTE_HOST="${1:-hermes-oci}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Deploying Hermes GitHub Webhook Service to ${REMOTE_HOST} ==="

# 1. Copy updated script and systemd unit
echo "[1/3] Copying files to ${REMOTE_HOST}..."
scp "${REPO_ROOT}/scripts/hermes-github-webhook.py" "${REMOTE_HOST}:/home/hermes/scripts/hermes-github-webhook.py"
scp "${REPO_ROOT}/systemd/hermes-github-webhook.service" "${REMOTE_HOST}:/tmp/hermes-github-webhook.service"

# 2. Update permissions and systemd unit
echo "[2/3] Installing systemd unit and reloading..."
ssh -t "${REMOTE_HOST}" "
  chmod +x /home/hermes/scripts/hermes-github-webhook.py &&
  sudo cp /tmp/hermes-github-webhook.service /etc/systemd/system/ &&
  sudo systemctl daemon-reload &&
  sudo systemctl restart hermes-github-webhook.service
"

# 3. Check status
echo "[3/3] Checking service status..."
ssh "${REMOTE_HOST}" "systemctl is-active hermes-github-webhook.service && echo '✓ Service is running!' || journalctl -u hermes-github-webhook.service -n 15 --no-pager"

echo "=== Deployment Complete ==="
