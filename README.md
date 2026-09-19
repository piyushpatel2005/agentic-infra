# Hermes Agent on Oracle Cloud Always Free

Terraform-driven deployment of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/)
on an Oracle Cloud Infrastructure (OCI) **Always Free** Ampere A1 VM, reachable only over
Tailscale, with encrypted backups to OCI Object Storage and an off-cloud GitHub mirror.

See [PLAN.md](PLAN.md) for the full design, decisions, and phased build-out, and
[docs/RUNBOOK.md](docs/RUNBOOK.md) for day-2 operations (deploy, restore drill, switch
model/provider, teardown, free-tier usage audit).

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
- Terraform >= 1.7, the OCI CLI, and `age` installed locally for backup/restore drills.
- A Tailscale account (the dashboard is reachable only via your tailnet).

## Quick start

See [docs/RUNBOOK.md](docs/RUNBOOK.md#first-time-deploy) for the full step-by-step. In short:

```sh
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

# 4. Seed Vault secrets (Tailscale key, dashboard credentials, optional GitHub PAT)
../scripts/bootstrap-secrets.sh --compartment-id <id> --vault-id <id> --key-id <id>
# paste the printed *_secret_ocid values into envs/prod.tfvars, then re-apply
terraform apply -var-file=envs/prod.tfvars
```

Then open `https://hermes-oci.<your-tailnet>.ts.net` on any device joined to your
tailnet, sign in with the generated dashboard credentials, and start chatting.
