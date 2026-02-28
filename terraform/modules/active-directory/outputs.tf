# -------------------------------------------------------------------------
# Program: outputs.tf
# Description: Outputs for Active Directory bootstrap module
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Return whether guest bootstrap is enabled.
output "bootstrap_enabled" {
  description = "Whether domain bootstrap automation is enabled"
  value       = var.enable_guest_bootstrap
}
