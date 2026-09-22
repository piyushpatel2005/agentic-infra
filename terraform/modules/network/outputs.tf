output "vcn_id" {
  description = "OCID of the created VCN."
  value       = oci_core_vcn.this.id
}

output "public_subnet_id" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "route_table_id" {
  description = "OCID of the public route table."
  value       = oci_core_route_table.public.id
}
