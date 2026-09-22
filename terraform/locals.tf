data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  name_prefix         = var.name_prefix
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name

  # Merged into every resource that supports freeform_tags.
  common_tags = merge(
    {
      "project"    = local.name_prefix
      "managed-by" = "terraform"
    },
    var.freeform_tags,
  )
}
