# Runbook

Operational procedures for the Hermes Agent Always-Free deployment. See [PLAN.md](../PLAN.md)
for design rationale and [README.md](../README.md) for repo layout.

## First-time deploy

0. **Configure OCI CLI and API credentials** (one-time workstation setup):
   - Ensure local tools are installed and accounts are ready:
     ```sh
     # macOS (Homebrew)
     brew install terraform oci-cli age jq
     ```
   - Ensure you have a free [Tailscale account](https://tailscale.com) (used for private networking and Tailscale SSH).
   - Initialize OCI CLI configuration:
     ```sh
     oci setup config
     ```
     *Prompts will request your **User OCID**, **Tenancy OCID**, and **Home Region** (see table below for where to copy these from the OCI Console). Accept the default options to generate a new RSA API key pair (`~/.oci/oci_api_key.pem`).*
   - Upload the generated public key to Oracle Cloud:
     - In OCI Console, click your **Profile icon** (top right) → **My Profile** (or **User Settings**).
     - Under **Resources** (bottom left), select **API Keys** → **Add API Key**.
     - Choose **Upload Public Key File** and select `~/.oci/oci_api_key_public.pem` (or choose **Paste Public Key** and paste the file content), then click **Add**.
   - Verify CLI authentication:
     ```sh
     oci iam region-subscription list
     ```

1. **Bootstrap the Terraform state backend** (one-time, per tenancy):
   ```sh
   cd terraform/bootstrap
   cp terraform.tfvars.example terraform.tfvars   # fill in your OCIDs
   terraform init
   terraform apply
   ```

   <details>
   <summary><b>Where to find these values in the OCI Console & CLI</b></summary>

   | Variable in `terraform.tfvars` | How to find in OCI Console | How to find via OCI CLI | Notes |
   |---|---|---|---|
   | **`compartment_ocid`** | Menu (☰) → **Identity & Security** → **Compartments** → copy OCID | `oci iam compartment list` | For the bootstrap state bucket, this is usually the root compartment (which is your Tenancy OCID `ocid1.tenancy.oc1..`). |
   | **`user_ocid`** | Profile icon (top right) → **My Profile** → under *User Information*, copy **OCID** (`ocid1.user.oc1..`) | `grep 'user=' ~/.oci/config` | Needed to generate Customer Secret Keys for the S3 state backend. |
   | **`region`** | Region dropdown (top right) → find your **Home Region** (indicated by a home icon, e.g. `us-ashburn-1`, `us-phoenix-1`) | `oci iam region-subscription list` | Must be the tenancy's home region (Always Free resources are only free there). |
   | **`tenancy_ocid`** *(used in main stack `prod.tfvars`)* | Profile icon (top right) → **Tenancy: `<name>`** → under *Tenancy Information*, copy **OCID** (`ocid1.tenancy.oc1..`) | `grep 'tenancy=' ~/.oci/config` | Tenancy root OCID (required for tenancy-scoped dynamic groups in `prod.tfvars`). |

   </details>

   Note the `tfstate_bucket`, `tfstate_namespace`, `tfstate_s3_endpoint`, `backend_access_key`,
   and `backend_secret_key` outputs (the secret key is shown only once).

2. **Configure the main stack's backend and variables**:

   **A. Generate `terraform/envs/prod.backend.hcl`**:
   From `terraform/bootstrap`, you can automatically create this file with all outputs filled:
   ```sh
   cat <<EOF > ../envs/prod.backend.hcl
   bucket                      = "$(terraform output -raw tfstate_bucket)"
   key                         = "prod/terraform.tfstate"
   region                      = "us-ashburn-1"
   endpoint                    = "$(terraform output -raw tfstate_s3_endpoint)"
   access_key                  = "$(terraform output -raw backend_access_key)"
   secret_key                  = "$(terraform output -raw backend_secret_key)"
   skip_region_validation      = true
   skip_credentials_validation = true
   skip_metadata_api_check     = true
   skip_requesting_account_id  = true
   skip_s3_checksum            = true
   use_path_style              = true
   EOF
   ```

   **B. Create and populate `terraform/envs/prod.tfvars`**:
   ```sh
   cd ../..
   cp terraform/envs/prod.tfvars.example terraform/envs/prod.tfvars
   ```

   <details open>
   <summary><b>Where to get values for <code>terraform/envs/prod.tfvars</code></b></summary>

   | Variable in `prod.tfvars` | Where to get the value / Command to run | Description |
   |---|---|---|
   | **`region`** | `us-ashburn-1` (or your home region) | Home region for Always Free resources. |
   | **`compartment_ocid`** | Tenancy root OCID or specific compartment OCID (`oci iam compartment list`) | Compartment where VM, network, and storage will reside. |
   | **`tenancy_ocid`** | Tenancy root OCID (`grep 'tenancy=' ~/.oci/config`) | Needed for IAM policy/dynamic group creation. |
   | **`ssh_public_key`** *(optional)* | `cat ~/.ssh/id_ed25519.pub` *(optional)* | Optional direct SSH key fallback. Omit if using Tailscale SSH exclusively. |
   | **`ssh_allowed_cidrs`** *(optional)* | `[]` *(or `["$(curl -s ifconfig.me)/32"]`)* | Set to `[]` for Tailscale SSH (port 22 closed to the public internet). |
   | **`age_recipient_public_key`** | Run `age-keygen -o key.txt` and copy the public key (`age1...`) | Public key used for encrypted backups in Object Storage. *Keep `key.txt` safe!* |
   | **`alert_email`** | Your email address (e.g. `you@example.com`) | Receives OCI metric alarms (CPU/RAM/storage/budget). |
   | **`dashboard_basic_auth_secret_ocid`** | Leave default placeholder for now | Will be populated in **Step 5** after running `bootstrap-secrets.sh`. |
   | **`tailscale_authkey_secret_ocid`** | Leave default placeholder for now | Will be populated in **Step 5** after running `bootstrap-secrets.sh`. |

   </details>

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
   - **Prerequisite**: Log in to your [Tailscale Admin Console → Keys](https://login.tailscale.com/admin/settings/keys), click **Generate auth key** (single-use / ephemeral is recommended), and copy the key (`tskey-auth-...`).
   - Run the secrets bootstrap script:
     ```sh
     ../scripts/bootstrap-secrets.sh \
       --compartment-id "$(grep 'compartment_ocid' envs/prod.tfvars | cut -d'"' -f2)" \
       --vault-id "$(terraform output -raw vault_id)" \
       --key-id "$(terraform output -raw vault_key_id)"
       # Add --github-pat <token> if you generated a GitHub PAT (optional)
     ```
     *When prompted, paste your **Tailscale auth key** and enter a **dashboard username** (a secure random password will be generated for you).*

   - Copy the printed `*_secret_ocid` lines into `terraform/envs/prod.tfvars`.

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

### Option A: Local CLI
```sh
cd terraform
terraform destroy -target=oci_core_instance.hermes -var-file=envs/prod.tfvars
terraform apply -var-file=envs/prod.tfvars
```

### Option B: GitHub Actions
You can trigger plans, applies, or full VM redeployments directly from the GitHub Actions UI via [.github/workflows/deploy.yml](../.github/workflows/deploy.yml).

#### 1. Configure GitHub Repository Secrets
In your GitHub repository, navigate to **Settings** → **Secrets and variables** → **Actions** → **New repository secret**, and create the following secrets:

| Secret Name | Value / Source |
|---|---|
| `OCI_USER_OCID` | User OCID (`ocid1.user.oc1..`) |
| `OCI_TENANCY_OCID` | Tenancy OCID (`ocid1.tenancy.oc1..`) |
| `OCI_FINGERPRINT` | API key fingerprint from `~/.oci/config` (or OCI Console > API Keys) |
| `OCI_PRIVATE_KEY` | Entire content of your private key file (`~/.oci/oci_api_key.pem`) |
| `OCI_REGION` | Home region identifier (e.g., `us-ashburn-1`) |
| `BACKEND_HCL` | Entire content of your filled-in `terraform/envs/prod.backend.hcl` |
| `PROD_TFVARS` | Entire content of your filled-in `terraform/envs/prod.tfvars` |

#### 2. Trigger the Workflow
1. Navigate to the **Actions** tab in GitHub.
2. Select **deploy** from the left-hand workflows list.
3. Click **Run workflow**:
   - Choose **`plan`** to preview Terraform changes safely.
   - Choose **`apply`** to execute general infrastructure updates.
   - Choose **`redeploy-vm`** to tear down and recreate only the compute instance.
   - Choose **`destroy`** to tear down the entire main stack (instance, volumes, networking, bucket, vault).

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

## Updating secrets in OCI Vault (Tailscale auth key, GitHub PAT, passwords)

All sensitive tokens and credentials used during VM provisioning are stored in OCI Vault as secrets.

### 1. Tailscale Key Expiry & Renewal

- **Running VM (Node Key)**: To prevent your running VM from disconnecting after Tailscale's default 180-day key expiry:
  1. Open [Tailscale Admin Console → Machines](https://login.tailscale.com/admin/machines).
  2. Locate `hermes-oci` → click **`...`** → select **Disable key expiry**.

- **Auth Key (`tskey-auth-...`) Renewal**: When your 90-day reusable auth key expires, you only need to renew it in OCI Vault before running `redeploy-vm` or provisioning new instances.

### 2. Updating Secret Content in OCI Vault (In-Place / Zero Code Changes)

Updating the secret directly in OCI Vault creates a new secret version under the **same OCID**. No changes to `prod.tfvars` or GitHub Secrets are needed.

#### Via OCI CLI:
```sh
# 1. Paste your new Tailscale auth key
NEW_AUTH_KEY="tskey-auth-..."

# 2. Automatically read the secret OCID from prod.tfvars
SECRET_OCID=$(grep -E '^\s*tailscale_authkey_secret_ocid\s*=' terraform/envs/prod.tfvars | cut -d'"' -f2)

# 3. Update the secret in OCI Vault in-place
oci vault secret update-base64 \
  --secret-id "$SECRET_OCID" \
  --secret-content-content "$(printf '%s' "$NEW_AUTH_KEY" | base64 | tr -d '\n')"
```

#### Via OCI Web Console:
1. Navigate to **Identity & Security** → **Vault**.
2. Select your compartment and click your Hermes vault (`hermes-secrets-vault`).
3. Under **Resources** (left menu), click **Secrets**.
4. Click the secret you want to update (e.g., `hermes-tailscale-authkey` or `hermes-github-pat`).
5. Click **Create Secret Version**.
6. Select **Plain-Text**, paste your new key/token value, and click **Create Secret Version**.

### 3. If Creating a Brand New Secret (New OCID)

If you create a completely new secret instead of a new version of the existing one:
1. Copy the new Secret OCID (`ocid1.vaultsecret.oc1..`).
2. Update the corresponding variable in `terraform/envs/prod.tfvars` (e.g. `tailscale_authkey_secret_ocid = "..."`).
3. Update the **`PROD_TFVARS`** secret in **GitHub Repo → Settings → Secrets and variables → Actions** with the updated `prod.tfvars` content.

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
