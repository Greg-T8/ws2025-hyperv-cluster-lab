# -------------------------------------------------------------------------
# Program: variables.tf
# Description: Input variables for Hyper-V failover cluster lab deployment
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Configure Hyper-V provider connection settings.
variable "hyperv_host" {
  description = "Hyper-V host name or IP address"
  type        = string
  default     = "127.0.0.1"
}

variable "hyperv_port" {
  description = "WinRM port for Hyper-V host connectivity"
  type        = number
  default     = 5986
}

variable "hyperv_https" {
  description = "Use HTTPS for WinRM connectivity"
  type        = bool
  default     = true
}

variable "hyperv_insecure" {
  description = "Skip TLS certificate verification for WinRM"
  type        = bool
  default     = false
}

variable "hyperv_use_ntlm" {
  description = "Use NTLM authentication for WinRM"
  type        = bool
  default     = true
}

variable "hyperv_timeout" {
  description = "Provider operation timeout"
  type        = string
  default     = "30s"
}

variable "hyperv_script_path" {
  description = "Remote script path pattern used by the provider"
  type        = string
  default     = "C:/Temp/terraform_%RAND%.cmd"
}

variable "hyperv_user" {
  description = "Hyper-V administrative username"
  type        = string
  sensitive   = true
}

variable "hyperv_password" {
  description = "Hyper-V administrative password"
  type        = string
  sensitive   = true
}

# Configure cluster node naming and placement settings.
variable "vm_prefix" {
  description = "Prefix used to build VM names"
  type        = string
  default     = "TEST"
}

variable "vm_count" {
  description = "Number of cluster node VMs to deploy"
  type        = number
  default     = 3

  validation {
    condition     = var.vm_count == 3
    error_message = "This lab configuration requires exactly 3 cluster nodes."
  }
}

variable "vm_path" {
  description = "Root path on Hyper-V host for VM assets"
  type        = string
  default     = "D:\\Hyper-V"
}

variable "iso_path" {
  description = "Path to the installation ISO on the Hyper-V host"
  type        = string

  validation {
    condition     = length(trimspace(var.iso_path)) > 0
    error_message = "iso_path must be provided in terraform.tfvars."
  }
}

# Configure VM compute and memory settings.
variable "vm_generation" {
  description = "Hyper-V VM generation"
  type        = number
  default     = 2

  validation {
    condition     = var.vm_generation == 2
    error_message = "This lab configuration is defined for Generation 2 VMs."
  }
}

variable "processor_count" {
  description = "Number of virtual processors per cluster node"
  type        = number
  default     = 4
}

variable "memory_startup_bytes" {
  description = "Startup memory in bytes for each cluster node"
  type        = number
  default     = 8589934592
}

variable "memory_minimum_bytes" {
  description = "Minimum dynamic memory in bytes for each cluster node"
  type        = number
  default     = 2147483648
}

variable "memory_maximum_bytes" {
  description = "Maximum dynamic memory in bytes for each cluster node"
  type        = number
  default     = 8589934592
}

# Configure virtual switch mappings for node network adapters.
variable "management_switch_name" {
  description = "Name of the external switch used for host management and compute adapters"
  type        = string
  default     = "Ethernet vSwitch"
}

variable "cluster_switch_name" {
  description = "Name of the private switch used for cluster management and live migration"
  type        = string
  default     = "Private vSwitch"
}

variable "internal_switch_name" {
  description = "Name of the internal switch used for host management adapters and domain connectivity"
  type        = string
  default     = "Internal vSwitch"
}

# Configure disk sizing and shared storage settings.
variable "os_disk_size_gb" {
  description = "OS disk size in GB for each cluster node"
  type        = number
  default     = 127
}

variable "csv_disk_count" {
  description = "Number of shared CSV disks"
  type        = number
  default     = 2

  validation {
    condition     = var.csv_disk_count == 2
    error_message = "This lab configuration requires exactly 2 CSV shared disks."
  }
}

variable "csv_disk_size_gb" {
  description = "Size in GB for each shared CSV disk"
  type        = number
  default     = 100
}

variable "witness_disk_size_gb" {
  description = "Size in GB for the shared witness disk"
  type        = number
  default     = 5
}

# Configure domain controller VM and guest bootstrap settings.
variable "domain_name" {
  description = "Active Directory root domain name"
  type        = string
  default     = "test.lab"
}

variable "domain_controller_ipv4" {
  description = "Static IPv4 address used by the domain controller on the internal switch"
  type        = string
  default     = "172.16.10.10"
}

variable "domain_controller_prefix_length" {
  description = "Prefix length for the domain controller internal IPv4 address"
  type        = number
  default     = 24
}

variable "domain_controller_processor_count" {
  description = "Number of virtual processors for the domain controller VM"
  type        = number
  default     = 2
}

variable "domain_controller_memory_startup_bytes" {
  description = "Startup memory in bytes for the domain controller VM"
  type        = number
  default     = 4294967296
}

variable "domain_controller_memory_minimum_bytes" {
  description = "Minimum dynamic memory in bytes for the domain controller VM"
  type        = number
  default     = 2147483648
}

variable "domain_controller_memory_maximum_bytes" {
  description = "Maximum dynamic memory in bytes for the domain controller VM"
  type        = number
  default     = 4294967296
}

variable "guest_admin_username" {
  description = "Local administrator username used for PowerShell Direct guest automation"
  type        = string
  default     = "Administrator"
}

variable "guest_admin_password" {
  description = "Local administrator password used for PowerShell Direct guest automation"
  type        = string
  sensitive   = true
}

variable "domain_safe_mode_password" {
  description = "DSRM password used during AD forest promotion"
  type        = string
  sensitive   = true
}

variable "enable_guest_bootstrap" {
  description = "Run guest automation to promote AD and join cluster nodes to the domain"
  type        = bool
  default     = true
}
