# -------------------------------------------------------------------------
# Program: locals.tf
# Description: Local computed values for Hyper-V module resources
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Build deterministic names and paths for VM and disk resources.
locals {
  vm_names               = [for index in range(var.vm_count) : format("%s-HV%02d", var.vm_prefix, index + 1)]
  domain_controller_name = format("%s-DC01", var.vm_prefix)
  shared_disk_folder     = "${var.vm_path}\\SharedDisks"
  smb_share_name         = "ClusterDisks"
  shared_disk_unc_folder = "\\\\localhost\\${local.smb_share_name}"
  csv_disk_map           = { for index in range(var.csv_disk_count) : format("%02d", index + 1) => index + 1 }
  dc_answer_iso_path     = "${var.vm_path}\\AnswerISO\\autounattend-dc.iso"
  node_answer_iso_path   = "${var.vm_path}\\AnswerISO\\autounattend-node.iso"

  bytes_per_gib           = 1073741824
  os_disk_size_bytes      = var.os_disk_size_gb * local.bytes_per_gib
  csv_disk_size_bytes     = var.csv_disk_size_gb * local.bytes_per_gib
  witness_disk_size_bytes = var.witness_disk_size_gb * local.bytes_per_gib
}
