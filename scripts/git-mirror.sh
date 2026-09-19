#!/usr/bin/env bash
# Off-cloud third backup copy: mirrors every git repo under the workspace
# directory to a private GitHub org/user, using the `gh` CLI (already
# authenticated in Phase 6 if a PAT was provisioned). Creates the remote repo
# if it doesn't exist yet. Run daily by hermes-git-mirror.timer.
set -euo pipefail

log() { echo "[git-mirror] $*"; }

# shellcheck source=/dev/null
[ -f /etc/hermes/backup.env ] && source /etc/hermes/backup.env

HERMES_USER_NAME="${HERMES_USER:-hermes}"
WORKSPACE_DIR="${HERMES_WORKSPACE_DIR:-/home/${HERMES_USER_NAME}/workspace}"
MIRROR_OWNER="${HERMES_GITHUB_MIRROR_OWNER:-}"

[ -n "$MIRROR_OWNER" ] || {
  log "HERMES_GITHUB_MIRROR_OWNER not set — skipping (set it in /etc/hermes/backup.env to enable)"
  exit 0
}

[ -d "$WORKSPACE_DIR" ] || {
  log "no workspace dir at ${WORKSPACE_DIR} — nothing to mirror"
  exit 0
}

runuser -u "$HERMES_USER_NAME" -- bash -lc "
set -euo pipefail
shopt -s nullglob
for repo_git in '${WORKSPACE_DIR}'/*/.git; do
  repo_dir=\$(dirname \"\$repo_git\")
  repo_name=\$(basename \"\$repo_dir\")
  mirror_name=\"\${repo_name}-mirror\"
  echo \"[git-mirror] \${repo_name} -> ${MIRROR_OWNER}/\${mirror_name}\"
  gh repo view \"${MIRROR_OWNER}/\${mirror_name}\" >/dev/null 2>&1 || \
    gh repo create \"${MIRROR_OWNER}/\${mirror_name}\" --private --description \"Off-cloud mirror of \${repo_name}\" >/dev/null
  git -C \"\$repo_dir\" push --mirror \"https://github.com/${MIRROR_OWNER}/\${mirror_name}.git\"
done
"

log "mirror complete"
