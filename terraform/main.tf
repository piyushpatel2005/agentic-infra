# Root Terraform Module orchestrating Network, Hermes Agent, and Piston Workloads.

module "network" {
  source = "./modules/network"

  compartment_ocid   = var.compartment_ocid
  name_prefix        = var.name_prefix
  vcn_cidr           = var.vcn_cidr
  public_subnet_cidr = var.public_subnet_cidr
  ssh_allowed_cidrs  = var.ssh_allowed_cidrs
  freeform_tags      = local.common_tags
}

module "hermes" {
  count  = var.deploy_hermes ? 1 : 0
  source = "./modules/hermes"

  compartment_ocid                 = var.compartment_ocid
  tenancy_ocid                     = var.tenancy_ocid
  public_subnet_id                 = module.network.public_subnet_id
  vcn_id                           = module.network.vcn_id
  availability_domain              = local.availability_domain
  name_prefix                      = var.name_prefix
  instance_ocpus                   = var.hermes_instance_ocpus
  instance_memory_gb               = var.hermes_instance_memory_gb
  boot_volume_size_gb              = var.hermes_boot_volume_size_gb
  data_volume_size_gb              = var.hermes_data_volume_size_gb
  ssh_public_key                   = var.ssh_public_key
  ssh_allowed_cidrs                = var.ssh_allowed_cidrs
  hermes_ingress_ports             = var.hermes_ingress_ports
  hermes_user                      = var.hermes_user
  swap_size_gb                     = var.swap_size_gb
  data_volume_device               = var.data_volume_device
  dashboard_basic_auth_secret_ocid = var.dashboard_basic_auth_secret_ocid
  tailscale_authkey_secret_ocid    = var.tailscale_authkey_secret_ocid
  nvidia_nim_base_url              = var.nvidia_nim_base_url
  mistral_base_url                 = var.mistral_base_url
  github_pat_secret_ocid           = var.github_pat_secret_ocid
  provider_rotation                = var.provider_rotation
  age_recipient_public_key         = var.age_recipient_public_key
  workspace_dir                    = var.workspace_dir
  github_mirror_owner              = var.github_mirror_owner
  alert_email                      = var.alert_email
  backup_stale_after_hours         = var.backup_stale_after_hours
  freeform_tags                    = local.common_tags
}

module "piston" {
  count  = var.deploy_piston ? 1 : 0
  source = "./modules/piston"

  compartment_ocid     = var.compartment_ocid
  public_subnet_id     = module.network.public_subnet_id
  vcn_id               = module.network.vcn_id
  availability_domain  = local.availability_domain
  name_prefix          = "${var.name_prefix}-piston"
  instance_ocpus       = var.piston_instance_ocpus
  instance_memory_gb   = var.piston_instance_memory_gb
  boot_volume_size_gb  = var.piston_boot_volume_size_gb
  ssh_public_key       = var.ssh_public_key
  ssh_allowed_cidrs    = var.ssh_allowed_cidrs
  piston_api_port      = var.piston_api_port
  piston_ingress_ports = var.piston_ingress_ports
  piston_allowed_cidrs = var.piston_allowed_cidrs
  tailscale_authkey    = var.piston_tailscale_authkey
  freeform_tags        = local.common_tags
}
