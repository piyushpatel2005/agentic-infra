output "instance_id" {
  description = "OCID of Piston compute instance."
  value       = oci_core_instance.piston.id
}

output "instance_public_ip" {
  description = "Reserved public IP assigned to Piston instance."
  value       = oci_core_public_ip.reserved.ip_address
}

output "instance_private_ip" {
  description = "Private IP of Piston instance."
  value       = data.oci_core_private_ips.piston_primary.private_ips[0].ip_address
}

output "instance_nsg_id" {
  description = "NSG ID of Piston instance."
  value       = oci_core_network_security_group.instance.id
}

output "piston_api_endpoint" {
  description = "Piston API HTTP endpoint."
  value       = "http://${oci_core_public_ip.reserved.ip_address}:${var.piston_api_port}"
}
