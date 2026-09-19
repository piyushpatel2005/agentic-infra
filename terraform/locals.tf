locals {
  name_prefix = var.name_prefix

  # Merged into every resource that supports freeform_tags.
  common_tags = merge(
    {
      "project"    = local.name_prefix
      "managed-by" = "terraform"
    },
    var.freeform_tags,
  )
}
