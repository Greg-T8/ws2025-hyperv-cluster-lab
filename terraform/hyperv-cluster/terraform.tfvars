# -------------------------------------------------------------------------
# Program: terraform.tfvars
# Description: Default variable values for local Hyper-V cluster lab
# Context: 3-node local Hyper-V failover cluster lab (Goose Creek ISD)
# Author: Greg Tate
# -------------------------------------------------------------------------

# Set the local ISO path for Windows Server installation media.
iso_path = "D:\\ISOs\\WindowsServer2025.iso"

# Set WinRM credentials for local Hyper-V host access.
hyperv_user     = "Administrator"
hyperv_password = "Hyper-V2026!"

# Set VM naming prefix and host paths.
vm_prefix = "TEST"
vm_path   = "D:\\Hyper-V"

# Set switch names used by host and domain controller adapters.
management_switch_name = "Ethernet vSwitch"
cluster_switch_name    = "Private vSwitch"
internal_switch_name   = "Internal vSwitch"

# Set Active Directory domain settings.
domain_name                     = "test.lab"
domain_controller_ipv4          = "172.16.10.10"
domain_controller_prefix_length = 24

# Set guest automation credentials and control flag.
guest_admin_username      = "Administrator"
guest_admin_password      = "REPLACE_WITH_GUEST_LOCAL_ADMIN_PASSWORD"
domain_safe_mode_password = "REPLACE_WITH_DSRC_SAFE_MODE_PASSWORD"
enable_guest_bootstrap    = true
