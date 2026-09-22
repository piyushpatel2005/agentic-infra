# Hermes & Piston Infrastructure on Oracle Cloud Always Free

Terraform-driven modular deployment of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) and [Piston Code Execution Engine](https://github.com/engineer-man/piston) on Oracle Cloud Infrastructure (OCI) **Always Free** Ampere A1 VMs.

Deploy either workload individually or run both concurrently within OCI's Always Free tier limits (4 Arm OCPUs, 24 GB RAM, 200 GB Storage).

See [PLAN.md](PLAN.md) for design decisions, and [docs/RUNBOOK.md](docs/RUNBOOK.md) for operational procedures.

## Repository Layout

| Path | Purpose |
|---|---|
| `terraform/` | Root Terraform configuration orchestrating modules (`main.tf`, `variables.tf`, `outputs.tf`) |
| `terraform/modules/network/` | Shared network infrastructure (VCN, Subnet, IGW, Security List) |
| `terraform/modules/hermes/` | Hermes Agent workload module (Compute, Block storage, Vault, IAM, ObjectStorage backups) |
| `terraform/modules/piston/` | Piston Code Execution workload module (Compute, Docker cloud-init setup, API port 2000) |
| `terraform/bootstrap/` | One-time stack that creates the Terraform state backend |
| `.github/workflows/deploy.yml` | Manual GitHub Actions workflow dispatch (`plan`, `apply`, `destroy` for `hermes`, `piston`, or `both`) |
| `scripts/` | Operational scripts (backup, restore, secrets bootstrap, provider rotation) |
| `systemd/` | Unit files installed on the VM |
| `cron/` | System crontab fragments (e.g. 4-hourly LLM provider rotation) |

## Prerequisites

- An OCI tenancy with Always Free resources available in its home region.
- Terraform >= 1.7, OCI CLI, and `age` installed locally (for local CLI deployment).
- GitHub repository secrets configured (for GitHub Actions workflow deployment): `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`, `OCI_PRIVATE_KEY_BASE64`, `OCI_REGION`.

## Deployment Options

### Option A: Deploy via GitHub Actions (Manual Trigger)

You can trigger deployments directly from GitHub without installing local tools:

1. In GitHub, go to **Actions** → **Deploy Infrastructure (Manual Trigger)**.
2. Click **Run workflow**.
3. Choose your parameters:
   - **Action**: `plan`, `apply`, or `destroy`
   - **Workload**: `hermes`, `piston`, or `both`

---

### Option B: Deploy Locally via Terraform CLI

```sh
# 1. One-time: create the Terraform state backend
cd terraform/bootstrap && cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars, then:
terraform init && terraform apply

# 2. Configure main stack variables
cd ../..
cp terraform/envs/prod.backend.hcl.example terraform/envs/prod.backend.hcl
cp terraform/envs/prod.tfvars.example terraform/envs/prod.tfvars
```

In `terraform/envs/prod.tfvars`, toggle which workloads to deploy:

```hcl
deploy_hermes = true
deploy_piston = true  # Set to true to deploy Piston
```

Then run:

```sh
# 3. Deploy
./scripts/preflight.sh
cd terraform && terraform init -backend-config=envs/prod.backend.hcl
terraform apply -var-file=envs/prod.tfvars

# 4. Seed Vault secrets (required if Hermes is enabled)
../scripts/bootstrap-secrets.sh --compartment-id <id> --vault-id <id> --key-id <id>
# paste printed *_secret_ocid values into envs/prod.tfvars, then re-apply
terraform apply -var-file=envs/prod.tfvars
```

## Accessing Services

- **Hermes Dashboard**: Reachable via Tailscale at `https://hermes-oci.<your-tailnet>.ts.net` (binds `127.0.0.1:9119`).
- **Piston API**: Reachable at `http://<piston-reserved-ip>:2000/api/v2` (or via Tailscale if configured).

