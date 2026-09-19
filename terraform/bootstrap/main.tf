data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

# Counts against the 20 GB / 50k-requests Always Free Object Storage allowance
# alongside the backups bucket created in Phase 3 — Terraform state itself is
# a few KB, so this is negligible.
#checkov:skip=CKV_OCI_7:No consumer for object events on this bucket.
#checkov:skip=CKV_OCI_9:Bootstrap-only stack; no user secrets are stored here (those are kept out of Terraform state by design — see PLAN.md §4).
resource "oci_objectstorage_bucket" "tfstate" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.name_prefix}-tfstate"
  access_type    = "NoPublicAccess"
  versioning     = "Enabled"

  freeform_tags = {
    "project" = var.name_prefix
    "purpose" = "terraform-state"
  }
}

# S3-compatible credential for the main stack's `backend "s3"` block.
# The secret key value is only ever shown once (in the apply output) and is
# not retrievable again from OCI afterwards — copy it into the backend config
# immediately after applying this stack.
resource "oci_identity_customer_secret_key" "tfstate_backend" {
  user_id      = var.user_ocid
  display_name = "${var.name_prefix}-tfstate-backend"
}
