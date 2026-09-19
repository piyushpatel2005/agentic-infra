#!/usr/bin/env bash
# Helper for authorizing OAuth-based MCP servers on a headless VM where no
# browser can complete the redirect locally. Wraps the documented escapes
# from PLAN.md §2.3 "Headless/remote OAuth for other MCPs" — run this ON THE
# VM (over SSH/Tailscale SSH), not on your laptop.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: mcp-oauth-helper.sh <server-name> <mode>

  device    Run `hermes mcp login <server-name> --flow device` — no callback
            listener needed. Prints a URL + code; open it on any device.
  sshfwd    Print the ssh -N -L command to run from your OTHER terminal,
            then run `hermes mcp login <server-name>` here.
  funnel    Print the config.yaml block to add before running
            `hermes mcp login <server-name>` (Tailscale Funnel callback).
EOF
  exit 1
}

[ $# -eq 2 ] || usage
server="$1"
mode="$2"

case "$mode" in
device)
  hermes mcp login "$server" --flow device
  ;;
sshfwd)
  this_ip=$(hostname -I | awk '{print $1}')
  echo "On your OTHER terminal (the one with a browser), run:" >&2
  echo "  ssh -N -L 27890:127.0.0.1:27890 $(whoami)@${this_ip}" >&2
  echo "Then approve the login when the browser opens on your side." >&2
  hermes mcp login "$server"
  ;;
funnel)
  tailnet_dns=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
  echo "Add this to ~/.hermes/config.yaml, then re-run this command:" >&2
  echo "" >&2
  echo "  mcp_servers:" >&2
  echo "    ${server}:" >&2
  echo "      oauth:" >&2
  echo "        redirect_uri: \"https://${tailnet_dns}/callback\"" >&2
  echo "        redirect_port: 27890" >&2
  echo "" >&2
  hermes mcp login "$server"
  ;;
*)
  usage
  ;;
esac
