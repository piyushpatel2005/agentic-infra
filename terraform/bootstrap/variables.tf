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
  description = "Compartment to create the state bucket in (the tenancy/root compartment is fine)."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the IAM user Terraform authenticates as; a Customer Secret Key is generated for this user so the main stack can use the S3-compatible backend."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix applied to the state bucket name and tags."
  type        = string
  default     = "hermes"
}
