#!/usr/bin/env bash
# ==============================================================================
# Piston Code Execution Engine Setup Script
# ==============================================================================
# Deploys and manages Piston (from https://github.com/piyushpatel2005/piston)
# in Docker on the OCI VM, bound securely to localhost (127.0.0.1:2000)
# for access by platform-workers via Cloudflare Tunnel or local proxy.
#
# By default (--start without --no-runtimes), installs all pinned language
# runtimes listed in the central runtimes.lock.json manifest (Node, Python, Go,
# Java, Rust, C, C++).
#
# Usage:
#   sudo /usr/local/bin/piston-setup.sh                 # Setup and build without starting
#   sudo /usr/local/bin/piston-setup.sh --start         # Setup, install all lockfile runtimes, and start
#   sudo /usr/local/bin/piston-setup.sh --packages-only # Install missing lockfile runtimes on an existing VM
# ==============================================================================

set -euo pipefail

PISTON_REPO="${PISTON_REPO:-https://github.com/piyushpatel2005/piston.git}"
PISTON_BRANCH="${PISTON_BRANCH:-master}"
PISTON_DIR="/opt/piston"
INTERNAL_PORT="2000"
START_SERVICE=false
INSTALL_RUNTIMES=true
PACKAGES_ONLY=false
TUNNEL_TOKEN=""
BUILD_JOBS="${RUNTIMES_BUILD_JOBS:-2}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -n "${PISTON_RUNTIMES_DIR:-}" ]]; then
  RUNTIMES_DIR="$PISTON_RUNTIMES_DIR"
elif [[ -d "${SCRIPT_DIR}/piston-runtimes" ]]; then
  RUNTIMES_DIR="${SCRIPT_DIR}/piston-runtimes"
else
  RUNTIMES_DIR="/usr/local/share/piston-runtimes"
fi

# Shared by fresh installs and the wrapper-only upgrade. No downloads or daemon changes.
install_go_wrapper() (
  set -eu
  local dir=$1 tmp
  [[ -x "$dir/go/bin/go" ]] || { printf 'Missing Go installation: %s\n' "$dir" >&2; exit 1; }
  tmp=$(mktemp "$dir/.run.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<'GO_RUN'
#!/usr/bin/env bash
set -eu
export GOCACHE="${TMPDIR:-/tmp}/go-cache"
export GOPATH="${TMPDIR:-/tmp}/go-path"
export GOPROXY=off GOSUMDB=off
# Piston supplies the entrypoint first; the Worker lists sibling sources only
# for non-module projects. Never append these names to a second *.go expansion.
if [[ -f go.mod ]]; then
  shift
  exec go run . "$@"
fi
exec go run "$@"
GO_RUN
  chmod 755 "$tmp"
  mv -f "$tmp" "$dir/run"
)

# Deliberately standalone: never fetch/reset the fork or restart running services.
if [[ $# == 1 && $1 == --refresh-go-wrapper ]]; then
  install_go_wrapper "$PISTON_DIR/data/piston/packages/go/1.16.2"
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start|-s)
      START_SERVICE=true
      shift
      ;;
    --no-runtimes)
      INSTALL_RUNTIMES=false
      shift
      ;;
    --packages-only)
      PACKAGES_ONLY=true
      shift
      ;;
    --tunnel-token)
      TUNNEL_TOKEN="$2"
      shift 2
      ;;
    --port|-p)
      INTERNAL_PORT="$2"
      shift 2
      ;;
    --jobs|-j)
      BUILD_JOBS="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--start] [--no-runtimes] [--packages-only] [--jobs 2] [--port 2000] [--tunnel-token <cloudflare-token>] | --refresh-go-wrapper"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() { echo "[piston-setup] $*"; }
fail() { echo "[piston-setup] ERROR: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  fail "piston-setup.sh must be run as root (sudo)"
fi

if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]?$ ]]; then
  fail "--jobs must be an integer between 1 and 99"
fi

if [[ ! "$INTERNAL_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( INTERNAL_PORT > 65535 )); then
  fail "--port must be a valid TCP port"
fi

install_all_lockfile_runtimes() {
  local skip_unmanaged="$1"
  local packages_dir="${PISTON_DIR}/data/piston/packages"
  local cache_dir
  local -a extra_args=()

  [[ -f "${RUNTIMES_DIR}/runtimes.py" ]] || fail "Missing central runtime installer: ${RUNTIMES_DIR}/runtimes.py"
  [[ -f "${RUNTIMES_DIR}/runtimes.lock.json" ]] || fail "Missing central runtime lockfile: ${RUNTIMES_DIR}/runtimes.lock.json"
  [[ -f "${RUNTIMES_DIR}/gcc-source.lock.json" ]] || fail "Missing GCC prerequisite lockfile: ${RUNTIMES_DIR}/gcc-source.lock.json"
  docker image inspect piston-api:local >/dev/null 2>&1 || fail "Docker image piston-api:local not found"

  mkdir -p "$packages_dir"
  chmod 755 "${PISTON_DIR}/data" "${PISTON_DIR}/data/piston" "$packages_dir"

  cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/piston-runtimes-cache.XXXXXX")"
  trap 'rm -rf -- "$cache_dir"' RETURN

  if [[ "$skip_unmanaged" = true ]]; then
    extra_args+=(--skip-unmanaged)
  fi

  log "Downloading and verifying archives from ${RUNTIMES_DIR}/runtimes.lock.json..."
  RUNTIMES_PACKAGES_DIR="$packages_dir" \
  RUNTIMES_CACHE_DIR="$cache_dir" \
    python3 -B "${RUNTIMES_DIR}/runtimes.py" --download-only "${extra_args[@]}"

  log "Provisioning all pinned runtimes inside piston-api:local (--network none, jobs=${BUILD_JOBS})..."
  docker run --rm --network none --memory 4g --memory-swap 6g \
    -e RUNTIMES_PACKAGES_DIR=/piston/packages \
    -e RUNTIMES_CACHE_DIR=/cache \
    -e "RUNTIMES_BUILD_JOBS=${BUILD_JOBS}" \
    -v "${packages_dir}:/piston/packages" \
    -v "${RUNTIMES_DIR}:/bootstrap:ro" \
    -v "${cache_dir}:/cache:ro" \
    --entrypoint python3 \
    piston-api:local -B /bootstrap/runtimes.py "${extra_args[@]}"
}

wait_for_piston_api() {
  local ready=0
  log "Waiting for Piston to become healthy on 127.0.0.1:${INTERNAL_PORT}..."
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${INTERNAL_PORT}/api/v2/runtimes" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  if [[ "$ready" -ne 1 ]]; then
    log "Warning: Piston did not respond within 120s. Check logs with 'journalctl -u piston.service' or 'docker compose logs'."
    return 1
  fi
  log "Piston API is active and healthy on 127.0.0.1:${INTERNAL_PORT}."
  return 0
}

if [[ "$PACKAGES_ONLY" = true ]]; then
  log "Syncing missing runtimes from ${RUNTIMES_DIR}/runtimes.lock.json (existing packages/containers untouched)..."
  install_all_lockfile_runtimes true
  log "Restarting piston.service to load all installed runtimes..."
  systemctl restart piston.service
  wait_for_piston_api
  log "Piston package sync complete."
  exit 0
fi

# 1. Ensure Docker & Docker Compose are installed
log "Step 1/5: Checking Docker and Docker Compose..."
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker and Docker Compose..."
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2
fi

systemctl enable --now docker.service

HERMES_USER="${HERMES_USER:-hermes}"
if id "$HERMES_USER" >/dev/null 2>&1; then
  usermod -aG docker "$HERMES_USER" || true
fi

# 2. Clone or update Piston repository in /opt/piston
log "Step 2/5: Checking Piston repository in ${PISTON_DIR}..."
mkdir -p "$PISTON_DIR"
if [[ ! -d "${PISTON_DIR}/.git" ]]; then
  log "Cloning ${PISTON_REPO} (${PISTON_BRANCH}) to ${PISTON_DIR}..."
  git clone --depth 1 --branch "$PISTON_BRANCH" "$PISTON_REPO" "$PISTON_DIR"
else
  log "Updating existing repository at ${PISTON_DIR}..."
  git -C "$PISTON_DIR" fetch --depth 1 origin "$PISTON_BRANCH" || true
  git -C "$PISTON_DIR" reset --hard "origin/${PISTON_BRANCH}" || true
fi

mkdir -p "${PISTON_DIR}/data/piston/packages"
chmod -R 755 "${PISTON_DIR}/data"

# Patch Dockerfile to point EOL Debian Buster to archive.debian.org
if [[ -f "${PISTON_DIR}/api/Dockerfile" ]]; then
  log "Patching api/Dockerfile for archive.debian.org Buster repositories..."
  python3 -c "
path = '${PISTON_DIR}/api/Dockerfile'
content = open(path).read()
if 'archive.debian.org' not in content:
    patch = 'RUN sed -i \"s/deb.debian.org/archive.debian.org/g\" /etc/apt/sources.list && sed -i \"s|security.debian.org/debian-security|archive.debian.org/debian-security|g\" /etc/apt/sources.list && sed -i \"/buster-updates/d\" /etc/apt/sources.list && apt-get update'
    content = content.replace('RUN apt-get update', patch)
    open(path, 'w').write(content)
"
fi

# 3. Configure 100% self-contained local build in docker-compose.yaml
log "Step 3/5: Ensuring 100% self-contained build in docker-compose.yaml..."
python3 -c "
path = '${PISTON_DIR}/docker-compose.yaml'
content = open(path).read()
if 'ghcr.io/engineer-man/piston' in content:
    content = content.replace('image: ghcr.io/engineer-man/piston', 'build: api\n        image: piston-api:local')
if '- 2000:2000' in content:
    content = content.replace('- 2000:2000', '- \"127.0.0.1:${INTERNAL_PORT}:2000\"')
open(path, 'w').write(content)
"

# Clean up any leftover containers and conflicting override files
docker rm -f piston_api >/dev/null 2>&1 || true
rm -f "${PISTON_DIR}/docker-compose.override.yaml" "${PISTON_DIR}/docker-compose.prod.yaml"

# Build native image from local source (zero dependency on upstream GHCR)
log "Building Piston container from source (piston-api:local)..."
docker compose -f "${PISTON_DIR}/docker-compose.yaml" build

# 4. Handle Cloudflare Tunnel (cloudflared) if configured
if [[ -n "$TUNNEL_TOKEN" ]]; then
  log "Step 4a: Configuring Cloudflare Tunnel for platform-workers access..."
  if ! command -v cloudflared >/dev/null 2>&1; then
    ARCH=$(dpkg --print-architecture)
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb || apt-get install -f -y -qq
    rm -f /tmp/cloudflared.deb
  fi
  cloudflared service install "$TUNNEL_TOKEN" || true
  systemctl restart cloudflared || true
fi

# 5. Install all lockfile runtimes and start Piston service if requested
if [[ "$START_SERVICE" = true ]]; then
  if [[ "$INSTALL_RUNTIMES" = true ]]; then
    install_all_lockfile_runtimes false
  fi
  log "Step 5/5: Starting Piston service via systemd..."
  systemctl daemon-reload
  systemctl enable --now piston.service
  systemctl restart piston.service || true
  wait_for_piston_api || true
else
  log "Piston configured. To start, run: sudo systemctl enable --now piston.service"
fi

log "Piston setup complete."
