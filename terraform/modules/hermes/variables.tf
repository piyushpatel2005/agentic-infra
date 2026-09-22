variable "compartment_ocid" {
  description = "OCID of the compartment to deploy Hermes into."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID for IAM dynamic groups."
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID where Hermes instance will live."
  type        = string
}

variable "vcn_id" {
  description = "VCN ID for network security groups."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name for instance and volume creation."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
  default     = "hermes"
}

variable "instance_ocpus" {
  description = "OCPUs for the Hermes A1.Flex shape."
  type        = number
  default     = 2
}

variable "instance_memory_gb" {
  description = "Memory (GB) for the Hermes A1.Flex shape."
  type        = number
  default     = 12
}

variable "boot_volume_size_gb" {
  description = "Boot volume size for Hermes instance."
  type        = number
  default     = 50
}

variable "data_volume_size_gb" {
  description = "Data block volume size for Hermes instance."
  type        = number
  default     = 100
}

variable "ssh_public_key" {
  description = "Public SSH key installed on the instance."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed for SSH access."
  type        = list(string)
}

variable "hermes_ingress_ports" {
  description = "Additional TCP ingress ports to expose on Hermes NSG (e.g. 9119)."
  type        = list(number)
  default     = [9119]
}

variable "hermes_user" {
  description = "Linux user for Hermes."
  type        = string
  default     = "hermes"
}

variable "swap_size_gb" {
  description = "Swapfile size in GB."
  type        = number
  default     = 4
}

variable "data_volume_device" {
  description = "Device path for attached data volume."
  type        = string
  default     = "/dev/oracleoci/oraclevdb"
}

variable "dashboard_basic_auth_secret_ocid" {
  description = "Vault secret OCID for dashboard basic auth."
  type        = string
}

variable "tailscale_authkey_secret_ocid" {
  description = "Vault secret OCID for Tailscale auth key."
  type        = string
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
  description = "Vault secret OCID for GitHub PAT."
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
  description = "Age public key for backup encryption."
  type        = string
}

variable "workspace_dir" {
  description = "Workspace directory path."
  type        = string
  default     = "/home/hermes/workspace"
}

variable "github_mirror_owner" {
  description = "GitHub org/user for git mirror."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email for alerts subscription."
  type        = string
}

variable "backup_stale_after_hours" {
  description = "Stale backup alert threshold hours."
  type        = number
  default     = 36
}

variable "freeform_tags" {
  description = "Freeform tags for resources."
  type        = map(string)
  default     = {}
}
