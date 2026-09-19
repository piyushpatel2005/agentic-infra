# Runbook

Operational procedures for the Hermes Agent Always-Free deployment. See [PLAN.md](../PLAN.md)
for design rationale and [README.md](../README.md) for repo layout.

## First-time deploy

1. **Bootstrap the Terraform state backend** (one-time, per tenancy):
   ```sh
   cd terraform/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # fill in your OCIDs
   terraform init
   terraform apply
   ```
   Note the `tfstate_bucket`, `tfstate_namespace`, `tfstate_s3_endpoint`, `backend_access_key`,
   and `backend_secret_key` outputs (the secret key is shown only once).

2. **Configure the main stack's backend and variables**:
   ```sh
   cd ../..
   cp terraform/envs/prod.backend.hcl.example terraform/envs/prod.backend.hcl
   cp terraform/envs/prod.tfvars.example terraform/envs/prod.tfvars
   # fill in both files using the bootstrap outputs above and your own OCIDs
   ```

3. **Preflight check** (confirms home region + reports current A1 usage):
   ```sh
   ./scripts/preflight.sh
   ```

4. **Apply network, storage, and IAM only first** (compute needs Vault secrets that don't
   exist yet):
   ```sh
   cd terraform
   terraform init -backend-config=envs/prod.backend.hcl
   terraform apply -target=oci_kms_vault.secrets -target=oci_kms_key.secrets \
     -var-file=envs/prod.tfvars
   ```

5. **Seed Vault secrets out-of-band** (never goes into Terraform state):
   ```sh
   ../scripts/bootstrap-secrets.sh \
     --compartment-id <compartment_ocid> \
     --vault-id <vault_id output> \
     --key-id <vault_key_id output> \
     --github-pat <optional PAT>
   ```
   Copy the printed `*_secret_ocid` lines into `terraform/envs/prod.tfvars`.

6. **Full apply**:
   ```sh
   terraform apply -var-file=envs/prod.tfvars
   ```
   If you see `Out of host capacity` for `VM.Standard.A1.Flex`, see
   [A1 capacity errors](#a1-out-of-host-capacity-errors) below.

7. **Confirm the OCI Notifications email subscription** — check the inbox at `alert_email`
   and click the confirmation link, or alerts will never arrive.

8. **Verify** (see [Verification](#verification) below).

## Redeploying from scratch

Volume, bucket, and vault survive independently of the compute instance, so a full
redeploy is fast:

```sh
cd terraform
terraform destroy -target=oci_core_instance.hermes -var-file=envs/prod.tfvars
terraform apply -var-file=envs/prod.tfvars
```

Cloud-init reinstalls Hermes fresh, mounts the *same* data volume (which still has your
`~/.hermes` and workspace on it, since only the compute instance was destroyed), and
re-fetches secrets from Vault. Log in and run `hermes doctor` to confirm.

To rebuild everything including the data volume (disaster recovery from Object Storage
only), see the restore drill below.

## Restore drill

Practice this periodically — a backup you've never restored is not a backup.

1. SSH to the instance (over Tailscale): `ssh hermes@hermes-oci.<tailnet>.ts.net`
2. Copy your `age` identity file to the VM **temporarily**:
   ```sh
   scp key.txt hermes@hermes-oci.<tailnet>.ts.net:/tmp/age-identity.txt
   ```
3. Run the restore script as root:
   ```sh
   sudo /usr/local/bin/hermes-restore.sh \
     --bucket <backups_bucket_name output> \
     --identity /tmp/age-identity.txt
   ```
   Omit `--object` to restore the newest daily backup, or pass a specific
   `daily/hermes-home/hermes-backup-<ts>.zip.age` / `weekly/...` / `monthly/...` path.
4. **Delete the identity file from the VM immediately**: `rm -f /tmp/age-identity.txt`
5. Verify: `hermes doctor`, `hermes kanban list`, check `MEMORY.md`/`USER.md` contents,
   confirm `~/.hermes/mcp-tokens/` came back (otherwise re-authorize OAuth MCPs).

## Switching LLM provider or model

Over SSH (or Tailscale SSH), as the `hermes` user:

```sh
hermes model                      # interactive picker — add providers, enter API keys
hermes config set model.provider openrouter
hermes config set model.default "openrouter/auto"
```

For NVIDIA NIM or Mistral (configured as custom providers), set `model.provider` to
`nvidia_nim` or `mistral` and `model.default` to a model name that endpoint serves.
Changes take effect on the next session; restart the gateway for messaging platforms:

```sh
sudo systemctl restart hermes-gateway.service
```

The 4-hourly rotation (`/usr/local/bin/rotate-provider.sh`) will override this on its
next tick — edit `HERMES_PROVIDER_ROTATION` in `~/.hermes/.env` to change the pool, or
comment out the crontab entry in `/etc/cron.d/hermes-rotate-provider` to pause rotation.

## A1 "out of host capacity" errors

Ampere A1 capacity is oversubscribed in some regions/availability domains. If
`terraform apply` fails with this error:

- Re-run the apply a few minutes later (capacity frees up as other tenants scale down).
- If your region has multiple availability domains, try a different
  `availability_domain_index` in `terraform.tfvars`.
- As a last resort, temporarily reduce `instance_ocpus`/`instance_memory_gb` (e.g. 1
  OCPU / 6 GB) to fit into whatever fragment of capacity is free, then resize up later
  with `terraform apply` once 2/12 is available again (resizing is in-place, no data loss).

## Running a security audit

From the dashboard (`https://hermes-oci.<tailnet>.ts.net` → System → Operations →
Security audit), or via the REST API: `POST /api/ops/security-audit` (authenticated).
Review the report and address anything flagged before exposing the dashboard more
broadly.

## Teardown

```sh
cd terraform
terraform destroy -var-file=envs/prod.tfvars
```

This removes the instance, network, volumes, bucket, vault, and alerting — **backups in
the bucket are deleted too**. If you want to keep the backups, either skip destroying
the bucket (`terraform destroy -target=oci_core_instance.hermes ...` and manually leave
the rest) or copy objects out of the bucket first (`oci os object bulk-download`).

Finally, tear down the bootstrap stack if you no longer need the tfstate backend:
```sh
cd terraform/bootstrap
terraform destroy
```

## Verification

- `curl -s https://hermes-oci.<tailnet>.ts.net/api/status | jq '.auth_required, .auth_providers'`
  → `true`, `["basic"]`
- Dashboard loads, Chat tab streams the embedded TUI
- `systemctl is-active hermes-dashboard hermes-gateway hermes-backup.timer hermes-git-mirror.timer hermes-backup-check.timer`
- `hermes doctor` clean (`/var/log/hermes-doctor.log` on the VM)
- `hermes mcp test playwright` and `hermes mcp test github` both connect
- `hermes prompt-size` within your token budget
- Port scan from a non-allowlisted IP: 9119 unreachable, 22 filtered

## Free-tier usage audit checklist

Check monthly in the OCI Console under **Governance & Administration → Limits, Quotas
and Usage**, or via CLI (`oci limits value list`):

| Resource | Always Free limit | This deployment's usage |
|---|---|---|
| A1 Compute | 2 OCPU / 12 GB | 1 instance, `instance_ocpus` + `instance_memory_gb` |
| Block Volume | 200 GB | boot (`boot_volume_size_gb`, default 50) + data (`data_volume_size_gb`, default 100) = 150 GB |
| Volume backups | 5 | up to 4 (2 boot + 2 block, weekly policy, 14-day retention) |
| Object Storage | 20 GB, 50k requests/mo | backups bucket + tfstate bucket; `hermes-backup.sh` aborts above 15 GB |
| Load Balancers | 1 Flexible + 1 NLB | 0 (none created — Tailscale only) |
| NAT Gateways | not free | 0 (public subnet + IGW instead) |
| VCNs | 2 | 1 |

If any of these creep toward the limit, investigate before Oracle either reclaims
resources or starts charging.
