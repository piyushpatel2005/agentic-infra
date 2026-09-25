# Primary backup target (see PLAN.md §4). Private, versioned Object Storage
# bucket with lifecycle rules that age out daily/weekly/monthly backup
# objects. Objects are uploaded already `age`-encrypted by scripts/hermes-backup.sh
# (Phase 7) — this bucket only ever stores ciphertext.

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

# OCI IAM policy propagation is eventually consistent. Waiting 30 seconds
# ensures regional Object Storage endpoints recognize KMS key authorization.
resource "time_sleep" "wait_for_kms_policy" {
  depends_on      = [oci_identity_policy.storage_services_kms]
  create_duration = "30s"
}

resource "oci_objectstorage_bucket" "backups" {
  #checkov:skip=CKV_OCI_7:No consumer for object events on this bucket; nothing subscribes to them.
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${local.name_prefix}-backups"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"
  kms_key_id     = oci_kms_key.storage.id

  depends_on = [time_sleep.wait_for_kms_policy]

  freeform_tags = local.common_tags
}

resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  namespace = data.oci_objectstorage_namespace.this.namespace
  bucket    = oci_objectstorage_bucket.backups.name

  rules {
    name        = "expire-daily"
    action      = "DELETE"
    time_amount = 14
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "objects"

    object_name_filter {
      inclusion_prefixes = ["daily/"]
    }
  }

  rules {
    name        = "expire-weekly"
    action      = "DELETE"
    time_amount = 56
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "objects"

    object_name_filter {
      inclusion_prefixes = ["weekly/"]
    }
  }

  rules {
    name        = "expire-monthly"
    action      = "DELETE"
    time_amount = 180
    time_unit   = "DAYS"
    is_enabled  = true
    target      = "objects"

    object_name_filter {
      inclusion_prefixes = ["monthly/"]
    }
  }

  depends_on = [time_sleep.wait_for_kms_policy]
}
