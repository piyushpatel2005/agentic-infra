#!/usr/bin/env bash
# Cloud-init payload (Phase 4): mounts the data volume, adds swap, creates the
# `hermes` user on top of the mount, installs Hermes Agent, fetches dashboard
# credentials from OCI Vault via instance principal, writes config/env, and
# starts the dashboard service. Runs once as root on first boot.
#
# Browser tooling (Lightpanda / Playwright MCP / GitHub MCP) and Tailscale are
# deliberately NOT set up here — they land in later phases against this same
# running instance.
set -euo pipefail

log() { echo "[bootstrap] $*"; }

# shellcheck source=/dev/null
source /etc/hermes/bootstrap.env

MOUNT_POINT=/home/hermes
DATA_DEVICE="${HERMES_DATA_DEVICE:-/dev/oracleoci/oraclevdb}"
SWAP_SIZE_GB="${HERMES_SWAP_SIZE_GB:-4}"
HERMES_USER_NAME="${HERMES_USER:-hermes}"

# --- 1. Wait for the paravirtualized data volume to appear, format once, mount ---
log "waiting for ${DATA_DEVICE}"
for _ in $(seq 1 30); do
  [ -b "$DATA_DEVICE" ] && break
  sleep 2
done
[ -b "$DATA_DEVICE" ] || {
  echo "error: ${DATA_DEVICE} never appeared" >&2
  exit 1
}

if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
  log "formatting ${DATA_DEVICE} (ext4)"
  mkfs.ext4 -F "$DATA_DEVICE"
fi

mkdir -p "$MOUNT_POINT"
DATA_UUID=$(blkid -s UUID -o value "$DATA_DEVICE")
grep -q "$DATA_UUID" /etc/fstab || echo "UUID=${DATA_UUID} ${MOUNT_POINT} ext4 defaults,nofail,_netdev 0 2" >>/etc/fstab
mountpoint -q "$MOUNT_POINT" || mount "$MOUNT_POINT"

# --- 2. Swapfile on the data volume, as an OOM cushion for browser/MCP bursts ---
SWAP_FILE="${MOUNT_POINT}/.swapfile"
if [ ! -f "$SWAP_FILE" ]; then
  log "creating ${SWAP_SIZE_GB}G swapfile"
  fallocate -l "${SWAP_SIZE_GB}G" "$SWAP_FILE"
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
fi
swapon "$SWAP_FILE" 2>/dev/null || true
grep -q "$SWAP_FILE" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >>/etc/fstab
sysctl -w vm.swappiness=10 >/dev/null
if grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
  sed -i 's/^vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
else
  echo 'vm.swappiness=10' >>/etc/sysctl.conf
fi

# --- 3. Create the service user on top of the now-mounted volume ---
if ! id "$HERMES_USER_NAME" >/dev/null 2>&1; then
  log "creating user ${HERMES_USER_NAME}"
  useradd -m -d "$MOUNT_POINT" -s /bin/bash "$HERMES_USER_NAME"
fi

# --- 4. Restrict host-level access to the dashboard port before it exists ---
# Ubuntu's OCI image ships an INPUT chain that only allows 22; add 9119 on
# loopback and the (not-yet-created) tailscale0 interface only. iptables
# accepts a rule for an interface name that doesn't exist yet — it simply
# stays inactive until Phase 5 brings tailscale0 up.
iptables -C INPUT -i lo -p tcp --dport 9119 -j ACCEPT 2>/dev/null ||
  iptables -I INPUT -i lo -p tcp --dport 9119 -j ACCEPT
iptables -C INPUT -i tailscale0 -p tcp --dport 9119 -j ACCEPT 2>/dev/null ||
  iptables -I INPUT -i tailscale0 -p tcp --dport 9119 -j ACCEPT
netfilter-persistent save

# --- 5. Install Hermes Agent as the service user (browser/computer-use deferred to Phase 6) ---
log "installing Hermes Agent"
runuser -u "$HERMES_USER_NAME" -- bash -lc \
  'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser --skip-computer-use'

log "installing web/pty/messaging extras"
runuser -u "$HERMES_USER_NAME" -- bash -lc \
  'cd ~/.hermes/hermes-agent && uv pip install -e ".[web,pty,messaging]"'

# --- 6. Fetch dashboard credentials from OCI Vault via instance principal ---
log "fetching dashboard credentials from Vault"
pip3 install --break-system-packages --quiet oci-cli

DASHBOARD_JSON=$(oci --auth instance_principal vault secret get-secret-bundle \
  --secret-id "$HERMES_OCI_SECRET_OCID_DASHBOARD" \
  --query 'data."secret-bundle-content".content' --raw-output | base64 -d)

DASH_USER=$(jq -r '.username' <<<"$DASHBOARD_JSON")
DASH_PASS=$(jq -r '.password' <<<"$DASHBOARD_JSON")
DASH_SECRET=$(jq -r '.secret' <<<"$DASHBOARD_JSON")

# --- 7. Render config.yaml and .env ---
install -d -o "$HERMES_USER_NAME" -g "$HERMES_USER_NAME" -m 755 "${MOUNT_POINT}/.hermes"
cp /etc/hermes/config.yaml.tmpl "${MOUNT_POINT}/.hermes/config.yaml"
chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "${MOUNT_POINT}/.hermes/config.yaml"

cat >"${MOUNT_POINT}/.hermes/.env" <<EOF
# Dashboard auth (basic provider) — fetched from OCI Vault at boot.
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${DASH_USER}
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${DASH_PASS}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${DASH_SECRET}

# LLM provider API keys — fill these in over SSH, then run \`hermes model\`
# or restart the affected service. Left empty on purpose: provider choice is
# yours to make and change at any time.
OPENROUTER_API_KEY=
NVIDIA_NIM_API_KEY=
MISTRAL_API_KEY=
EOF
chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "${MOUNT_POINT}/.hermes/.env"
chmod 600 "${MOUNT_POINT}/.hermes/.env"

# --- 8. Install and start services ---
cp /etc/hermes/hermes-dashboard.service /etc/systemd/system/hermes-dashboard.service
cp /etc/hermes/hermes-gateway.service /etc/systemd/system/hermes-gateway.service
systemctl daemon-reload
systemctl enable --now hermes-dashboard.service
systemctl enable hermes-gateway.service # left stopped until a platform token is configured (Phase 6)

# --- 9. Best-effort health check, logged for later inspection ---
runuser -u "$HERMES_USER_NAME" -- bash -lc 'hermes doctor' >/var/log/hermes-doctor.log 2>&1 || true

log "bootstrap complete"
