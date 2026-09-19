output "tfstate_bucket" {
  description = "Bucket name — use as `bucket` in the main stack's backend config."
  value       = oci_objectstorage_bucket.tfstate.name
}

output "tfstate_namespace" {
  description = "Object Storage namespace for this tenancy."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "tfstate_s3_endpoint" {
  description = "S3-compatible endpoint — use as `endpoint` in the main stack's backend config."
  value       = "https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "backend_access_key" {
  description = "Customer Secret Key access key — use as `access_key` in the main stack's backend config."
  value       = oci_identity_customer_secret_key.tfstate_backend.id
  sensitive   = true
}

output "backend_secret_key" {
  description = "Customer Secret Key secret — shown once; use as `secret_key` in the main stack's backend config, then store it in a password manager."
  value       = oci_identity_customer_secret_key.tfstate_backend.key
  sensitive   = true
}
