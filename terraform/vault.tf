# KMS vault + key used only to envelope-encrypt Vault secrets. The secrets
# themselves (Tailscale key, dashboard credentials, GitHub PAT) are created
# out-of-band by scripts/bootstrap-secrets.sh so plaintext never enters
# `terraform.tfstate` — Terraform only ever references them by OCID (see the
# `*_secret_ocid` variables consumed in Phase 4's cloud-init).

resource "oci_kms_vault" "secrets" {
  compartment_id = var.compartment_ocid
  display_name   = "${local.name_prefix}-vault"
  vault_type     = "DEFAULT"

  freeform_tags = local.common_tags
}

resource "oci_kms_key" "secrets" {
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_prefix}-secrets-key"
  management_endpoint = oci_kms_vault.secrets.management_endpoint
  protection_mode     = "SOFTWARE" # software-protected keys are Always Free; no HSM

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  freeform_tags = local.common_tags
}

# Separate from "secrets" above: this key encrypts the backups bucket and the
# data volume at rest (CMK instead of the Oracle-managed default), so a
# leaked/rotated key never touches the vault secrets used for auth.
resource "oci_kms_key" "storage" {
  compartment_id      = var.compartment_ocid
  display_name        = "${local.name_prefix}-storage-key"
  management_endpoint = oci_kms_vault.secrets.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  freeform_tags = local.common_tags
}
