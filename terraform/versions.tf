terraform {
  required_version = ">= 1.7.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }

  # Bucket/key/region/endpoints are supplied at `terraform init
  # -backend-config=envs/<env>.backend.hcl` (see envs/prod.backend.hcl.example),
  # because they depend on the bootstrap stack's output and differ per tenancy.
  backend "s3" {
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
