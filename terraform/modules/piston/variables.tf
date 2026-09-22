variable "compartment_ocid" {
  description = "OCID of the compartment to deploy Piston into."
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID where Piston instance will live."
  type        = string
}

variable "vcn_id" {
  description = "VCN ID for network security groups."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name for instance creation."
  type        = string
}

variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
  default     = "piston"
}

variable "instance_ocpus" {
  description = "OCPUs for the Piston A1.Flex shape."
  type        = number
  default     = 2
}

variable "instance_memory_gb" {
  description = "Memory (GB) for the Piston A1.Flex shape."
  type        = number
  default     = 12
}

variable "boot_volume_size_gb" {
  description = "Boot volume size for Piston instance."
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "Public SSH key installed on the instance."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed for SSH access."
  type        = list(string)
}

variable "piston_api_port" {
  description = "Port Piston API listens on."
  type        = number
  default     = 2000
}

variable "piston_ingress_ports" {
  description = "Additional TCP ingress ports to expose on Piston NSG (e.g. 2000)."
  type        = list(number)
  default     = [2000]
}

variable "piston_allowed_cidrs" {
  description = "CIDR blocks allowed to access Piston API port."
  type        = list(string)
  default     = []
}

variable "tailscale_authkey" {
  description = "Optional Tailscale auth key for joining tailnet."
  type        = string
  default     = ""
}

variable "freeform_tags" {
  description = "Freeform tags for resources."
  type        = map(string)
  default     = {}
}
