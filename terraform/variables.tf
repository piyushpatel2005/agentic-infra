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
  description = "Index into the list of availability domains in the region (0-based). Most Always Free regions have only one."
  type        = number
  default     = 0
}

variable "data_volume_size_gb" {
  description = "Size of the block volume mounted at /home/hermes. Combined with the boot volume this must stay within the 200 GB Always Free allotment."
  type        = number
  default     = 100
}
