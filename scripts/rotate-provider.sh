#!/usr/bin/env bash
# Rotates the active Hermes model/provider through the pool in
# HERMES_PROVIDER_ROTATION (set in ~/.hermes/.env) every time it's invoked.
# Installed as a root crontab entry (cron/hermes-rotate-provider.cron)
# running every 4 hours: drops to the hermes user for `hermes config set`,
# then restarts the gateway (as root) so live sessions pick up the change.
set -euo pipefail

HERMES_USER_NAME="${HERMES_USER:-hermes}"
HERMES_HOME_DIR="/home/${HERMES_USER_NAME}"
STATE_FILE="${HERMES_HOME_DIR}/.hermes/.provider-rotation-state"
ENV_FILE="${HERMES_HOME_DIR}/.hermes/.env"

[ -f "$ENV_FILE" ] || {
  echo "error: ${ENV_FILE} not found" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$ENV_FILE"

ROTATION="${HERMES_PROVIDER_ROTATION:?HERMES_PROVIDER_ROTATION not set in ${ENV_FILE}}"

IFS=',' read -r -a entries <<<"$ROTATION"
count=${#entries[@]}
[ "$count" -gt 0 ] || {
  echo "error: HERMES_PROVIDER_ROTATION is empty" >&2
  exit 1
}

current_index=0
[ -f "$STATE_FILE" ] && current_index=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
next_index=$(((current_index + 1) % count))

next_entry="${entries[$next_index]}"
provider="${next_entry%%:*}"
model="${next_entry#*:}"

runuser -u "$HERMES_USER_NAME" -- bash -lc "hermes config set model.provider '${provider}'"
runuser -u "$HERMES_USER_NAME" -- bash -lc "hermes config set model.default '${model}'"
echo "$next_index" >"$STATE_FILE"
chown "$HERMES_USER_NAME":"$HERMES_USER_NAME" "$STATE_FILE"

echo "[rotate-provider] switched to provider=${provider} model=${model} ($((next_index + 1))/${count})"

systemctl restart hermes-gateway.service 2>/dev/null || true
