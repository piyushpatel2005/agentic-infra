terraform {
  required_version = ">= 1.7.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }

  # Deliberately local state: this stack creates the remote state backend
  # used by the main `terraform/` stack, so it cannot depend on it.
}
