#!/usr/bin/env bash
# Restore a `hermes backup` snapshot from OCI Object Storage: pulls the named
# object (or the newest daily one), decrypts it with your local `age`
# identity, and runs `hermes import`. This is deliberately NOT run
# automatically — restoring overwrites live config/sessions/memory.
#
# Run this ON THE VM (over SSH), with your `age` identity file copied over
# temporarily (never store it on the VM permanently — see PLAN.md §4).
set -euo pipefail

usage() {
  echo "Usage: hermes-restore.sh --bucket <name> --identity <age-identity-file> [--object <daily/hermes-home/hermes-backup-<ts>.zip.age>]" >&2
  exit 1
}

bucket=""
identity=""
object=""

while [ $# -gt 0 ]; do
  case "$1" in
  --bucket)
    bucket="$2"
    shift 2
    ;;
  --identity)
    identity="$2"
    shift 2
    ;;
  --object)
    object="$2"
    shift 2
    ;;
  -h | --help) usage ;;
  *)
    echo "unknown argument: $1" >&2
    usage
    ;;
  esac
done

[ -n "$bucket" ] && [ -n "$identity" ] || usage
[ -f "$identity" ] || {
  echo "error: identity file not found: ${identity}" >&2
  exit 1
}

if [ -z "$object" ]; then
  echo "No --object given, using the newest daily/hermes-home/ backup..." >&2
  object=$(oci --auth instance_principal os object list --bucket-name "$bucket" \
    --prefix "daily/hermes-home/" --query 'data | sort_by(@, &name) | [-1].name' --raw-output)
fi

echo "Restoring: ${object}" >&2

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

oci --auth instance_principal os object get --bucket-name "$bucket" --name "$object" \
  --file "${tmp_dir}/backup.zip.age"

age -d -i "$identity" -o "${tmp_dir}/backup.zip" "${tmp_dir}/backup.zip.age"

echo "Decrypted to ${tmp_dir}/backup.zip — running hermes import as the hermes user." >&2
cp "${tmp_dir}/backup.zip" "/home/hermes/hermes-restore.zip"
chown hermes:hermes "/home/hermes/hermes-restore.zip"
runuser -u hermes -- bash -lc 'hermes import ~/hermes-restore.zip'
rm -f "/home/hermes/hermes-restore.zip"

echo "Restarting services to pick up the restored state..." >&2
systemctl restart hermes-dashboard.service
systemctl restart hermes-gateway.service 2>/dev/null || true

echo "Restore complete. Verify with: hermes doctor / hermes kanban list / MEMORY.md contents." >&2
