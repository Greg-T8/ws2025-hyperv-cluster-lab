# -------------------------------------------------------------------------
# Program: versions.tf
# Description: Provider requirements for Hyper-V infrastructure module
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Declare Hyper-V provider source for module-scoped resources.
terraform {
  required_providers {
    hyperv = {
      source = "taliesins/hyperv"
    }
  }
}
