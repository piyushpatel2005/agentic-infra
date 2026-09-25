# Hermes Agent on Oracle Cloud Always Free

Terraform-driven deployment of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/)
on an Oracle Cloud Infrastructure (OCI) **Always Free** Ampere A1 VM, reachable only over
Tailscale, with encrypted backups to OCI Object Storage and an off-cloud GitHub mirror.

See [PLAN.md](PLAN.md) for the full design, decisions, and phased build-out,
[docs/RUNBOOK.md](docs/RUNBOOK.md) for day-2 operations (deploy, restore drill, switch
model/provider, teardown, free-tier usage audit), [docs/channels.md](docs/channels.md)
for Telegram messaging setup, [docs/syncthing.md](docs/syncthing.md) for multi-device sync
(macOS <-> OCI VM), and [docs/managing-repos.md](docs/managing-repos.md) for
scoping and managing tutorial/content repositories with custom skill guidelines.

## Status

All 10 phases in PLAN.md §5 are complete on `main` (tags `v0.1.0`–`v1.0.0`). Ongoing
work continues phase-by-phase on branches named `phase/NN-<name>`, one merged at a
time. Only `main` is expected to be consistent and deployable.

## Repository layout

| Path | Purpose |
|---|---|
| `terraform/` | All infrastructure-as-code (network, compute, storage, IAM, monitoring) |
| `terraform/bootstrap/` | One-time stack that creates the Terraform state backend |
| `scripts/` | Operational scripts run on the VM (backup, restore, git mirror, provider rotation, MCP OAuth helper, secrets bootstrap) |
| `systemd/` | Unit files installed on the VM |
| `cron/` | System crontab fragments (e.g. the 4-hourly provider rotation) |
| `docs/` | Runbook and operational documentation |

## Prerequisites

- An OCI tenancy with Always Free resources available in its home region.
- Local tools installed: Terraform (>= 1.7), OCI CLI (`oci`), `age`, and `jq`.
- Authenticated OCI credentials (`oci setup config` with public API key added in the OCI Console).
- A Tailscale account (the dashboard is reachable only via your tailnet).

## Quick start

See [docs/RUNBOOK.md](docs/RUNBOOK.md#first-time-deploy) for the full step-by-step. In short:

```sh
# 0. Initial OCI setup (if not already configured)
oci setup config
# Upload ~/.oci/oci_api_key_public.pem to OCI Console > Profile > API Keys

# 1. One-time: create the Terraform state backend
cd terraform/bootstrap && cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars, then:
terraform init && terraform apply

# 2. Configure the main stack
cd ../..
cp terraform/envs/prod.backend.hcl.example terraform/envs/prod.backend.hcl
cp terraform/envs/prod.tfvars.example terraform/envs/prod.tfvars
# edit both files with the outputs from step 1 and your own OCIDs

# 3. Deploy
./scripts/preflight.sh
cd terraform && terraform init -backend-config=envs/prod.backend.hcl
terraform apply -var-file=envs/prod.tfvars

# 4. Connect via Tailscale SSH and run one-time setup
ssh hermes@hermes-oci
sudo /usr/local/bin/hermes-setup.sh
```

Then open `https://hermes-oci.<your-tailnet>.ts.net` on any device joined to your
tailnet, sign in with the generated dashboard credentials, and start chatting.
