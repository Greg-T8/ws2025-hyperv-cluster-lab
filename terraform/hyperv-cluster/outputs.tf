# -------------------------------------------------------------------------
# Program: outputs.tf
# Description: Outputs for Hyper-V failover cluster lab deployment
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Return the names of all cluster node VMs.
output "vm_names" {
  description = "Names of the created cluster node VMs"
  value       = module.hyperv.vm_names
}

# Return the domain controller VM name.
output "domain_controller_name" {
  description = "Name of the created domain controller VM"
  value       = module.hyperv.domain_controller_name
}

# Return node OS disk paths.
output "os_disk_paths" {
  description = "Map of VM name to OS VHDX path"
  value       = module.hyperv.os_disk_paths
}

# Return shared CSV disk paths.
output "shared_csv_disk_paths" {
  description = "Paths of shared CSV VHDX disks"
  value       = module.hyperv.shared_csv_disk_paths
}

# Return the shared witness disk path.
output "witness_disk_path" {
  description = "Path of the shared witness VHDX disk"
  value       = module.hyperv.witness_disk_path
}
