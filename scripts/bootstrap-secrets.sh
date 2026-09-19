#!/usr/bin/env bash
# Seeds OCI Vault with the secrets Phase 4's cloud-init needs, out-of-band
# from Terraform so plaintext values never enter `terraform.tfstate`. Run
# this once from an operator machine (OCI CLI configured) after `terraform
# apply` on the main stack has created the vault (Phase 3), and before
# applying Phase 4's compute stack. Prints the secret OCIDs to paste into
# terraform/envs/prod.tfvars.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bootstrap-secrets.sh --compartment-id <ocid> --vault-id <ocid> --key-id <ocid> [--github-pat <token>]

  --compartment-id  Compartment OCID the vault/secrets live in
  --vault-id        `vault_id` output from `terraform apply` in terraform/
  --key-id          `vault_key_id` output from `terraform apply` in terraform/
  --github-pat      GitHub fine-grained PAT for the stdio GitHub MCP (optional; can add later)

Requires: oci CLI (configured), jq, openssl.

Prompts for a Tailscale auth key — generate an ephemeral, single-use one at
https://login.tailscale.com/admin/settings/keys before running this — and a
dashboard username (a strong password is generated for you).
EOF
  exit 1
}

compartment_id=""
vault_id=""
key_id=""
github_pat=""

while [ $# -gt 0 ]; do
  case "$1" in
  --compartment-id)
    compartment_id="$2"
    shift 2
    ;;
  --vault-id)
    vault_id="$2"
    shift 2
    ;;
  --key-id)
    key_id="$2"
    shift 2
    ;;
  --github-pat)
    github_pat="$2"
    shift 2
    ;;
  -h | --help) usage ;;
  *)
    echo "unknown argument: $1" >&2
    usage
    ;;
  esac
done

[ -n "$compartment_id" ] && [ -n "$vault_id" ] && [ -n "$key_id" ] || usage

for bin in oci jq openssl; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: $bin not found on PATH" >&2
    exit 1
  }
done

create_secret() {
  local name="$1" content="$2" b64
  b64=$(printf '%s' "$content" | base64 | tr -d '\n')
  oci vault secret create-base64 \
    --compartment-id "$compartment_id" \
    --vault-id "$vault_id" \
    --key-id "$key_id" \
    --secret-name "$name" \
    --secret-content-content "$b64" \
    --query 'data.id' --raw-output
}

echo "== Tailscale pre-auth key ==" >&2
echo "Generate an ephemeral, single-use key at https://login.tailscale.com/admin/settings/keys" >&2
read -r -s -p "Paste the Tailscale auth key: " ts_key
echo >&2
ts_secret_id=$(create_secret "hermes-tailscale-authkey" "$ts_key")
echo "tailscale_authkey_secret_ocid    = \"$ts_secret_id\""

echo >&2
echo "== Dashboard basic-auth credentials ==" >&2
read -r -p "Dashboard username [admin]: " dash_user
dash_user="${dash_user:-admin}"
dash_pass=$(openssl rand -base64 24)
dash_secret_key=$(openssl rand -base64 32)
dash_json=$(jq -n --arg u "$dash_user" --arg p "$dash_pass" --arg s "$dash_secret_key" \
  '{username: $u, password: $p, secret: $s}')
dash_secret_id=$(create_secret "hermes-dashboard-basic-auth" "$dash_json")
echo "dashboard_basic_auth_secret_ocid = \"$dash_secret_id\""
echo "Generated dashboard password (save this now — it is not stored anywhere else in plaintext): $dash_pass" >&2

if [ -n "$github_pat" ]; then
  gh_secret_id=$(create_secret "hermes-github-pat" "$github_pat")
  echo "github_pat_secret_ocid          = \"$gh_secret_id\""
else
  echo >&2
  echo "# --github-pat not supplied. Add it later with:" >&2
  echo "#   oci vault secret create-base64 --compartment-id $compartment_id --vault-id $vault_id \\" >&2
  echo "#     --key-id $key_id --secret-name hermes-github-pat --secret-content-content <base64 token>" >&2
fi

echo >&2
echo "Copy the *_secret_ocid lines above into terraform/envs/prod.tfvars." >&2
