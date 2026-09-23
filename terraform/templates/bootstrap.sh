#!/usr/bin/env bash
# Cloud-init payload: mounts the data volume, adds swap, creates the `hermes`
# user on top of the mount, installs Hermes Agent and its agent tooling
# (browser, Playwright MCP, GitHub CLI/MCP), joins the tailnet and fronts the
# dashboard with `tailscale serve` HTTPS, fetches secrets from OCI Vault via
# instance principal, writes config/env, and starts the dashboard + provider
# rotation cron. Runs once as root on first boot.
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
if ! id "$HERMES_USER_NAME" > /dev/null 2>&1; then
  log "creating user ${HERMES_USER_NAME}"
  # -M skips mkdir (mount point already exists); we chown it explicitly below.
  useradd -M -d "$MOUNT_POINT" -s /bin/bash "$HERMES_USER_NAME"
fi
# Always chown: useradd skips ownership when the directory pre-exists (Step 1
# created /home/hermes as root before the user existed).
chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "$MOUNT_POINT"

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

# --- 5. Install Hermes Agent as the service user (own browser tooling set up in step 9) ---
log "installing Hermes Agent"
runuser -u "$HERMES_USER_NAME" -- bash -lc \
  'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser --skip-computer-use'

log "installing web/pty/messaging extras"
# The Hermes installer uses 'venv/' (no dot) and puts the hermes wrapper at
# ~/.local/bin/hermes. Target the existing venv explicitly with --python.
runuser -u "$HERMES_USER_NAME" -- bash -lc \
  'export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:$HOME/.hermes/bin:$PATH" && \
   /home/hermes/.hermes/bin/uv pip install --python ~/.hermes/hermes-agent/venv/bin/python -e ~/.hermes/hermes-agent/".[web,pty,messaging]"'

# Wrapper script in /usr/local/bin/hermes so operators can run `hermes` commands
# directly with proper user context, environment, and TTY pass-through.
cat >/usr/local/bin/hermes <<'EOF'
#!/usr/bin/env bash
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME=$(getent passwd "$HERMES_USER" 2>/dev/null | cut -d: -f6)
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_BIN="${HERMES_HOME}/.hermes/hermes-agent/venv/bin/hermes"

if [ "$(id -un)" = "$HERMES_USER" ]; then
  exec "$HERMES_BIN" "$@"
else
  exec sudo -u "$HERMES_USER" -H "$HERMES_BIN" "$@"
fi
EOF
chmod 755 /usr/local/bin/hermes

# --- 6. Fetch Vault secrets (dashboard credentials + Tailscale auth key) ---
log "fetching secrets from Vault"
# Install oci-cli in an isolated venv to avoid conflicts with Debian's urllib3
# (pip3 install --break-system-packages fails because urllib3 has no RECORD file).
# python3-venv is not included in the OCI Ubuntu 24.04 image by default.
apt-get install -y -qq python3-venv
python3 -m venv /opt/oci-cli-env
/opt/oci-cli-env/bin/pip install --quiet oci-cli

# Smoke-test instance principal auth before attempting secret fetches.
# Logs the exact OCI error so the console reveals the root cause without SSH.
log "smoke-testing instance principal auth..."
for _ip_attempt in 1 2 3 4 5; do
  _ip_out=$(/opt/oci-cli-env/bin/oci iam region list --auth instance_principal 2>&1) && {
    log "instance principal auth: OK"; break
  }
  log "instance principal not ready (${_ip_attempt}/5): ${_ip_out}"
  [ "$_ip_attempt" -lt 5 ] && sleep 10
done

fetch_secret() {
  local secret_id="$1" attempt output rc
  for attempt in $(seq 1 10); do
    output=$(/opt/oci-cli-env/bin/oci --auth instance_principal secrets secret-bundle get \
      --secret-id "$secret_id" \
      --query 'data."secret-bundle-content".content' --raw-output 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && printf '%s' "$output" | base64 -d 2>/dev/null; then
      return 0
    fi
    log "fetch_secret attempt ${attempt}/10 failed (rc=${rc}): ${output}"
    sleep 6
  done
  echo "error: fetch_secret failed after 10 attempts for secret ${secret_id}" >&2
  return 1
}

DASHBOARD_JSON=$(fetch_secret "$HERMES_OCI_SECRET_OCID_DASHBOARD")
DASH_USER=$(jq -r '.username' <<<"$DASHBOARD_JSON")
DASH_PASS=$(jq -r '.password' <<<"$DASHBOARD_JSON")
DASH_SECRET=$(jq -r '.secret' <<<"$DASHBOARD_JSON")

TAILSCALE_AUTHKEY=$(fetch_secret "$HERMES_OCI_SECRET_OCID_TAILSCALE")

GITHUB_PAT=""
if [ -n "${HERMES_OCI_SECRET_OCID_GITHUB_PAT:-}" ]; then
  GITHUB_PAT=$(fetch_secret "$HERMES_OCI_SECRET_OCID_GITHUB_PAT")
fi

# --- 7. Install Tailscale, join the tailnet, and front the dashboard with HTTPS ---
log "installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh

tailscale up --ssh --hostname=hermes-oci --authkey="$TAILSCALE_AUTHKEY" --accept-dns=false

# Re-apply the tailscale0 firewall rule now that the interface actually exists
# (the Phase 4 rule above was accepted but inactive until now).
iptables -C INPUT -i tailscale0 -p tcp --dport 9119 -j ACCEPT 2>/dev/null ||
  iptables -I INPUT -i tailscale0 -p tcp --dport 9119 -j ACCEPT
netfilter-persistent save

TAILSCALE_DNS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
PUBLIC_URL="https://${TAILSCALE_DNS_NAME}"
tailscale serve --bg --https=443 http://127.0.0.1:9119

# --- 8. Render config.yaml, then set the runtime-only public_url ---
install -d -o "$HERMES_USER_NAME" -g "$HERMES_USER_NAME" -m 755 "${MOUNT_POINT}/.hermes"
cp /etc/hermes/config.yaml.tmpl "${MOUNT_POINT}/.hermes/config.yaml"
chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "${MOUNT_POINT}/.hermes/config.yaml"
# Declaring a non-loopback public_url is what engages the dashboard auth gate
# even though the service itself still binds 127.0.0.1 — see PLAN.md §2.1.
runuser -u "$HERMES_USER_NAME" -- bash -lc "export PATH=\"\$HOME/.local/bin:\$HOME/.hermes/hermes-agent/venv/bin:\$HOME/.hermes/bin:\$PATH\"; hermes config set dashboard.public_url '${PUBLIC_URL}'"

# --- 9. Browser tooling, Playwright MCP's Chromium, and GitHub CLI ---
log "installing ripgrep, Node.js 22, agent-browser, Playwright's Chromium, and gh CLI"
apt-get install -y -qq ripgrep

# Playwright requires Node.js >=20 and agent-browser requires Node >=22.
# Ubuntu default package is Node 18, so upgrade to Node.js 22.x LTS via NodeSource.
if ! node -v 2>/dev/null | grep -E '^v(2[0-9])' >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi

npm install -g agent-browser || true
# Install OS system dependencies for Playwright as root
npx --yes playwright install-deps chromium || true
# Download Playwright Chromium binaries under hermes user (no --with-deps flag to avoid sudo prompt)
runuser -u "$HERMES_USER_NAME" -- bash -lc 'npx --yes playwright install chromium' || true

if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" >/etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh
fi

if [ -n "$GITHUB_PAT" ]; then
  gh_pat_file=$(mktemp)
  printf '%s' "$GITHUB_PAT" >"$gh_pat_file"
  chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "$gh_pat_file"
  chmod 600 "$gh_pat_file"
  runuser -u "$HERMES_USER_NAME" -- bash -lc "gh auth login --with-token < '${gh_pat_file}'"
  rm -f "$gh_pat_file"
fi

# --- 10. Write .env (dashboard auth + provider key placeholders) ---
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

# GitHub PAT for the stdio github MCP (empty until you provision
# github_pat_secret_ocid, or set it here directly).
GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_PAT}

# provider:model pairs the 4-hourly cron (cron/hermes-rotate-provider.cron)
# cycles the active model through. Edit freely; takes effect on the next run.
HERMES_PROVIDER_ROTATION=${HERMES_PROVIDER_ROTATION}
EOF
chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "${MOUNT_POINT}/.hermes/.env"
chmod 600 "${MOUNT_POINT}/.hermes/.env"

# --- 11. Install and start services ---
[ -f /etc/hermes/hermes-dashboard.service ] && cp -f /etc/hermes/hermes-dashboard.service /etc/systemd/system/hermes-dashboard.service 2>/dev/null || true
[ -f /etc/hermes/hermes-gateway.service ] && cp -f /etc/hermes/hermes-gateway.service /etc/systemd/system/hermes-gateway.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now hermes-dashboard.service
systemctl enable hermes-gateway.service # left stopped until a platform token is configured
systemctl enable --now hermes-backup.timer
systemctl enable --now hermes-git-mirror.timer
systemctl enable --now hermes-backup-check.timer

# Pick up /etc/cron.d/hermes-rotate-provider without waiting for the daemon's own rescan.
systemctl restart cron

# --- 12. OS hardening: unattended security upgrades, logrotate, fail2ban ---
log "configuring unattended-upgrades, logrotate, and fail2ban"
apt-get install -y -qq unattended-upgrades fail2ban python3-systemd

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat >"/etc/logrotate.d/hermes" <<EOF
${MOUNT_POINT}/.hermes/logs/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF

cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 5
bantime = 3600
findtime = 600
EOF

systemctl enable --now unattended-upgrades
systemctl enable --now fail2ban

# --- 13. Best-effort health check, logged for later inspection ---
# Migrate config version and auto-fix what's possible (e.g. new config keys).
runuser -u "$HERMES_USER_NAME" -- bash -lc \
  'export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:$HOME/.hermes/bin:$PATH"; hermes doctor --fix' \
  >/var/log/hermes-doctor.log 2>&1 || true

runuser -u "$HERMES_USER_NAME" -- bash -lc 'export PATH="$HOME/.local/bin:$HOME/.hermes/hermes-agent/venv/bin:$HOME/.hermes/bin:$PATH"; hermes doctor' >/var/log/hermes-doctor.log 2>&1 || true

log "bootstrap complete"
