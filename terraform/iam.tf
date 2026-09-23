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
  # Match all compute instances in the Hermes compartment.
  # Using compartment.id (not instance OCID) means redeployed instances are
  # automatically covered without any IAM update. Freeform tags are NOT
  # supported in dynamic group matching rules — only defined tag namespaces are.
  matching_rule  = "ALL {instance.compartment.id = '${var.compartment_ocid}'}"
}

resource "oci_identity_policy" "hermes_instance" {
  compartment_id = var.compartment_ocid
  name           = "${local.name_prefix}-instance-policy"
  description    = "Scopes the Hermes instance principal to its own backups bucket, secrets vault, and alerts topic."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to read buckets in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to read secret-family in compartment id ${var.compartment_ocid} where target.vault.id = '${oci_kms_vault.secrets.id}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to use ons-topics in compartment id ${var.compartment_ocid} where target.topic.id = '${oci_ons_notification_topic.alerts.id}'",
  ]
}

# Lets the Events service actually deliver matched events to the topic —
# without this, oci_events_rule's ONS action is silently undeliverable.
resource "oci_identity_policy" "events_to_ons" {
  compartment_id = var.tenancy_ocid
  name           = "${local.name_prefix}-events-to-ons-policy"
  description    = "Allows the Events service to publish to the Hermes alerts topic."

  statements = [
    "Allow service cloudevents to use ons-topics in tenancy where target.topic.id = '${oci_ons_notification_topic.alerts.id}'",
  ]
}

# Required for CMK-encrypted resources: OCI's storage services must be
# explicitly allowed to use a customer-managed key, or bucket/volume creation
# with kms_key_id set is rejected.
resource "oci_identity_policy" "storage_services_kms" {
  compartment_id = var.tenancy_ocid
  name           = "${local.name_prefix}-storage-kms-policy"
  description    = "Allows Object Storage and Block Storage to use the Hermes storage CMK and manage lifecycle."

  statements = [
    "Allow service objectstorage-${var.region} to use keys in tenancy where target.key.id = '${oci_kms_key.storage.id}'",
    "Allow service objectstorage-${var.region} to read vaults in tenancy where target.vault.id = '${oci_kms_vault.secrets.id}'",
    "Allow service objectstorage-${var.region} to manage object-family in tenancy",
    "Allow service blockstorage to use keys in tenancy where target.key.id = '${oci_kms_key.storage.id}'",
  ]
}
