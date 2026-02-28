# -------------------------------------------------------------------------
# Program: main.tf
# Description: Hyper-V VM, disk, and network configuration for cluster lab
# Context: 3-node local Hyper-V failover cluster lab (Goose Creek ISD)
# Author: Greg Tate
# -------------------------------------------------------------------------

# Deploy Hyper-V infrastructure resources for the lab domain.
module "hyperv" {
  source = "./modules/hyperv"

  vm_prefix     = var.vm_prefix
  vm_count      = var.vm_count
  vm_path       = var.vm_path
  iso_path      = var.iso_path
  vm_generation = var.vm_generation

  processor_count      = var.processor_count
  memory_startup_bytes = var.memory_startup_bytes
  memory_minimum_bytes = var.memory_minimum_bytes
  memory_maximum_bytes = var.memory_maximum_bytes

  management_switch_name = var.management_switch_name
  cluster_switch_name    = var.cluster_switch_name
  internal_switch_name   = var.internal_switch_name

  os_disk_size_gb      = var.os_disk_size_gb
  csv_disk_count       = var.csv_disk_count
  csv_disk_size_gb     = var.csv_disk_size_gb
  witness_disk_size_gb = var.witness_disk_size_gb

  domain_controller_processor_count      = var.domain_controller_processor_count
  domain_controller_memory_startup_bytes = var.domain_controller_memory_startup_bytes
  domain_controller_memory_minimum_bytes = var.domain_controller_memory_minimum_bytes
  domain_controller_memory_maximum_bytes = var.domain_controller_memory_maximum_bytes
}

# Run Active Directory guest bootstrap and domain join operations.
module "active_directory" {
  source = "./modules/active-directory"

  enable_guest_bootstrap          = var.enable_guest_bootstrap
  domain_name                     = var.domain_name
  domain_controller_name          = module.hyperv.domain_controller_name
  cluster_node_names              = module.hyperv.vm_names
  guest_admin_username            = var.guest_admin_username
  guest_admin_password            = var.guest_admin_password
  domain_safe_mode_password       = var.domain_safe_mode_password
  domain_controller_ipv4          = var.domain_controller_ipv4
  domain_controller_prefix_length = var.domain_controller_prefix_length
  bootstrap_script_path           = "${path.module}/scripts/Invoke-DomainBootstrap.ps1"

  depends_on = [module.hyperv]
}
