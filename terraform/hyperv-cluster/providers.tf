# -------------------------------------------------------------------------
# Program: providers.tf
# Description: Hyper-V provider configuration for local WinRM connectivity
# Context: 3-node local Hyper-V failover cluster lab (Goose Creek ISD)
# Author: Greg Tate
# -------------------------------------------------------------------------

# Configure provider to connect to the local Hyper-V host over WinRM.
provider "hyperv" {
  host        = var.hyperv_host
  port        = var.hyperv_port
  user        = var.hyperv_user
  password    = var.hyperv_password
  https       = var.hyperv_https
  insecure    = var.hyperv_insecure
  use_ntlm    = var.hyperv_use_ntlm
  script_path = var.hyperv_script_path
  timeout     = var.hyperv_timeout
}
