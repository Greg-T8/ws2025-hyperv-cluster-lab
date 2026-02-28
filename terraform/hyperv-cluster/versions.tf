# -------------------------------------------------------------------------
# Program: versions.tf
# Description: Terraform and provider version constraints for Hyper-V lab
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Define Terraform engine and provider versions.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = "~> 1.2.0"
    }
  }
}
