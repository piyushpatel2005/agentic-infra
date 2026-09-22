output "instance_id" {
  description = "OCID of Hermes compute instance."
  value       = oci_core_instance.hermes.id
}

output "instance_public_ip" {
  description = "Reserved public IP assigned to Hermes instance."
  value       = oci_core_public_ip.reserved.ip_address
}

output "instance_private_ip" {
  description = "Private IP of Hermes instance."
  value       = data.oci_core_private_ips.hermes_primary.private_ips[0].ip_address
}

output "instance_nsg_id" {
  description = "NSG ID of Hermes instance."
  value       = oci_core_network_security_group.instance.id
}

output "data_volume_id" {
  description = "Data block volume ID."
  value       = oci_core_volume.hermes_data.id
}

output "backups_bucket_name" {
  description = "Name of Object Storage backups bucket."
  value       = oci_objectstorage_bucket.backups.name
}

output "object_storage_namespace" {
  description = "Object Storage namespace."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "vault_id" {
  description = "OCID of secrets Vault."
  value       = oci_kms_vault.secrets.id
}

output "vault_key_id" {
  description = "OCID of secrets KMS key."
  value       = oci_kms_key.secrets.id
}

output "dynamic_group_name" {
  description = "Name of IAM dynamic group."
  value       = oci_identity_dynamic_group.hermes_instance.name
}

output "alerts_topic_id" {
  description = "OCID of notifications alert topic."
  value       = oci_ons_notification_topic.alerts.id
}
