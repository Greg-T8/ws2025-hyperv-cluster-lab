# -------------------------------------------------------------------------
# Program: main.tf
# Description: Active Directory promotion and domain-join orchestration module
# Context: 3-node local Hyper-V failover cluster lab (Goose Creek ISD)
# Author: Greg Tate
# -------------------------------------------------------------------------

# Promote Active Directory and join cluster nodes to the domain.
resource "terraform_data" "guest_bootstrap" {
  count = var.enable_guest_bootstrap ? 1 : 0

  triggers_replace = {
    domain_name                   = var.domain_name
    domain_controller_name        = var.domain_controller_name
    cluster_nodes                 = join(",", var.cluster_node_names)
    guest_admin_username          = var.guest_admin_username
    guest_admin_password_checksum = sha256(var.guest_admin_password)
    dsrm_password_checksum        = sha256(var.domain_safe_mode_password)
    domain_controller_ipv4        = var.domain_controller_ipv4
    domain_controller_prefix      = tostring(var.domain_controller_prefix_length)
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "& '${var.bootstrap_script_path}' -DomainName '${var.domain_name}' -DomainControllerName '${var.domain_controller_name}' -ClusterNodeNames '${join(",", var.cluster_node_names)}' -GuestAdminUsername '${var.guest_admin_username}' -DomainControllerIPv4 '${var.domain_controller_ipv4}' -DomainControllerPrefixLength ${var.domain_controller_prefix_length}"

    environment = {
      GUEST_ADMIN_PASSWORD      = var.guest_admin_password
      DOMAIN_SAFE_MODE_PASSWORD = var.domain_safe_mode_password
    }
  }
}
