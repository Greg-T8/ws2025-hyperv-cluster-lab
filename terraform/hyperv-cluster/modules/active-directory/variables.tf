# -------------------------------------------------------------------------
# Program: variables.tf
# Description: Input variables for Active Directory bootstrap module
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Configure domain bootstrap execution settings.
variable "enable_guest_bootstrap" {
  description = "Run guest automation to promote AD and join cluster nodes to the domain"
  type        = bool
}

variable "domain_name" {
  description = "Active Directory root domain name"
  type        = string
}

variable "domain_controller_name" {
  description = "Name of the domain controller VM"
  type        = string
}

variable "cluster_node_names" {
  description = "Names of cluster node VMs to join to the domain"
  type        = list(string)
}

variable "guest_admin_username" {
  description = "Local administrator username used for PowerShell Direct guest automation"
  type        = string
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

variable "domain_controller_ipv4" {
  description = "Static IPv4 address used by the domain controller on the internal switch"
  type        = string
}

variable "domain_controller_prefix_length" {
  description = "Prefix length for the domain controller internal IPv4 address"
  type        = number
}

variable "bootstrap_script_path" {
  description = "Path to the PowerShell bootstrap script on the Terraform runner"
  type        = string
}
