#!/usr/bin/env bash
# Checks meta/last-success.json in the backups bucket; if the last successful
# backup is older than the staleness threshold, publishes an OCI
# Notifications message. Run periodically (see systemd/hermes-backup-check.timer).
set -euo pipefail

log() { echo "[backup-check] $*"; }

# shellcheck source=/dev/null
[ -f /etc/hermes/backup.env ] && source /etc/hermes/backup.env

BUCKET="${HERMES_BACKUP_BUCKET:?HERMES_BACKUP_BUCKET not set in /etc/hermes/backup.env}"
TOPIC_ID="${HERMES_ALERTS_TOPIC_OCID:?HERMES_ALERTS_TOPIC_OCID not set}"
STALE_AFTER_HOURS="${HERMES_BACKUP_STALE_AFTER_HOURS:-36}"

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

if ! oci --auth instance_principal os object get --bucket-name "$BUCKET" --name "meta/last-success.json" --file "$tmp_file" 2>/dev/null; then
  log "no meta/last-success.json yet — treating as stale (first boot, or backups never ran)"
  last_success_epoch=0
else
  last_success_iso=$(jq -r '.last_success_utc' "$tmp_file")
  last_success_epoch=$(date -u -d "$last_success_iso" +%s 2>/dev/null || echo 0)
fi

now_epoch=$(date -u +%s)
age_hours=$(((now_epoch - last_success_epoch) / 3600))

if [ "$age_hours" -ge "$STALE_AFTER_HOURS" ]; then
  log "backup is ${age_hours}h old (threshold ${STALE_AFTER_HOURS}h) — alerting"
  oci --auth instance_principal ons message publish \
    --topic-id "$TOPIC_ID" \
    --title "Hermes backup stale (${age_hours}h)" \
    --body "No successful hermes-backup.service run recorded in the last ${age_hours} hours on $(hostname). Check 'systemctl status hermes-backup.service' and 'journalctl -u hermes-backup.service'." \
    >/dev/null
else
  log "backup is ${age_hours}h old — within threshold (${STALE_AFTER_HOURS}h)"
fi
