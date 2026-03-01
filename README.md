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
- [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) (for building the custom ISO with `oscdimg.exe`)
- WinRM enabled on the Hyper-V host (HTTP, port 5985, NTLM auth)
- A **Windows Server 2025 Datacenter** ISO accessible on the Hyper-V host

---

## Repository Structure

```
scripts/
├── Confirm-LocalAdminCredential.ps1
├── Invoke-HyperVLabSnapshot.ps1
└── Invoke-TerraformApply.ps1          # Wrapper for terraform apply with credentials
terraform/
├── main.tf                            # Root module — wires hyperv and active-directory modules
├── variables.tf                       # All input variable declarations
├── outputs.tf                         # VM names, disk paths, and DC name outputs
├── providers.tf                       # Hyper-V provider configuration (WinRM over HTTP)
├── versions.tf                        # Terraform and provider version constraints
├── terraform.tfvars                   # Default variable values (customize before applying)
├── modules/
│   ├── hyperv/                        # Hyper-V VMs, VHDs, and network adapter resources
│   │   ├── main.tf                    # VM, VHD, DVD drives, firmware boot order
│   │   ├── locals.tf                  # Computed names, paths, disk maps
│   │   ├── variables.tf               # Module input variables with validation
│   │   ├── outputs.tf                 # Module outputs
│   │   └── versions.tf                # Provider version constraints
│   └── active-directory/              # AD forest promotion and domain join automation
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── scripts/
    ├── autounattend-dc.xml            # Unattended answer file for domain controller
    ├── autounattend-node.xml          # Unattended answer file for cluster nodes
    └── Invoke-DomainBootstrap.ps1     # PowerShell Direct guest bootstrap script
docs/
├── hyper-v-failover-cluster-lab-guide.md
├── network-atc-implementation-guide.md
└── winrm-lessons-learned.md
```

---

## Custom ISO Build Process

Windows Server 2025 introduced a redesigned Setup UI that requires a custom ISO for fully unattended installation on Hyper-V Gen 2 VMs. The standard ISO has two problems:

1. **"Press any key to boot from CD or DVD"** — The UEFI boot loader (`bootx64.efi`) embedded in the stock ISO prompts for a keypress. When no one presses a key (automation scenario), the boot "fails" and falls through to PXE, producing the error: `SCSI DVD (0,1) The boot loader failed.`

2. **Answer file discovery** — Windows Setup must find `autounattend.xml` to automate installation. The most reliable method is embedding it directly in the ISO root.

### Building the No-Prompt ISO

The following steps produce a custom ISO that boots without user interaction and includes the answer file. Requires the Windows ADK (`oscdimg.exe`).

```powershell
# Mount the original ISO
$srcIso = "D:\Media\Windows\Windows Server 2025 Updated September 2025.iso"
$work   = "D:\Hyper-V\ClusterLab\WinSvr2025_noprompt"
$outIso = "D:\Hyper-V\ClusterLab\WinSvr2025_noprompt.iso"

$img = Mount-DiskImage -ImagePath $srcIso -PassThru
$drv = ($img | Get-Volume).DriveLetter

# Copy ISO contents to a working directory
robocopy "${drv}:\" $work /E

# Remove the BIOS "press any key" prompt binary
Remove-Item "$work\boot\bootfix.bin" -Force

# Replace the UEFI boot loader with the no-prompt version
Copy-Item "$work\efi\microsoft\boot\cdboot_noprompt.efi" "$work\efi\boot\bootx64.efi" -Force

# Copy the answer file into the ISO root
Copy-Item "terraform\scripts\autounattend-dc.xml" "$work\autounattend.xml" -Force

# Dismount the original ISO
Dismount-DiskImage -ImagePath $srcIso

# Build the custom ISO with oscdimg (dual BIOS/UEFI boot)
$oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"

& $oscdimg -m -o -u2 -udfver102 `
  "-bootdata:2#p0,e,b$work\boot\etfsboot.com#pEF,e,b$work\efi\microsoft\boot\efisys_noprompt.bin" `
  $work $outIso

# Clean up working directory (optional, saves ~7 GB)
Remove-Item $work -Recurse -Force
```

### Key Files in the ISO

| Original File | No-Prompt Replacement | Purpose |
|---|---|---|
| `\boot\bootfix.bin` | *(deleted)* | BIOS "press any key" prompt |
| `\efi\boot\bootx64.efi` | `\efi\microsoft\boot\cdboot_noprompt.efi` | UEFI boot loader (Gen 2 VMs load this directly) |
| `\efi\microsoft\boot\efisys.bin` | `\efi\microsoft\boot\efisys_noprompt.bin` | El Torito UEFI boot catalog image |

---

## Answer File Configuration

The unattended answer files (`autounattend-dc.xml` and `autounattend-node.xml`) handle:

| Setup Phase | What It Configures |
|---|---|
| `windowsPE` | Language (en-US), disk partitioning (GPT: EFI + MSR + WinRE + OS), image selection, product key, EULA acceptance |
| `specialize` | Computer name, time zone (Eastern) |
| `oobeSystem` | Administrator password, auto-logon, skip all OOBE prompts |

### Partition Layout (UEFI/GPT)

| # | Type | Size | Format | Label |
|---|---|---|---|---|
| 1 | EFI System | 260 MB | FAT32 | System |
| 2 | MSR | 16 MB | — | — |
| 3 | Recovery (WinRE) | 1000 MB | NTFS | WinRE |
| 4 | Primary (OS) | Remainder | NTFS | Windows |

### Product Key

Both answer files use the Windows Server 2025 Datacenter KMS client setup key: `D764K-2NDRG-47T6Q-P8T8W-YP6DF`. This is a [Generic Volume License Key (GVLK)](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys) that allows installation without activation — appropriate for lab environments.

### DC vs. Node Differences

| Setting | DC (`autounattend-dc.xml`) | Node (`autounattend-node.xml`) |
|---|---|---|
| ComputerName | `TEST-DC01` | `*` (auto-assigned by Hyper-V) |

---

## Usage

### Script Locations

Use the script directories based on how scripts are executed:

- Manual operational scripts: `scripts/`
- Terraform-invoked scripts and artifacts: `terraform/scripts/`

Top-level manual scripts:

- `scripts/Invoke-HyperVLabSnapshot.ps1` - Create, revert, or delete snapshots across lab VMs
- `scripts/Confirm-LocalAdminCredential.ps1` - Validate Hyper-V local admin credentials
- `scripts/Invoke-TerraformApply.ps1` - Wrapper for `terraform apply`

Terraform automation scripts/artifacts:

- `terraform/scripts/Invoke-DomainBootstrap.ps1` - Guest bootstrap script invoked by Terraform
- `terraform/scripts/autounattend-dc.xml` - Domain controller unattended setup file
- `terraform/scripts/autounattend-node.xml` - Cluster node unattended setup file

### 1. Build the Custom ISO

Follow the [Custom ISO Build Process](#custom-iso-build-process) to create `WinSvr2025_noprompt.iso`.

### 2. Prepare `terraform.tfvars`

Edit `terraform/terraform.tfvars` and set values appropriate for your environment:

```hcl
# Path to the custom no-prompt ISO on the Hyper-V host
iso_path = "D:\\Hyper-V\\ClusterLab\\WinSvr2025_noprompt.iso"

# WinRM credentials (or set via TF_VAR_hyperv_user / TF_VAR_hyperv_password env vars)
hyperv_user     = "GT-100821\\Administrator"
hyperv_password = "your-host-password"

# VM naming prefix and storage root
vm_prefix = "TEST"
vm_path   = "D:\\Hyper-V\\ClusterLab"

# Virtual switch names (must match switches on your host)
management_switch_name = "Ethernet vSwitch"
cluster_switch_name    = "Private vSwitch"
internal_switch_name   = "Internal vSwitch"

# Active Directory settings
domain_name                     = "test.lab"
domain_controller_ipv4          = "172.16.10.10"
domain_controller_prefix_length = 24

# Guest automation
enable_guest_bootstrap = false   # Set to true after Windows is installed
```

### 3. Initialize and Apply

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

### 4. Review Outputs

After a successful apply, Terraform outputs the VM names, OS disk paths, CSV disk paths, and witness disk path for reference.

---

## Providers

| Provider | Source | Version |
|---|---|---|
| hyperv | `taliesins/hyperv` | `~> 1.2.0` |

---

## Lessons Learned

### UEFI DVD Boot Failure on Gen 2 VMs

The most persistent issue encountered during development was `SCSI DVD (0,1) The boot loader failed` on Gen 2 VMs. Root cause: the stock Windows Server ISO's UEFI boot loader (`bootx64.efi`) displays "Press any key to boot from CD or DVD" and times out silently when no keypress is received. In Hyper-V Gen 2ÊVMs, there's no way to send keystrokes fast enough via automation to catch this prompt reliably.

**Fix:** Rebuild the ISO with the no-prompt boot files that ship alongside the originals on every Windows Server ISO (`cdboot_noprompt.efi` and `efisys_noprompt.bin`). These skip the keypress prompt entirely. Also delete `boot\bootfix.bin` (the BIOS equivalent).

### WinRM Authentication

The Terraform Hyper-V provider communicates over WinRM. Key configuration:

- Use HTTP (port 5985) with NTLM authentication for local development
- Credential format must be `HOSTNAME\Username` (not just `Username`)
- Set a generous timeout (300s) — VM creation operations can be slow

### Answer File Iteration

Windows Server 2025 Setup requires specific answer file elements that weren't needed on earlier versions:

- A **KMS client setup key** (`<Key>`) is required to skip the product key screen
- **Image name** (`/IMAGE/NAME`) must be specified to auto-select the edition (Desktop Experience vs. Server Core)
- **EFI partition** should be 260 MB (the old 100 MB default may fail validation)
- A **WinRE partition** (1000 MB) is needed for the recovery environment
- The most reliable answer file delivery method is **embedding `autounattend.xml` in the ISO root** rather than using a separate floppy or second DVD drive

### Shared VHDX Storage

Shared VHDX with persistent reservations (for cluster CSV) requires the backing storage to be on a **ReFS** or **CSVFS** volume, or accessed via **SMB 3.x** share. NTFS volumes do not support the persistent reservation SCSI commands. The current workaround uses an SMB share (`\\localhost\ClusterDisks`) pointing to the local disk.

---

## Notes

- `terraform.tfvars` contains placeholder passwords. Replace all values before running.
- The `vm_count` variable is locked to `3` and `csv_disk_count` is locked to `2` by input validation — these reflect the intended fixed topology of the lab.
- Virtual machines boot from the custom ISO and install Windows Server fully unattended via the embedded answer file.
- The custom ISO must be rebuilt if the answer file changes. Keep the `WinSvr2025_noprompt/` working directory as a cache to speed up rebuilds, or delete it to save ~7 GB of disk space.
