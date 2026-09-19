# Instance-principal IAM: the Hermes VM authenticates to OCI as itself (no
# static API keys on disk) and is scoped to exactly two things — objects in
# its own backups bucket, and secrets in its own vault.
#
# The dynamic group matches the specific instance OCID (tightened here in
# Phase 4 now that the instance exists; Phase 3 scoped it compartment-wide
# as a self-contained placeholder).

resource "oci_identity_dynamic_group" "hermes_instance" {
  compartment_id = var.tenancy_ocid # dynamic groups are always tenancy-scoped
  name           = "${local.name_prefix}-instance-dynamic-group"
  description    = "Matches the Hermes agent compute instance for instance-principal auth."
  matching_rule  = "ALL {instance.id = '${oci_core_instance.hermes.id}'}"
}

resource "oci_identity_policy" "hermes_instance" {
  compartment_id = var.compartment_ocid
  name           = "${local.name_prefix}-instance-policy"
  description    = "Scopes the Hermes instance principal to its own backups bucket and secrets vault."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to read buckets in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to read secret-family in compartment id ${var.compartment_ocid} where target.vault.id = '${oci_kms_vault.secrets.id}'",
  ]
}
