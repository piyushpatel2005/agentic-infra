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
  description = "CIDR blocks allowed to reach TCP/22 on the instance's NSG. Keep this list tight."
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "At least one CIDR must be allowlisted for SSH; 0.0.0.0/0 is not permitted by this design."
  }

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not allowed — SSH must be restricted to specific allowlisted IPs."
  }
}

variable "freeform_tags" {
  description = "Freeform tags merged into every resource's tags."
  type        = map(string)
  default     = {}
}
