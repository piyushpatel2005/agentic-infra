variable "region" {
  description = "OCI region to deploy into. Must be the tenancy's home region — Always Free resources are only free there."
  type        = string
}

variable "oci_config_profile" {
  description = "Profile name in ~/.oci/config used for authentication (no API keys are stored in tfvars)."
  type        = string
  default     = "DEFAULT"
}

variable "compartment_ocid" {
  description = "OCID of the compartment to deploy resources into."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix applied to all resource names and tags."
  type        = string
  default     = "hermes"
}

variable "ssh_allowed_cidrs" {
  description = "Optional CIDR blocks allowed to reach TCP/22 on the instance's NSG. Leave empty ([]) when using Tailscale SSH."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed — SSH must be restricted to specific allowlisted IPs or empty."
  }
}

variable "freeform_tags" {
  description = "Freeform tags merged into every resource's tags."
  type        = map(string)
  default     = {}
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet the instance lives in."
  type        = string
  default     = "10.20.0.0/24"
}

variable "tenancy_ocid" {
  description = "Tenancy (root compartment) OCID. Required because dynamic groups are always tenancy-scoped."
  type        = string
}

variable "availability_domain_index" {
  description = "0-based index into the tenancy's list of ADs in the home region."
  type        = number
  default     = 0
}

variable "data_volume_size_gb" {
  description = "Size of the block volume mounted at /home/hermes. Combined with the boot volume this must stay within the 200 GB Always Free allotment."
  type        = number
  default     = 100
}

variable "ssh_public_key" {
  description = "Optional public SSH key for direct SSH access. If omitted, Tailscale SSH is used."
  type        = string
  default     = ""
}

variable "instance_ocpus" {
  description = "OCPUs for the A1.Flex shape. 2 is the entire Always Free A1 allotment."
  type        = number
  default     = 2
}

variable "instance_memory_gb" {
  description = "Memory (GB) for the A1.Flex shape. 12 is the entire Always Free A1 allotment."
  type        = number
  default     = 12
}

variable "boot_volume_size_gb" {
  description = "Boot volume size. Combined with data_volume_size_gb this must stay within the 200 GB Always Free allotment."
  type        = number
  default     = 50
}

variable "hermes_user" {
  description = "Unprivileged Linux user Hermes Agent runs as."
  type        = string
  default     = "hermes"
}

variable "swap_size_gb" {
  description = "Swapfile size created on the data volume, an OOM cushion for browser/MCP memory bursts."
  type        = number
  default     = 4
}

variable "data_volume_device" {
  description = "Device path the data volume is attached at (paravirtualized attachment)."
  type        = string
  default     = "/dev/oracleoci/oraclevdb"
}

variable "dashboard_basic_auth_secret_ocid" {
  description = "OCID of the Vault secret holding {username,password,secret} JSON for the dashboard basic-auth provider. Optional; leave empty to auto-generate credentials."
  type        = string
  default     = ""
}

variable "tailscale_auth_key" {
  description = "Tailscale pre-auth key (e.g. tskey-auth-...). If provided, the VM automatically joins Tailnet on first boot with Tailscale SSH enabled."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_authkey_secret_ocid" {
  description = "OCID of the Vault secret holding an ephemeral Tailscale pre-auth key. (Alternative to tailscale_auth_key)."
  type        = string
  default     = ""
}

variable "nvidia_nim_base_url" {
  description = "OpenAI-compatible base URL for NVIDIA NIM, wired in as a custom Hermes provider."
  type        = string
  default     = "https://integrate.api.nvidia.com/v1"
}

variable "mistral_base_url" {
  description = "OpenAI-compatible base URL for Mistral, wired in as a custom Hermes provider."
  type        = string
  default     = "https://api.mistral.ai/v1"
}

variable "github_pat_secret_ocid" {
  description = "OCID of the Vault secret holding a GitHub fine-grained PAT for the stdio GitHub MCP, created out-of-band by scripts/bootstrap-secrets.sh. Empty string = not configured yet; add it later and re-apply."
  type        = string
  default     = ""
}

variable "provider_rotation" {
  description = "Ordered \"provider:model\" pairs the 4-hourly cron rotates the active model through. Adjust the nvidia_nim/mistral model names to ones your account actually has access to."
  type        = list(string)
  default = [
    "openrouter:openrouter/auto",
    "nvidia_nim:nvidia/llama-3.1-nemotron-70b-instruct",
    "mistral:mistral-large-latest",
  ]
}

variable "age_recipient_public_key" {
  description = "age public key (starts with age1...) backups are encrypted to. Generate with `age-keygen -o key.txt`; keep the private key off the VM, in a password manager."
  type        = string
}

variable "workspace_dir" {
  description = "Directory on the instance backed up daily and mirrored to GitHub."
  type        = string
  default     = "/home/hermes/workspace"
}

variable "github_mirror_owner" {
  description = "GitHub org or user the off-cloud git mirror pushes repos to. Empty = git-mirror disabled."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address subscribed to the alerts topic (backup staleness, instance stop/terminate). OCI sends a confirmation link here after apply."
  type        = string
}

variable "backup_stale_after_hours" {
  description = "Hours after which a missing successful backup triggers an alert."
  type        = number
  default     = 36
}
