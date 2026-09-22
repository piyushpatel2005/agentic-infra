# Hermes Module: Compute, Storage, Backup ObjectStore, Vault, IAM, and Security Groups

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# -----------------------------------------------------------------------------
# Security Group & Ports
# -----------------------------------------------------------------------------
resource "oci_core_network_security_group" "instance" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.name_prefix}-instance-nsg"

  freeform_tags = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "ssh_ingress" {
  #checkov:skip=CKV_OCI_21:Stateful is intentional
  for_each = toset(var.ssh_allowed_cidrs)

  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "custom_ingress" {
  for_each = toset([for p in var.hermes_ingress_ports : tostring(p)])

  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

# Tailscale P2P direct connection UDP port
resource "oci_core_network_security_group_security_rule" "tailscale_udp" {
  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  udp_options {
    destination_port_range {
      min = 41641
      max = 41641
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  #checkov:skip=CKV2_OCI_2:Egress is open
  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}

# -----------------------------------------------------------------------------
# Storage & KMS Keys
# -----------------------------------------------------------------------------
resource "oci_kms_vault" "storage" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-storage-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = var.freeform_tags
}

resource "oci_kms_key" "storage" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-storage-key"
  key_shape {
    algorithm = "AES"
    length    = 32
  }
  management_endpoint = oci_kms_vault.storage.management_endpoint
  freeform_tags       = var.freeform_tags
}

resource "oci_core_volume" "hermes_data" {
  #checkov:skip=CKV_OCI_2:Backup policy assignment attached below
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.name_prefix}-data"
  size_in_gbs         = var.data_volume_size_gb
  vpus_per_gb         = 10
  kms_key_id          = oci_kms_key.storage.id

  freeform_tags = var.freeform_tags
}

resource "oci_core_volume_backup_policy" "weekly" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-weekly-backup-policy"

  schedules {
    backup_type       = "FULL"
    period            = "ONE_WEEK"
    retention_seconds = 60 * 60 * 24 * 14
    time_zone         = "UTC"
    hour_of_day       = 3
    day_of_week       = "SUNDAY"
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_volume_backup_policy_assignment" "hermes_data" {
  asset_id  = oci_core_volume.hermes_data.id
  policy_id = oci_core_volume_backup_policy.weekly.id
}

# -----------------------------------------------------------------------------
# Compute Instance & Public IP
# -----------------------------------------------------------------------------
resource "oci_core_instance" "hermes" {
  #checkov:skip=CKV_OCI_4:In-transit encryption enabled via top level
  compartment_id                      = var.compartment_ocid
  availability_domain                 = var.availability_domain
  display_name                        = "${var.name_prefix}-agent-vm"
  shape                               = "VM.Standard.A1.Flex"
  is_pv_encryption_in_transit_enabled = true

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

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
    subnet_id        = var.public_subnet_id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.instance.id]
    hostname_label   = "${var.name_prefix}-oci"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/../../templates/cloud-init.yaml.tftpl", {
      bootstrap_script = file("${path.module}/../../templates/bootstrap.sh")
      hermes_config_yaml = templatefile("${path.module}/../../templates/hermes-config.yaml.tftpl", {
        nvidia_nim_base_url = var.nvidia_nim_base_url
        mistral_base_url    = var.mistral_base_url
      })
      dashboard_service_unit           = file("${path.module}/../../../systemd/hermes-dashboard.service")
      gateway_service_unit             = file("${path.module}/../../../systemd/hermes-gateway.service")
      rotate_provider_script           = file("${path.module}/../../../scripts/rotate-provider.sh")
      rotate_provider_cron             = file("${path.module}/../../../cron/hermes-rotate-provider.cron")
      hermes_backup_script             = file("${path.module}/../../../scripts/hermes-backup.sh")
      git_mirror_script                = file("${path.module}/../../../scripts/git-mirror.sh")
      backup_check_script              = file("${path.module}/../../../scripts/check-backup-freshness.sh")
      hermes_backup_service_unit       = file("${path.module}/../../../systemd/hermes-backup.service")
      hermes_backup_timer_unit         = file("${path.module}/../../../systemd/hermes-backup.timer")
      git_mirror_service_unit          = file("${path.module}/../../../systemd/hermes-git-mirror.service")
      git_mirror_timer_unit            = file("${path.module}/../../../systemd/hermes-git-mirror.timer")
      backup_check_service_unit        = file("${path.module}/../../../systemd/hermes-backup-check.service")
      backup_check_timer_unit          = file("${path.module}/../../../systemd/hermes-backup-check.timer")
      hermes_user                      = var.hermes_user
      data_volume_device               = var.data_volume_device
      swap_size_gb                     = var.swap_size_gb
      dashboard_basic_auth_secret_ocid = var.dashboard_basic_auth_secret_ocid
      tailscale_authkey_secret_ocid    = var.tailscale_authkey_secret_ocid
      github_pat_secret_ocid           = var.github_pat_secret_ocid
      provider_rotation                = join(",", var.provider_rotation)
      backups_bucket_name              = oci_objectstorage_bucket.backups.name
      age_recipient_public_key         = var.age_recipient_public_key
      workspace_dir                    = var.workspace_dir
      github_mirror_owner              = var.github_mirror_owner
      alerts_topic_id                  = oci_ons_notification_topic.alerts.id
      backup_stale_after_hours         = var.backup_stale_after_hours
    }))
  }

  freeform_tags = var.freeform_tags

  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}

resource "oci_core_volume_attachment" "hermes_data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.hermes.id
  volume_id       = oci_core_volume.hermes_data.id
  display_name    = "${var.name_prefix}-data-attachment"
  device          = var.data_volume_device
}

data "oci_core_boot_volume_attachments" "hermes" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  instance_id         = oci_core_instance.hermes.id
}

resource "oci_core_volume_backup_policy_assignment" "hermes_boot" {
  asset_id  = data.oci_core_boot_volume_attachments.hermes.boot_volume_attachments[0].boot_volume_id
  policy_id = oci_core_volume_backup_policy.weekly.id
}

data "oci_core_vnic_attachments" "hermes" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  instance_id         = oci_core_instance.hermes.id
}

data "oci_core_private_ips" "hermes_primary" {
  vnic_id = data.oci_core_vnic_attachments.hermes.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "reserved" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-reserved-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.hermes_primary.private_ips[0].id

  freeform_tags = var.freeform_tags
}

# -----------------------------------------------------------------------------
# Object Storage for Encrypted Backups
# -----------------------------------------------------------------------------
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = var.compartment_ocid
  name           = "${var.name_prefix}-backups-${data.oci_objectstorage_namespace.this.namespace}"
  namespace      = data.oci_objectstorage_namespace.this.namespace
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"

  kms_key_id = oci_kms_key.storage.id

  freeform_tags = var.freeform_tags
}

# -----------------------------------------------------------------------------
# Dynamic Group & IAM Policies
# -----------------------------------------------------------------------------
resource "oci_identity_dynamic_group" "hermes_instance" {
  compartment_id = var.tenancy_ocid
  name           = "${var.name_prefix}-instance-dg"
  description    = "Dynamic group matching Hermes compute instance."
  matching_rule  = "ANY {instance.id = '${oci_core_instance.hermes.id}'}"

  freeform_tags = var.freeform_tags
}

resource "oci_identity_policy" "hermes_backup" {
  compartment_id = var.compartment_ocid
  name           = "${var.name_prefix}-backup-policy"
  description    = "Allows Hermes instance principal to access its backups bucket and read secrets."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name='${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to read secret-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.hermes_instance.name} to use keys in compartment id ${var.compartment_ocid}"
  ]

  freeform_tags = var.freeform_tags
}

# -----------------------------------------------------------------------------
# Vault & KMS Secrets
# -----------------------------------------------------------------------------
resource "oci_kms_vault" "secrets" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-secrets-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = var.freeform_tags
}

resource "oci_kms_key" "secrets" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-secrets-key"
  key_shape {
    algorithm = "AES"
    length    = 32
  }
  management_endpoint = oci_kms_vault.secrets.management_endpoint
  freeform_tags       = var.freeform_tags
}

# -----------------------------------------------------------------------------
# Monitoring & Alerts
# -----------------------------------------------------------------------------
resource "oci_ons_notification_topic" "alerts" {
  compartment_id = var.compartment_ocid
  name           = "${var.name_prefix}-alerts-topic"
  freeform_tags  = var.freeform_tags
}

resource "oci_ons_subscription" "email" {
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.alerts.id
  protocol       = "EMAIL"
  endpoint       = var.alert_email
  freeform_tags  = var.freeform_tags
}
