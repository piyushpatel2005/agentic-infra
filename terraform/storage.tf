# 100 GB block volume for /home/hermes (mounted by Phase 4's cloud-init) plus
# a weekly volume-backup policy. The boot volume gets the same policy
# assigned once it exists (Phase 4) — together that's up to 4 of the 5
# Always Free volume backups (2 boot + 2 block), matching PLAN.md's design.

data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
}

resource "oci_core_volume" "hermes_data" {
  #checkov:skip=CKV_OCI_2:Backup IS enabled — see oci_core_volume_backup_policy_assignment.hermes_data below; this check only looks for the legacy backup_policy_id attribute.
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = "${local.name_prefix}-data"
  size_in_gbs         = var.data_volume_size_gb
  vpus_per_gb         = 10 # "Balanced" — the default performance tier, no extra cost beyond size
  kms_key_id          = oci_kms_key.storage.id

  depends_on = [oci_identity_policy.storage_services_kms]

  freeform_tags = local.common_tags
}

resource "oci_core_volume_backup_policy" "weekly" {
  compartment_id = var.compartment_ocid
  display_name   = "${local.name_prefix}-weekly-backup-policy"

  schedules {
    backup_type       = "FULL"
    period            = "ONE_WEEK"
    retention_seconds = 60 * 60 * 24 * 14 # 14 days -> 2 weekly backups retained
    time_zone         = "UTC"
    hour_of_day       = 3
    day_of_week       = "SUNDAY"
  }

  freeform_tags = local.common_tags
}

resource "oci_core_volume_backup_policy_assignment" "hermes_data" {
  asset_id  = oci_core_volume.hermes_data.id
  policy_id = oci_core_volume_backup_policy.weekly.id
}
