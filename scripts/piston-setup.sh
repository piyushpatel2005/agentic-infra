#!/usr/bin/env bash
# ==============================================================================
# Piston Code Execution Engine Setup Script
# ==============================================================================
# Deploys and manages Piston (from https://github.com/piyushpatel2005/piston)
# in Docker on the OCI VM, bound securely to localhost (127.0.0.1:2000)
# for access by platform-workers via Cloudflare Tunnel or local proxy.
#
# Usage:
#   sudo /usr/local/bin/piston-setup.sh         # Setup and build without starting
#   sudo /usr/local/bin/piston-setup.sh --start # Setup, start service, and install runtimes
# ==============================================================================

set -euo pipefail

PISTON_REPO="${PISTON_REPO:-https://github.com/piyushpatel2005/piston.git}"
PISTON_BRANCH="${PISTON_BRANCH:-master}"
PISTON_DIR="/opt/piston"
INTERNAL_PORT="2000"
START_SERVICE=false
INSTALL_RUNTIMES=true
TUNNEL_TOKEN=""

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
    --tunnel-token)
      TUNNEL_TOKEN="$2"
      shift 2
      ;;
    --port|-p)
      INTERNAL_PORT="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--start] [--no-runtimes] [--port 2000] [--tunnel-token <cloudflare-token>] | --refresh-go-wrapper"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log() { echo "[piston-setup] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "error: piston-setup.sh must be run as root (sudo)" >&2
  exit 1
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
if [ ! -d "${PISTON_DIR}/.git" ]; then
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
if [ -f "${PISTON_DIR}/api/Dockerfile" ]; then
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

# Build native ARM64 image from local source (zero dependency on upstream GHCR)
log "Building native ARM64 Piston container from source (piston-api:local)..."
docker compose -f "${PISTON_DIR}/docker-compose.yaml" build

# 4. Handle Cloudflare Tunnel (cloudflared) if configured
if [ -n "$TUNNEL_TOKEN" ]; then
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

# 5. Enable and start Piston service if requested
if [ "$START_SERVICE" = true ]; then
  log "Step 5/5: Starting Piston service via systemd..."
  systemctl daemon-reload
  systemctl enable --now piston.service

  # Wait for API to respond
  log "Waiting for Piston to become healthy on 127.0.0.1:${INTERNAL_PORT}..."
  READY=0
  for _ in $(seq 1 60); do
    if curl -sfS "http://127.0.0.1:${INTERNAL_PORT}/api/v2/runtimes" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 2
  done

  if [ "$READY" -ne 1 ]; then
    log "Warning: Piston did not respond within 120s. Check logs with 'journalctl -u piston.service' or 'docker compose logs'."
  else
    log "Piston API is active and healthy on 127.0.0.1:${INTERNAL_PORT}."

    # Install base language runtimes needed by intercourses
    if [ "$INSTALL_RUNTIMES" = true ]; then
      log "Installing default language runtimes (Python, Node.js, Go, Java, Rust)..."
      ARCH=$(uname -m)

      if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        log "Configuring native ARM64 runtimes..."

        # 1. Node.js (JavaScript) 20.11.1
        NODE_DIR="${PISTON_DIR}/data/piston/packages/node/20.11.1"
        mkdir -p "$NODE_DIR"
        if [ ! -f "${NODE_DIR}/bin/node" ]; then
          log "  Installing Node.js 20.11.1 (ARM64)..."
          curl -sSL "https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-arm64.tar.xz" | \
            tar -xJ -C "$NODE_DIR" --strip-components=1 2>/dev/null || true
          cat << "EOF" > "${NODE_DIR}/environment"
export PATH=$PWD/bin:$PATH
EOF
          cat << "EOF" > "${NODE_DIR}/.env"
PATH=/piston/packages/node/20.11.1/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.
EOF
          cat << "EOF" > "${NODE_DIR}/run"
#!/usr/bin/env bash
node "$@"
EOF
          cat << "EOF" > "${NODE_DIR}/pkg-info.json"
{
  "language": "node",
  "version": "20.11.1",
  "aliases": ["node-javascript", "node-js", "javascript", "js"],
  "runtime": "node"
}
EOF
          touch "${NODE_DIR}/.ppman-installed"
          chmod +x "${NODE_DIR}/run"
        fi

        # 2. Python 3.12.0
        PYTHON_DIR="${PISTON_DIR}/data/piston/packages/python/3.12.0"
        mkdir -p "$PYTHON_DIR"
        if [ ! -f "${PYTHON_DIR}/bin/python3" ]; then
          log "  Installing Python 3.12.0 (ARM64)..."
          curl -sSL "https://github.com/astral-sh/python-build-standalone/releases/download/20241016/cpython-3.12.7+20241016-aarch64-unknown-linux-gnu-install_only.tar.gz" | \
            tar -xz -C "$PYTHON_DIR" --strip-components=1 2>/dev/null || true
          cat << "EOF" > "${PYTHON_DIR}/environment"
export PATH=$PWD/bin:$PATH
EOF
          cat << "EOF" > "${PYTHON_DIR}/.env"
PATH=/piston/packages/python/3.12.0/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.
EOF
          cat << "EOF" > "${PYTHON_DIR}/run"
#!/usr/bin/env bash
python3 "$@"
EOF
          cat << "EOF" > "${PYTHON_DIR}/pkg-info.json"
{
  "language": "python",
  "version": "3.12.0",
  "aliases": ["py", "py3", "python3", "python3.12"]
}
EOF
          touch "${PYTHON_DIR}/.ppman-installed"
          chmod +x "${PYTHON_DIR}/run"
        fi

        # 3. Go 1.16.2
        GO_DIR="${PISTON_DIR}/data/piston/packages/go/1.16.2"
        mkdir -p "$GO_DIR"
        if [ ! -f "${GO_DIR}/go/bin/go" ]; then
          log "  Installing Go 1.16.2 (ARM64)..."
          rm -rf "${GO_DIR}/go"
          curl -sSL "https://golang.org/dl/go1.16.2.linux-arm64.tar.gz" | \
            tar -xz -C "$GO_DIR" 2>/dev/null || true
          cat << "EOF" > "${GO_DIR}/environment"
export PATH=$PWD/go/bin:$PATH
export GOROOT=$PWD/go
EOF
          cat << "EOF" > "${GO_DIR}/.env"
GOROOT=/piston/packages/go/1.16.2/go
PATH=/piston/packages/go/1.16.2/go/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.
EOF

          cat << "EOF" > "${GO_DIR}/pkg-info.json"
{
  "language": "go",
  "version": "1.16.2",
  "aliases": ["go", "golang"]
}
EOF
          touch "${GO_DIR}/.ppman-installed"
        fi
        install_go_wrapper "$GO_DIR"

        # 4. Java 15.0.2 (with multi-file support)
        JAVA_DIR="${PISTON_DIR}/data/piston/packages/java/15.0.2"
        mkdir -p "$JAVA_DIR"
        if [ ! -f "${JAVA_DIR}/bin/java" ]; then
          log "  Installing Java 15.0.2 (ARM64)..."
          curl -sSL "https://download.java.net/java/GA/jdk15.0.2/0d1cfde4252546c6931946de8db48ee2/7/GPL/openjdk-15.0.2_linux-aarch64_bin.tar.gz" | \
            tar -xz -C "$JAVA_DIR" --strip-components=1 2>/dev/null || true
          cat << "EOF" > "${JAVA_DIR}/environment"
export PATH=$PWD/bin:$PATH
export JAVA_HOME=$PWD
EOF
          cat << "EOF" > "${JAVA_DIR}/.env"
JAVA_HOME=/piston/packages/java/15.0.2
PATH=/piston/packages/java/15.0.2/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.
EOF
          cat << "EOF" > "${JAVA_DIR}/compile"
#!/usr/bin/env bash
javac *.java
EOF
          chmod +x "${JAVA_DIR}/compile"
          cat << "EOF" > "${JAVA_DIR}/run"
#!/usr/bin/env bash
if [ -f "Main.class" ]; then
    exec java -cp . Main "$@"
else
    main_class=$(grep -l -m 1 "public static void main" *.java 2>/dev/null | head -n1 | sed 's/\.java$//')
    if [ -n "$main_class" ]; then
        exec java -cp . "$main_class" "$@"
    else
        echo "Error: No main method found" >&2
        exit 1
    fi
fi
EOF
          chmod +x "${JAVA_DIR}/run"
          cat << "EOF" > "${JAVA_DIR}/pkg-info.json"
{
  "language": "java",
  "version": "15.0.2",
  "aliases": ["java", "jdk", "openjdk", "java15"]
}
EOF
          touch "${JAVA_DIR}/.ppman-installed"
          chmod +x "${JAVA_DIR}/run"
        fi

        # 5. Rust 1.68.2
        RUST_DIR="${PISTON_DIR}/data/piston/packages/rust/1.68.2"
        mkdir -p "$RUST_DIR"
        if [ ! -f "${RUST_DIR}/rust-1.68.2-aarch64-unknown-linux-gnu/rustc/bin/rustc" ]; then
          log "  Installing Rust 1.68.2 (ARM64)..."
          rm -rf "${RUST_DIR}/rust-1.68.2-x86_64-unknown-linux-gnu"
          curl -sSL "https://static.rust-lang.org/dist/rust-1.68.2-aarch64-unknown-linux-gnu.tar.gz" | \
            tar -xz -C "$RUST_DIR" 2>/dev/null || true
          cat << "EOF" > "${RUST_DIR}/environment"
export PATH=$PWD/rust-1.68.2-aarch64-unknown-linux-gnu/rustc/bin/:$PATH
export RUST_INSTALL_LOC=$PWD/rust-1.68.2-aarch64-unknown-linux-gnu
EOF
          cat << "EOF" > "${RUST_DIR}/.env"
RUST_INSTALL_LOC=/piston/packages/rust/1.68.2/rust-1.68.2-aarch64-unknown-linux-gnu
PATH=/piston/packages/rust/1.68.2/rust-1.68.2-aarch64-unknown-linux-gnu/rustc/bin/:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.
EOF
          cat << "EOF" > "${RUST_DIR}/compile"
#!/usr/bin/env bash
rustc -o binary -L ${RUST_INSTALL_LOC}/rustc/lib -L ${RUST_INSTALL_LOC}/rust-std-aarch64-unknown-linux-gnu/lib/rustlib/aarch64-unknown-linux-gnu/lib "$@"
chmod +x binary
EOF
          cat << "EOF" > "${RUST_DIR}/run"
#!/usr/bin/env bash
shift
./binary "$@"
EOF
          cat << "EOF" > "${RUST_DIR}/pkg-info.json"
{
  "language": "rust",
  "version": "1.68.2",
  "aliases": ["rs"]
}
EOF
          touch "${RUST_DIR}/.ppman-installed"
          chmod +x "${RUST_DIR}/compile" "${RUST_DIR}/run"
        fi

        # Reload systemd service so Piston caches all .env and runtime configurations
        log "Restarting piston.service to cache all runtime configurations..."
        systemctl restart piston.service || true
      else
        log "Non-ARM64 architecture detected ($ARCH). Falling back to Piston package API..."
        post_pkg() {
          local body=$1
          curl -sS -o /dev/null -X POST "http://127.0.0.1:${INTERNAL_PORT}/api/v2/packages" \
            -H 'Content-Type: application/json' -d "$body" || true
        }
        post_pkg '{"language":"python","version":"3.12.0"}'
        post_pkg '{"language":"node","version":"20.11.1"}'
        post_pkg '{"language":"go","version":"1.16.2"}'
        post_pkg '{"language":"rust","version":"1.68.2"}'
      fi
      log "All 5 language runtimes installed and configured."
    fi
  fi
else
  log "Piston configured. To start, run: sudo systemctl enable --now piston.service"
fi

log "Piston setup complete."
