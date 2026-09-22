variable "compartment_ocid" {
  description = "OCID of the compartment to deploy network resources into."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix applied to all resource names and tags."
  type        = string
  default     = "infra"
}

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
  description = "CIDR blocks allowed to reach TCP/22 on subnet security list."
  type        = list(string)
  default     = []
}

variable "freeform_tags" {
  description = "Freeform tags applied to network resources."
  type        = map(string)
  default     = {}
}
