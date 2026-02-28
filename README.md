# Hyper-V Failover Cluster Lab

## Purpose

This repository is used to prove out the latest procedures for building a **Windows Server 2025 Datacenter** Hyper-V failover cluster. It provides a fully automated, Terraform-driven lab environment that deploys a 3-node cluster with a dedicated domain controller, shared storage, and Active Directory — all running as nested VMs on a local Hyper-V host.

---

## Architecture

| Component | Count | Details |
|---|---|---|
| Cluster nodes | 3 | Gen 2, 4 vCPUs, 8 GB RAM (dynamic), 127 GB OS disk |
| Domain controller | 1 | Gen 2, 2 vCPUs, 4 GB RAM (dynamic), 127 GB OS disk |
| CSV shared disks | 2 | 100 GB fixed VHDX each |
| Witness disk | 1 | 5 GB fixed VHDX |

### Networking

Three virtual switches are required on the Hyper-V host:

| Switch | Type | Purpose |
|---|---|---|
| `Ethernet vSwitch` | External | Host management and cluster node compute traffic |
| `Private vSwitch` | Private | Cluster heartbeat and live migration |
| `Internal vSwitch` | Internal | Domain controller connectivity and host management adapters |

### Active Directory

A single-forest AD domain (`test.lab` by default) is promoted on the dedicated domain controller VM. Cluster nodes are joined to the domain automatically via PowerShell Direct guest automation.

---

## Prerequisites

- Windows host with the **Hyper-V** role enabled
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- WinRM enabled on the Hyper-V host (HTTPS, port 5986)
- A **Windows Server 2025 Datacenter** ISO accessible on the Hyper-V host

---

## Repository Structure

```
terraform/
└── hyperv-cluster/
    ├── main.tf              # Root module — wires hyperv and active-directory modules
    ├── variables.tf         # All input variable declarations
    ├── outputs.tf           # VM names, disk paths, and DC name outputs
    ├── providers.tf         # Hyper-V provider configuration
    ├── versions.tf          # Terraform and provider version constraints
    ├── terraform.tfvars     # Default variable values (customize before applying)
    ├── modules/
    │   ├── hyperv/          # Hyper-V VMs, VHDs, and network adapter resources
    │   └── active-directory/# AD forest promotion and domain join automation
    └── scripts/
        └── Invoke-DomainBootstrap.ps1  # PowerShell Direct guest bootstrap script
```

---

## Usage

### 1. Prepare `terraform.tfvars`

Edit `terraform/hyperv-cluster/terraform.tfvars` and set values appropriate for your environment:

```hcl
# Path to the Windows Server 2025 ISO on the Hyper-V host
iso_path = "D:\\ISOs\\WindowsServer2025.iso"

# WinRM credentials for the local Hyper-V host
hyperv_user     = "Administrator"
hyperv_password = "your-host-password"

# VM naming prefix and storage root
vm_prefix = "TEST"
vm_path   = "D:\\Hyper-V"

# Virtual switch names (must match switches on your host)
management_switch_name = "Ethernet vSwitch"
cluster_switch_name    = "Private vSwitch"
internal_switch_name   = "Internal vSwitch"

# Active Directory settings
domain_name                     = "test.lab"
domain_controller_ipv4          = "172.16.10.10"
domain_controller_prefix_length = 24

# Guest automation credentials
guest_admin_username      = "Administrator"
guest_admin_password      = "your-guest-local-admin-password"
domain_safe_mode_password = "your-dsrm-password"
enable_guest_bootstrap    = true
```

### 2. Initialize and apply

```powershell
cd terraform/hyperv-cluster

terraform init
terraform plan
terraform apply
```

### 3. Review outputs

After a successful apply, Terraform outputs the VM names, OS disk paths, CSV disk paths, and witness disk path for reference.

---

## Providers

| Provider | Source | Version |
|---|---|---|
| hyperv | `taliesins/hyperv` | `~> 1.2.0` |

---

## Notes

- `terraform.tfvars` contains placeholder passwords. Replace all `REPLACE_WITH_*` values before running.
- The `vm_count` variable is locked to `3` and `csv_disk_count` is locked to `2` by input validation — these reflect the intended fixed topology of the lab.
- Virtual machines boot from the ISO; Windows Server installation and initial configuration must be completed manually (or via unattended setup) before the guest bootstrap phase runs.
