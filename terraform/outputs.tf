# Root Outputs

output "vcn_id" {
  description = "OCID of VCN."
  value       = module.network.vcn_id
}

output "public_subnet_id" {
  description = "OCID of public subnet."
  value       = module.network.public_subnet_id
}

# -----------------------------------------------------------------------------
# Hermes Outputs (conditional)
# -----------------------------------------------------------------------------
output "hermes_instance_id" {
  description = "OCID of Hermes instance."
  value       = try(module.hermes[0].instance_id, null)
}

output "hermes_public_ip" {
  description = "Reserved public IP assigned to Hermes instance."
  value       = try(module.hermes[0].instance_public_ip, null)
}

output "hermes_private_ip" {
  description = "Private IP of Hermes instance."
  value       = try(module.hermes[0].instance_private_ip, null)
}

output "hermes_backups_bucket_name" {
  description = "Name of Object Storage backups bucket."
  value       = try(module.hermes[0].backups_bucket_name, null)
}

output "hermes_vault_id" {
  description = "OCID of secrets Vault."
  value       = try(module.hermes[0].vault_id, null)
}

# -----------------------------------------------------------------------------
# Piston Outputs (conditional)
# -----------------------------------------------------------------------------
output "piston_instance_id" {
  description = "OCID of Piston instance."
  value       = try(module.piston[0].instance_id, null)
}

output "piston_public_ip" {
  description = "Reserved public IP assigned to Piston instance."
  value       = try(module.piston[0].instance_public_ip, null)
}

output "piston_private_ip" {
  description = "Private IP of Piston instance."
  value       = try(module.piston[0].instance_private_ip, null)
}

output "piston_api_endpoint" {
  description = "Piston API HTTP endpoint."
  value       = try(module.piston[0].piston_api_endpoint, null)
}
