#!/usr/bin/env bash
# Daily backup: `hermes backup` (full ~/.hermes) + a workspace tarball, both
# age-encrypted client-side, uploaded to OCI Object Storage via instance
# principal. Promotes daily objects to weekly/ (Sundays) and monthly/ (1st),
# and writes meta/last-success.json for the staleness check. Run as root by
# hermes-backup.timer (see systemd/hermes-backup.{service,timer}).
set -euo pipefail

log() { echo "[hermes-backup] $*"; }

# shellcheck source=/dev/null
[ -f /etc/hermes/backup.env ] && source /etc/hermes/backup.env

HERMES_USER_NAME="${HERMES_USER:-hermes}"
BUCKET="${HERMES_BACKUP_BUCKET:?HERMES_BACKUP_BUCKET not set in /etc/hermes/backup.env}"
AGE_RECIPIENT="${HERMES_BACKUP_AGE_RECIPIENT:?HERMES_BACKUP_AGE_RECIPIENT not set}"
WORKSPACE_DIR="${HERMES_WORKSPACE_DIR:-/home/${HERMES_USER_NAME}/workspace}"
MAX_BUCKET_BYTES=$((15 * 1024 * 1024 * 1024)) # soft cap; bucket allotment is 20 GiB

ts=$(date -u +%Y%m%dT%H%M%SZ)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# --- 1. Guard: don't push the bucket over its Always Free allotment ---
bucket_bytes=$(oci --auth instance_principal os object list --bucket-name "$BUCKET" --all --fields size \
  --query 'sum(data[].size)' --raw-output 2>/dev/null || echo 0)
if [ "${bucket_bytes:-0}" -gt "$MAX_BUCKET_BYTES" ]; then
  echo "error: backups bucket is ${bucket_bytes} bytes (over the 15 GiB soft cap) — aborting, investigate before the 20 GiB Always Free limit is hit" >&2
  exit 1
fi

# --- 2. `hermes backup` (full ~/.hermes snapshot), encrypted ---
log "running hermes backup"
hermes_zip=$(runuser -u "$HERMES_USER_NAME" -- bash -lc 'hermes backup >/dev/null 2>&1; ls -t ~/hermes-backup-*.zip | head -1')
age -r "$AGE_RECIPIENT" -o "${tmp_dir}/hermes-home-${ts}.zip.age" "$hermes_zip"
oci --auth instance_principal os object put --bucket-name "$BUCKET" \
  --name "daily/hermes-home/hermes-backup-${ts}.zip.age" \
  --file "${tmp_dir}/hermes-home-${ts}.zip.age" --force
rm -f "$hermes_zip"

# --- 3. Workspace tarball, excluding build artifacts/caches, encrypted ---
if [ -d "$WORKSPACE_DIR" ]; then
  log "archiving workspace"
  tar --zstd \
    --exclude='node_modules' --exclude='.venv' --exclude='target' --exclude='dist' \
    --exclude='.playwright' \
    -cf "${tmp_dir}/workspace-${ts}.tar.zst" -C "$(dirname "$WORKSPACE_DIR")" "$(basename "$WORKSPACE_DIR")"
  age -r "$AGE_RECIPIENT" -o "${tmp_dir}/workspace-${ts}.tar.zst.age" "${tmp_dir}/workspace-${ts}.tar.zst"
  oci --auth instance_principal os object put --bucket-name "$BUCKET" \
    --name "daily/workspace/workspace-${ts}.tar.zst.age" \
    --file "${tmp_dir}/workspace-${ts}.tar.zst.age" --force
else
  log "no workspace dir at ${WORKSPACE_DIR} — skipping"
fi

# --- 4. Promote to weekly/ (Sundays) and monthly/ (1st of month) ---
day_of_week=$(date -u +%u) # 7 = Sunday
day_of_month=$(date -u +%d)

if [ "$day_of_week" = "7" ]; then
  oci --auth instance_principal os object copy --bucket-name "$BUCKET" \
    --source-object-name "daily/hermes-home/hermes-backup-${ts}.zip.age" \
    --destination-object-name "weekly/hermes-home/hermes-backup-${ts}.zip.age" \
    --destination-bucket "$BUCKET" --force || log "weekly promotion failed (non-fatal)"
fi

if [ "$day_of_month" = "01" ]; then
  oci --auth instance_principal os object copy --bucket-name "$BUCKET" \
    --source-object-name "daily/hermes-home/hermes-backup-${ts}.zip.age" \
    --destination-object-name "monthly/hermes-home/hermes-backup-${ts}.zip.age" \
    --destination-bucket "$BUCKET" --force || log "monthly promotion failed (non-fatal)"
fi

# --- 5. Record success for the staleness check (scripts/check-backup-freshness.sh) ---
meta=$(printf '{"last_success_utc":"%s","hermes_home_object":"daily/hermes-home/hermes-backup-%s.zip.age"}' "$ts" "$ts")
printf '%s' "$meta" >"${tmp_dir}/last-success.json"
oci --auth instance_principal os object put --bucket-name "$BUCKET" \
  --name "meta/last-success.json" --file "${tmp_dir}/last-success.json" --force

log "backup complete (${ts})"
