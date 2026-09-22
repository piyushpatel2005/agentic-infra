# Piston Module: Compute Instance, Security Group, and Reserved IP

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# -----------------------------------------------------------------------------
# Network Security Group & Ports
# -----------------------------------------------------------------------------
resource "oci_core_network_security_group" "instance" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "${var.name_prefix}-instance-nsg"

  freeform_tags = var.freeform_tags
}

# SSH ingress
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

# Piston API ingress (port 2000 or custom ports)
resource "oci_core_network_security_group_security_rule" "piston_api_ingress" {
  for_each = toset([for p in var.piston_ingress_ports : tostring(p)])

  network_security_group_id = oci_core_network_security_group.instance.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = length(var.piston_allowed_cidrs) > 0 ? var.piston_allowed_cidrs[0] : "0.0.0.0/0"
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
# Compute Instance
# -----------------------------------------------------------------------------
resource "oci_core_instance" "piston" {
  #checkov:skip=CKV_OCI_4:In-transit encryption enabled via top level
  compartment_id                      = var.compartment_ocid
  availability_domain                 = var.availability_domain
  display_name                        = "${var.name_prefix}-vm"
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
    user_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      piston_api_port   = var.piston_api_port
      tailscale_authkey = var.tailscale_authkey
      hostname_label    = "${var.name_prefix}-oci"
    }))
  }

  freeform_tags = var.freeform_tags

  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}

data "oci_core_vnic_attachments" "piston" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  instance_id         = oci_core_instance.piston.id
}

data "oci_core_private_ips" "piston_primary" {
  vnic_id = data.oci_core_vnic_attachments.piston.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "reserved" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name_prefix}-reserved-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.piston_primary.private_ips[0].id

  freeform_tags = var.freeform_tags
}
