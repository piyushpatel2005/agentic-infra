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

output "data_volume_id" {
  value = oci_core_volume.hermes_data.id
}

output "backups_bucket_name" {
  value = oci_objectstorage_bucket.backups.name
}

output "object_storage_namespace" {
  value = data.oci_objectstorage_namespace.this.namespace
}

output "vault_id" {
  description = "Feed this into scripts/bootstrap-secrets.sh --vault-id."
  value       = oci_kms_vault.secrets.id
}

output "vault_key_id" {
  description = "Feed this into scripts/bootstrap-secrets.sh --key-id."
  value       = oci_kms_key.secrets.id
}

output "dynamic_group_name" {
  value = oci_identity_dynamic_group.hermes_instance.name
}

output "instance_id" {
  value = oci_core_instance.hermes.id
}

output "instance_public_ip" {
  description = "Reserved public IP now assigned to the instance — use for SSH and as the Tailscale-less fallback."
  value       = oci_core_public_ip.reserved.ip_address
}

output "instance_private_ip" {
  value = data.oci_core_private_ips.hermes_primary.private_ips[0].ip_address
}
