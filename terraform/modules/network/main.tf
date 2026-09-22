# VCN, Internet Gateway, public subnet, and route table.

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = replace(var.name_prefix, "-", "")

  freeform_tags = var.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true

  freeform_tags = var.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_security_list" "public" {
  #checkov:skip=CKV_OCI_17:Stateful (not stateless) rules are intentional here — return traffic for the allowlisted SSH/egress flows is handled automatically instead of doubling every rule.
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-public-sl"

  dynamic "ingress_security_rules" {
    for_each = toset(var.ssh_allowed_cidrs)
    content {
      protocol    = "6" # TCP
      source      = ingress_security_rules.value
      source_type = "CIDR_BLOCK"
      stateless   = false

      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    stateless        = false
  }

  freeform_tags = var.freeform_tags
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.name_prefix}-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false

  freeform_tags = var.freeform_tags
}
