variable "region" {
  description = "OCI region to deploy into. Must be the tenancy's home region."
  type        = string
}

variable "oci_config_profile" {
  description = "Profile name in ~/.oci/config used for authentication."
  type        = string
  default     = "DEFAULT"
}

variable "compartment_ocid" {
  description = "OCID of the compartment to deploy resources into."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy (root compartment) OCID."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix applied to all resource names and tags."
  type        = string
  default     = "infra"
}

# -----------------------------------------------------------------------------
# Module Deployment Toggles
# -----------------------------------------------------------------------------
variable "deploy_hermes" {
  description = "Whether to deploy the Hermes agent workload module."
  type        = bool
  default     = true
}

variable "deploy_piston" {
  description = "Whether to deploy the Piston code execution engine workload module."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Network Variables
# -----------------------------------------------------------------------------
variable "vcn_cidr" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to reach TCP/22."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "At least one CIDR must be allowlisted for SSH."
  }

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed for SSH access."
  }
}

variable "availability_domain_index" {
  description = "Index into the list of availability domains (0-based)."
  type        = number
  default     = 0
}

variable "ssh_public_key" {
  description = "Public SSH key for instances."
  type        = string
}

variable "freeform_tags" {
  description = "Freeform tags merged into every resource's tags."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Hermes Module Variables
# -----------------------------------------------------------------------------
variable "hermes_instance_ocpus" {
  description = "OCPUs for Hermes instance."
  type        = number
  default     = 2
}

variable "hermes_instance_memory_gb" {
  description = "Memory (GB) for Hermes instance."
  type        = number
  default     = 12
}

variable "hermes_boot_volume_size_gb" {
  description = "Boot volume size for Hermes instance."
  type        = number
  default     = 50
}

variable "hermes_data_volume_size_gb" {
  description = "Size of block volume mounted at /home/hermes."
  type        = number
  default     = 100
}

variable "hermes_ingress_ports" {
  description = "Additional TCP ingress ports to expose on Hermes NSG (e.g. 9119)."
  type        = list(number)
  default     = [9119]
}

variable "hermes_user" {
  description = "Linux user Hermes Agent runs as."
  type        = string
  default     = "hermes"
}

variable "swap_size_gb" {
  description = "Swapfile size created on data volume."
  type        = number
  default     = 4
}

variable "data_volume_device" {
  description = "Device path for attached data volume."
  type        = string
  default     = "/dev/oracleoci/oraclevdb"
}

variable "dashboard_basic_auth_secret_ocid" {
  description = "OCID of Vault secret for dashboard basic-auth."
  type        = string
  default     = ""
}

variable "tailscale_authkey_secret_ocid" {
  description = "OCID of Vault secret for Tailscale key."
  type        = string
  default     = ""
}

variable "nvidia_nim_base_url" {
  description = "Base URL for NVIDIA NIM."
  type        = string
  default     = "https://integrate.api.nvidia.com/v1"
}

variable "mistral_base_url" {
  description = "Base URL for Mistral."
  type        = string
  default     = "https://api.mistral.ai/v1"
}

variable "github_pat_secret_ocid" {
  description = "OCID of Vault secret for GitHub PAT."
  type        = string
  default     = ""
}

variable "provider_rotation" {
  description = "LLM provider rotation pool."
  type        = list(string)
  default = [
    "openrouter:openrouter/auto",
    "nvidia_nim:nvidia/llama-3.1-nemotron-70b-instruct",
    "mistral:mistral-large-latest",
  ]
}

variable "age_recipient_public_key" {
  description = "age public key for backup encryption."
  type        = string
  default     = ""
}

variable "workspace_dir" {
  description = "Directory backed up daily."
  type        = string
  default     = "/home/hermes/workspace"
}

variable "github_mirror_owner" {
  description = "GitHub org/user for git mirror."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address for alerts subscription."
  type        = string
  default     = ""
}

variable "backup_stale_after_hours" {
  description = "Hours after which a missing backup triggers alert."
  type        = number
  default     = 36
}

# -----------------------------------------------------------------------------
# Piston Module Variables
# -----------------------------------------------------------------------------
variable "piston_instance_ocpus" {
  description = "OCPUs for Piston instance."
  type        = number
  default     = 2
}

variable "piston_instance_memory_gb" {
  description = "Memory (GB) for Piston instance."
  type        = number
  default     = 12
}

variable "piston_boot_volume_size_gb" {
  description = "Boot volume size for Piston instance."
  type        = number
  default     = 50
}

variable "piston_api_port" {
  description = "Port Piston API listens on."
  type        = number
  default     = 2000
}

variable "piston_ingress_ports" {
  description = "TCP ingress ports exposed on Piston NSG (e.g. 2000)."
  type        = list(number)
  default     = [2000]
}

variable "piston_allowed_cidrs" {
  description = "CIDR blocks allowed to reach Piston API port."
  type        = list(string)
  default     = []
}

variable "piston_tailscale_authkey" {
  description = "Optional Tailscale auth key for Piston instance."
  type        = string
  default     = ""
}
