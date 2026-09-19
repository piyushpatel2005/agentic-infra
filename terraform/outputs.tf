# Outputs are added phase by phase (network, storage, compute, ...) as each
# resource lands. Kept as its own file from the start so later phases only
# ever append here.

output "vcn_id" {
  value = oci_core_vcn.this.id
}

output "public_subnet_id" {
  value = oci_core_subnet.public.id
}

output "instance_nsg_id" {
  value = oci_core_network_security_group.instance.id
}

output "reserved_public_ip" {
  description = "Reserved public IP address — stays stable across instance replacement."
  value       = oci_core_public_ip.reserved.ip_address
}
