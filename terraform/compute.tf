# The A1.Flex compute instance, its attachments, and the pieces of Phase 2/3
# that could only be finished once the instance exists: assigning the
# reserved public IP, covering the boot volume with the backup policy, and
# tightening the dynamic group from compartment-wide to this instance only.

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "hermes" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  display_name        = "${local.name_prefix}-agent-vm"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = false # the reserved public IP below is attached separately
    nsg_ids          = [oci_core_network_security_group.instance.id]
    hostname_label   = "hermes-oci"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      bootstrap_script = file("${path.module}/templates/bootstrap.sh")
      hermes_config_yaml = templatefile("${path.module}/templates/hermes-config.yaml.tftpl", {
        nvidia_nim_base_url = var.nvidia_nim_base_url
        mistral_base_url    = var.mistral_base_url
      })
      dashboard_service_unit           = file("${path.module}/../systemd/hermes-dashboard.service")
      gateway_service_unit             = file("${path.module}/../systemd/hermes-gateway.service")
      rotate_provider_script           = file("${path.module}/../scripts/rotate-provider.sh")
      rotate_provider_cron             = file("${path.module}/../cron/hermes-rotate-provider.cron")
      hermes_user                      = var.hermes_user
      data_volume_device               = var.data_volume_device
      swap_size_gb                     = var.swap_size_gb
      dashboard_basic_auth_secret_ocid = var.dashboard_basic_auth_secret_ocid
      tailscale_authkey_secret_ocid    = var.tailscale_authkey_secret_ocid
      github_pat_secret_ocid           = var.github_pat_secret_ocid
      provider_rotation                = join(",", var.provider_rotation)
    }))
  }

  freeform_tags = local.common_tags

  # A new Ubuntu image release should not force-replace a running agent.
  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}

resource "oci_core_volume_attachment" "hermes_data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.hermes.id
  volume_id       = oci_core_volume.hermes_data.id
  display_name    = "${local.name_prefix}-data-attachment"
  device          = var.data_volume_device
}

data "oci_core_boot_volume_attachments" "hermes" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  instance_id         = oci_core_instance.hermes.id
}

resource "oci_core_volume_backup_policy_assignment" "hermes_boot" {
  asset_id  = data.oci_core_boot_volume_attachments.hermes.boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.weekly.id
}

data "oci_core_vnic_attachments" "hermes" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.availability_domain
  instance_id         = oci_core_instance.hermes.id
}

data "oci_core_private_ips" "hermes_primary" {
  vnic_id = data.oci_core_vnic_attachments.hermes.vnic_attachments[0].vnic_id
}
