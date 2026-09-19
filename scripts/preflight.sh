#!/usr/bin/env bash
# Sanity-checks the local OCI CLI setup before any `terraform apply`: confirms
# the CLI/jq are available, resolves the tenancy's home region, and refuses to
# continue if the configured region differs (Always Free resources are only
# free in the home region). Also prints current A1 compute usage for a manual
# cross-check against PLAN.md's Always Free limits table.
set -euo pipefail

profile="${OCI_CLI_PROFILE:-DEFAULT}"

if ! command -v oci >/dev/null 2>&1; then
  echo "error: oci CLI not found on PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found on PATH (required to parse oci CLI output)" >&2
  exit 1
fi

subs_json=$(oci iam region-subscription list --profile "$profile" --all --output json)

tenancy_ocid=$(jq -r '.data[0]."tenancy-id" // empty' <<<"$subs_json")
home_region=$(jq -r '.data[] | select(."is-home-region") | ."region-name"' <<<"$subs_json")

if [ -z "$tenancy_ocid" ] || [ -z "$home_region" ]; then
  echo "error: could not determine tenancy or home region from the oci CLI — check ~/.oci/config" >&2
  exit 1
fi

echo "Tenancy:      ${tenancy_ocid}"
echo "Home region:  ${home_region}"

if [ -n "${OCI_CLI_REGION:-}" ] && [ "${OCI_CLI_REGION}" != "$home_region" ]; then
  echo "error: OCI_CLI_REGION=${OCI_CLI_REGION} is not the home region (${home_region}); Always Free resources are only free there" >&2
  exit 1
fi

echo
echo "== Current A1 compute usage (cross-check against PLAN.md Always Free limits) =="
oci limits value list \
  --profile "$profile" \
  --compartment-id "$tenancy_ocid" \
  --service-name "compute" \
  --output json 2>/dev/null |
  jq -r '.data[] | select(.name | test("a1"; "i")) | "\(.name): \(.value)"' ||
  echo "  (lookup failed — verify manually in Console > Governance > Limits, Quotas and Usage)"

echo
echo "Preflight checks passed."
