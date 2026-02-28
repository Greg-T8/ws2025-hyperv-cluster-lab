# -------------------------------------------------------------------------
# Program: variables.tf
# Description: Input variables for Hyper-V infrastructure module
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Configure cluster naming and placement settings.
variable "vm_prefix" {
  description = "Prefix used to build VM names"
  type        = string
}

variable "vm_count" {
  description = "Number of cluster node VMs to deploy"
  type        = number
}

variable "vm_path" {
  description = "Root path on Hyper-V host for VM assets"
  type        = string
}

variable "iso_path" {
  description = "Path to the installation ISO on the Hyper-V host"
  type        = string
}

# Configure VM compute and memory settings.
variable "vm_generation" {
  description = "Hyper-V VM generation"
  type        = number
}

variable "processor_count" {
  description = "Number of virtual processors per cluster node"
  type        = number
}

variable "memory_startup_bytes" {
  description = "Startup memory in bytes for each cluster node"
  type        = number
}

variable "memory_minimum_bytes" {
  description = "Minimum dynamic memory in bytes for each cluster node"
  type        = number
}

variable "memory_maximum_bytes" {
  description = "Maximum dynamic memory in bytes for each cluster node"
  type        = number
}

# Configure virtual switch mappings for node network adapters.
variable "management_switch_name" {
  description = "Name of the external switch used for compute adapters"
  type        = string
}

variable "cluster_switch_name" {
  description = "Name of the private switch used for cluster management and live migration"
  type        = string
}

variable "internal_switch_name" {
  description = "Name of the internal switch used for host management adapters and domain connectivity"
  type        = string
}

# Configure disk sizing and shared storage settings.
variable "os_disk_size_gb" {
  description = "OS disk size in GB for each cluster node"
  type        = number
}

variable "csv_disk_count" {
  description = "Number of shared CSV disks"
  type        = number
}

variable "csv_disk_size_gb" {
  description = "Size in GB for each shared CSV disk"
  type        = number
}

variable "witness_disk_size_gb" {
  description = "Size in GB for the shared witness disk"
  type        = number
}

# Configure domain controller VM sizing.
variable "domain_controller_processor_count" {
  description = "Number of virtual processors for the domain controller VM"
  type        = number
}

variable "domain_controller_memory_startup_bytes" {
  description = "Startup memory in bytes for the domain controller VM"
  type        = number
}

variable "domain_controller_memory_minimum_bytes" {
  description = "Minimum dynamic memory in bytes for the domain controller VM"
  type        = number
}

variable "domain_controller_memory_maximum_bytes" {
  description = "Maximum dynamic memory in bytes for the domain controller VM"
  type        = number
}
