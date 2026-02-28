# -------------------------------------------------------------------------
# Program: outputs.tf
# Description: Outputs for Hyper-V infrastructure module resources
# Context: 3-node local Hyper-V failover cluster lab (Goose Creek ISD)
# Author: Greg Tate
# -------------------------------------------------------------------------

# Return the names of all cluster node VMs.
output "vm_names" {
  description = "Names of the created cluster node VMs"
  value       = local.vm_names
}

# Return the domain controller VM name.
output "domain_controller_name" {
  description = "Name of the created domain controller VM"
  value       = local.domain_controller_name
}

# Return node OS disk paths.
output "os_disk_paths" {
  description = "Map of VM name to OS VHDX path"
  value       = { for vm_name, disk in hyperv_vhd.os_disk : vm_name => disk.path }
}

# Return shared CSV disk paths.
output "shared_csv_disk_paths" {
  description = "Paths of shared CSV VHDX disks"
  value       = [for disk in hyperv_vhd.shared_csv : disk.path]
}

# Return the shared witness disk path.
output "witness_disk_path" {
  description = "Path of the shared witness VHDX disk"
  value       = hyperv_vhd.shared_witness.path
}
