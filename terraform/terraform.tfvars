# -------------------------------------------------------------------------
# Program: terraform.tfvars
# Description: Default variable values for local Hyper-V cluster lab
# Context: 3-node local Hyper-V failover cluster lab
# Author: Greg Tate
# -------------------------------------------------------------------------

# Set the local ISO path for Windows Server installation media.
iso_path = "D:\\Media\\Windows\\Windows Server 2025 Updated September 2025.iso"

# Set WinRM connection settings for local Hyper-V host access.
hyperv_host     = "localhost"
hyperv_port     = 5985
hyperv_https    = false
hyperv_insecure = true
hyperv_use_ntlm = true
hyperv_timeout  = "300s"

# Set local administrator credentials for Hyper-V host WinRM access.
# TODO: Move these to environment variables (TF_VAR_hyperv_user / TF_VAR_hyperv_password) or a secrets manager.
hyperv_user     = ""
hyperv_password = ""

# Set VM naming prefix and host paths.
vm_prefix = "TEST"
vm_path   = "D:\\Hyper-V\\ClusterLab"

# Set shared storage sizing for CSV disks.
csv_disk_size_gb = 50

# Set switch names used by host and domain controller adapters.
management_switch_name = "Ethernet vSwitch"
cluster_switch_name    = "Private vSwitch"
internal_switch_name   = "Internal vSwitch"

# Set Active Directory domain settings.
domain_name                     = "test.lab"
domain_controller_ipv4          = "192.168.148.40"
cluster_node_internal_ipv4s     = ["192.168.148.51", "192.168.148.52", "192.168.148.53"]
domain_controller_prefix_length = 24

# Set guest automation credentials and control flag.
guest_admin_username      = "Administrator"
guest_admin_password      = "Hyper-V2026!"
domain_safe_mode_password = "Hyper-V2026!"
enable_guest_bootstrap    = true
