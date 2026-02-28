# Network ATC Implementation Guide

This guide covers implementing **Network ATC (Advanced Topology Configuration)** for a Windows Server 2025 Hyper-V failover cluster. Network ATC replaces manual NIC teaming, vSwitch creation, QoS policies, and RDMA configuration with a declarative, intent-based approach — you describe *what* you want the network to do, and Network ATC determines *how* to configure it.

---

## Table of Contents

1. [What is Network ATC?](#1-what-is-network-atc)
2. [Prerequisites](#2-prerequisites)
3. [Network ATC vs. Manual Configuration](#3-network-atc-vs-manual-configuration)
4. [Phase 1 — Install Network ATC](#4-phase-1--install-network-atc)
5. [Phase 2 — Plan Network Intents](#5-phase-2--plan-network-intents)
6. [Phase 3 — Deploy Network Intents](#6-phase-3--deploy-network-intents)
7. [Phase 4 — Verify and Monitor](#7-phase-4--verify-and-monitor)
8. [Phase 5 — Integrate with Failover Cluster](#8-phase-5--integrate-with-failover-cluster)
9. [Customizing Intent Overrides](#9-customizing-intent-overrides)
10. [Updating and Removing Intents](#10-updating-and-removing-intents)
11. [Troubleshooting](#11-troubleshooting)
12. [Appendix — PowerShell Quick Reference](#12-appendix--powershell-quick-reference)

---

## 1. What is Network ATC?

Network ATC is a Windows Server feature (introduced in Windows Server 2022 and enhanced in Windows Server 2025) that automates host networking configuration using **intents**. An intent declares the desired traffic types for a set of NICs and Network ATC handles:

- SET (Switch Embedded Teaming) vSwitch creation
- Host vNIC provisioning
- IP address and VLAN assignment
- RDMA configuration and verification
- QoS and traffic class policies
- DCB (Data Center Bridging) settings
- Network proxy and adapter advanced properties

### Key Concepts

| Concept | Description |
|---|---|
| **Intent** | A declarative definition of what traffic types a set of NICs should carry |
| **Traffic Type** | A predefined category: `Management`, `Compute`, `Storage`, `StretchCluster` |
| **Override** | Custom settings that modify default behavior for an intent |
| **Intent Status** | Provisioning lifecycle: Pending → Validating → Provisioning → Completed |
| **Cluster Scope** | When deployed on a cluster, intents apply uniformly to all nodes |

---

## 2. Prerequisites

- **OS**: Windows Server 2025 Datacenter (or Windows Server 2022 with limited feature set)
- **Networking**: Matching NIC names across all cluster nodes (required for cluster-wide intents)
- **Cluster**: Failover Clustering feature installed (for cluster-scoped intents)
- **RDMA** (optional): RDMA-capable NICs (RoCE v2 or iWARP) for storage intents
- All nodes must have the same NIC naming convention — use `Rename-NetAdapter` if needed

### NIC Naming Requirement

Network ATC requires **identical adapter names** across all cluster nodes. Standardize names before adding intents:

```powershell
# Example: Rename adapters consistently across all nodes
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    # Rename based on MAC or slot — adapt to your environment
    Get-NetAdapter | Sort-Object InterfaceDescription | ForEach-Object -Begin { $i = 1 } -Process {
        $mapping = @{
            1 = "Mgmt-1"
            2 = "Mgmt-2"
            3 = "Storage-1"
            4 = "Storage-2"
            5 = "Compute-1"
            6 = "Compute-2"
        }
        if ($mapping.ContainsKey($i)) {
            Rename-NetAdapter -Name $_.Name -NewName $mapping[$i]
        }
        $i++
    }
}
```

---

## 3. Network ATC vs. Manual Configuration

| Task | Manual Approach | Network ATC |
|---|---|---|
| Create SET vSwitch | `New-VMSwitch -EnableEmbeddedTeaming` | Automatic — part of intent |
| Create host vNICs | `Add-VMNetworkAdapter -ManagementOS` | Automatic — per traffic type |
| Configure RDMA | `Enable-NetAdapterRDMA`, `Set-NetAdapterAdvancedProperty` | Automatic — validated |
| Configure QoS | `New-NetQosPolicy`, `New-NetQosTrafficClass` | Automatic — best practice defaults |
| Configure DCB | `Enable-NetQosFlowControl`, `New-NetQosTrafficClass` | Automatic — traffic-class aware |
| Cluster network naming | Manual rename in cluster manager | Automatic — matches intent |
| Drift detection | None | Continuous — repairs configuration |
| Multi-node consistency | Manual repetition per node | Single command — cluster-wide |

---

## 4. Phase 1 — Install Network ATC

### 4.1 Install the Feature

On **each cluster node**:

```powershell
Install-WindowsFeature -Name NetworkATC -IncludeManagementTools -Restart
```

Or deploy across all nodes remotely:

```powershell
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Install-WindowsFeature -Name NetworkATC -IncludeManagementTools
}
```

### 4.2 Verify Installation

```powershell
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Get-WindowsFeature -Name NetworkATC | Select-Object Name, InstallState
}
```

### 4.3 Verify the Network ATC Service

```powershell
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Get-Service -Name "ovsdb-server" | Select-Object Name, Status
}
```

> **Note**: In Windows Server 2025, Network ATC is fully integrated. The `ovsdb-server` service backs the ATC configuration store.

---

## 5. Phase 2 — Plan Network Intents

### 5.1 Intent Design for This Lab

Based on the lab architecture (6 NICs per node, 3 traffic types), the following intent design is used:

| Intent Name | Traffic Types | NICs | Purpose |
|---|---|---|---|
| `Management-Compute` | Management, Compute | Mgmt-1, Mgmt-2 | Host management + VM guest traffic |
| `Storage` | Storage | Storage-1, Storage-2 | CSV traffic, live migration, RDMA |

> **Design Decision**: Management and Compute are combined into a single intent because they commonly share the same physical uplinks. Storage gets a dedicated intent with its own NICs for optimal RDMA and CSV performance.

### 5.2 Alternative: Three Separate Intents

For environments with enough NICs, you can create fully separated intents:

| Intent Name | Traffic Types | NICs |
|---|---|---|
| `Management` | Management | Mgmt-1, Mgmt-2 |
| `Compute` | Compute | Compute-1, Compute-2 |
| `Storage` | Storage | Storage-1, Storage-2 |

### 5.3 Supported Traffic Type Combinations

Network ATC supports these combinations per intent:

| Combination | Supported |
|---|---|
| Management only | Yes |
| Compute only | Yes |
| Storage only | Yes |
| Management + Compute | Yes |
| Management + Storage | Yes |
| Compute + Storage | Yes |
| Management + Compute + Storage | Yes |

---

## 6. Phase 3 — Deploy Network Intents

### 6.1 Option A — Cluster-Wide Intent (Recommended)

When the failover cluster already exists, add intents at the cluster scope. This applies the configuration to **all nodes automatically**.

Run from **any one cluster node**:

```powershell
# Create a combined Management + Compute intent
Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Management-Compute" `
    -Management `
    -Compute `
    -AdapterName "Mgmt-1", "Mgmt-2"
```

```powershell
# Create a dedicated Storage intent
Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Storage" `
    -Storage `
    -AdapterName "Storage-1", "Storage-2"
```

### 6.2 Option B — Standalone Node Intent (Pre-Cluster)

If Network ATC intents need to be deployed **before** the cluster is formed:

```powershell
# Run on each individual node
Add-NetIntent -Name "Management-Compute" `
    -Management `
    -Compute `
    -AdapterName "Mgmt-1", "Mgmt-2"

Add-NetIntent -Name "Storage" `
    -Storage `
    -AdapterName "Storage-1", "Storage-2"
```

> **Important**: Standalone intents are local to each node. After forming the cluster, convert them to cluster-scoped intents by removing and re-adding with `-ClusterName`.

### 6.3 Wait for Intent Provisioning

Network ATC works asynchronously. Monitor provisioning status:

```powershell
# Check intent status — repeat until all show "Completed"
Get-NetIntentStatus | Select-Object IntentName, Host, ConfigurationStatus, ProvisioningStatus |
    Format-Table -AutoSize
```

Expected progression:

```
IntentName           Host  ConfigurationStatus  ProvisioningStatus
----------           ----  -------------------  ------------------
Management-Compute   HV01  Success              Completed
Management-Compute   HV02  Success              Completed
Management-Compute   HV03  Success              Completed
Storage              HV01  Success              Completed
Storage              HV02  Success              Completed
Storage              HV03  Success              Completed
```

> **Tip**: Provisioning can take 2–5 minutes per intent. If status shows `Failed`, check the error details with `Get-NetIntentStatus -Name "IntentName" | Format-List *`.

### 6.4 What Network ATC Creates Automatically

After successful provisioning, Network ATC will have created:

**For the Management-Compute intent:**

- A SET vSwitch named `Management-Compute` with `Mgmt-1` and `Mgmt-2` teamed
- A host vNIC for management traffic
- QoS policies for management traffic
- Bandwidth reservation for management

**For the Storage intent:**

- A SET vSwitch named `Storage` with `Storage-1` and `Storage-2` teamed
- Two host vNICs for storage traffic (one per physical NIC for RDMA)
- RDMA enabled and configured (if hardware supports it)
- QoS policies for SMB/CSV traffic
- DCB settings for lossless traffic class (RoCE v2)
- Jumbo frames enabled (9014 MTU)

---

## 7. Phase 4 — Verify and Monitor

### 7.1 Verify Intents

```powershell
# List all intents
Get-NetIntent | Select-Object IntentName, IsManagementIntent, IsComputeIntent, IsStorageIntent,
    @{Name='Adapters'; Expression={$_.NetAdapterNamesAsList -join ', '}} |
    Format-Table -AutoSize
```

### 7.2 Verify Created vSwitches

```powershell
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Get-VMSwitch | Select-Object Name, SwitchType, EmbeddedTeamingEnabled |
        Format-Table -AutoSize
}
```

### 7.3 Verify Host vNICs

```powershell
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Get-VMNetworkAdapter -ManagementOS |
        Select-Object Name, SwitchName, @{Name='IPAddress'; Expression={$_.IPAddresses -join ', '}} |
        Format-Table -AutoSize
}
```

### 7.4 Verify RDMA Configuration (Storage Intent)

```powershell
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    # Check RDMA is enabled on storage vNICs
    Get-NetAdapterRdma | Where-Object Enabled | Select-Object Name, Enabled |
        Format-Table -AutoSize

    # Verify SMB Direct (RDMA) connections
    Get-SmbConnection | Where-Object RdmaCapable | Select-Object ServerName, ShareName |
        Format-Table -AutoSize
}
```

### 7.5 Verify QoS Policies

```powershell
Invoke-Command -ComputerName "HV01" -ScriptBlock {
    # View Network ATC-managed QoS policies
    Get-NetQosPolicy | Select-Object Name, Owner, PriorityValue8021Action,
        MinBandwidthWeightAction | Format-Table -AutoSize

    # View traffic classes
    Get-NetQosTrafficClass | Select-Object Name, Priority, BandwidthPercentage, Algorithm |
        Format-Table -AutoSize
}
```

### 7.6 Verify Intent Health

```powershell
# Detailed status for all intents
Get-NetIntentStatus | Format-List IntentName, Host, ConfigurationStatus,
    ProvisioningStatus, Error, Progress, RetryCount
```

---

## 8. Phase 5 — Integrate with Failover Cluster

### 8.1 Cluster Network Configuration

After Network ATC provisions the intents, the failover cluster automatically picks up the new networks. Verify:

```powershell
Get-ClusterNetwork | Select-Object Name, State, Role, Address |
    Format-Table -AutoSize
```

Network ATC automatically names cluster networks based on intent names.

### 8.2 Configure Cluster Network Roles

```powershell
# Verify roles — ATC typically sets these correctly
# 0 = Not used, 1 = Cluster only, 3 = Cluster and client
Get-ClusterNetwork | Format-Table Name, Role -AutoSize

# Adjust if needed
(Get-ClusterNetwork "Storage").Role = 1           # Cluster traffic only
(Get-ClusterNetwork "Management-Compute").Role = 3 # Cluster + client
```

### 8.3 Configure Live Migration to Use Storage Network

```powershell
# Restrict live migration to storage network
Set-VMHost -VirtualMachineMigrationPerformanceOption SMB

# Add storage subnet for live migration
Add-VMMigrationNetwork -Subnet "10.10.10.0/24" -Priority 1

# Verify
Get-VMMigrationNetwork | Format-Table -AutoSize
```

### 8.4 Cluster CSV Settings

```powershell
# Enable CSV cache (if not using Storage Spaces Direct)
(Get-Cluster).BlockCacheSize = 2048  # 2 GB cache

# Verify CSV uses RDMA for direct I/O when available
Get-ClusterSharedVolume | Get-ClusterSharedVolumeState |
    Select-Object VolumeName, Node, StateInfo, FileSystemRedirectedIOReason |
    Format-Table -AutoSize
```

---

## 9. Customizing Intent Overrides

Network ATC applies best-practice defaults, but you can customize settings using **overrides**.

### 9.1 Storage Override — Custom VLAN and Jumbo Frames

```powershell
# Create an adapter property override
$adapterOverride = New-NetIntentAdapterPropertyOverrides
$adapterOverride.JumboPacket = 9014
$adapterOverride.NetworkDirectTechnology = 4  # RoCE v2

# Create a storage override with custom VLANs
$storageOverride = New-NetIntentStorageOverrides
$storageOverride.EnableAutomaticIPGeneration = $false

# Apply intent with overrides
Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Storage" `
    -Storage `
    -AdapterName "Storage-1", "Storage-2" `
    -AdapterPropertyOverrides $adapterOverride `
    -StorageOverrides $storageOverride `
    -StorageVlans 711, 712
```

### 9.2 QoS Override — Custom Bandwidth Allocation

```powershell
# Create a QoS override
$qosOverride = New-NetIntentQosPolicyOverrides
$qosOverride.BandwidthPercentage_SMB = 60
$qosOverride.BandwidthPercentage_Cluster = 2

# Apply to an existing intent
Set-NetIntent -Name "Storage" `
    -QosPolicyOverrides $qosOverride
```

### 9.3 Management Override — Static IP and DNS

```powershell
# Create a site override for static IP management
$siteOverride = New-NetIntentSiteOverrides
$siteOverride.EnableAutomaticIPGeneration = $false

# Re-add intent with site override
Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Management-Compute" `
    -Management `
    -Compute `
    -AdapterName "Mgmt-1", "Mgmt-2" `
    -SiteOverrides $siteOverride
```

### 9.4 Global Overrides

```powershell
# Create a global override object
$globalOverride = New-NetIntentGlobalOverrides

# Customize global proxy settings
$globalOverride.EnableAutomaticIPGeneration = $true

# Apply global overrides
Set-NetIntentGlobalOverrides -GlobalOverrides $globalOverride
```

---

## 10. Updating and Removing Intents

### 10.1 Update an Existing Intent

```powershell
# Add or change adapters in an intent
Set-NetIntent -Name "Management-Compute" `
    -AdapterName "Mgmt-1", "Mgmt-2", "Mgmt-3"
```

### 10.2 Remove a Specific Intent

```powershell
# Remove a single intent (reverts all configuration it created)
Remove-NetIntent -ClusterName "HV-Cluster" -Name "Storage"
```

> **Warning**: Removing an intent tears down the vSwitch, host vNICs, QoS policies, and all related configuration. Plan for network disruption.

### 10.3 Remove All Intents

```powershell
# Remove all intents from the cluster
Get-NetIntent | ForEach-Object {
    Remove-NetIntent -ClusterName "HV-Cluster" -Name $_.IntentName
}
```

### 10.4 Retry a Failed Intent

```powershell
# If an intent fails, check the error and retry
Get-NetIntentStatus -Name "Storage" | Format-List *

# Retry provisioning
Set-NetIntentRetryState -ClusterName "HV-Cluster" -Name "Storage"
```

---

## 11. Troubleshooting

### 11.1 Common Issues

| Symptom | Cause | Resolution |
|---|---|---|
| Intent stuck in `Provisioning` | Adapter names mismatch across nodes | Rename adapters consistently |
| `ConfigurationStatus: Failed` | Conflicting existing vSwitch or team | Remove manual vSwitch/team first |
| RDMA not enabled | NIC doesn't support RDMA | Use adapter property override to disable RDMA requirement |
| QoS policies not applied | DCB not supported on NIC | Use software QoS instead of hardware DCB |
| Intent disappears after reboot | Network ATC service not running | Verify `ovsdb-server` service |

### 11.2 Diagnostic Commands

```powershell
# Detailed intent status with error messages
Get-NetIntentStatus | Where-Object ConfigurationStatus -ne "Success" |
    Format-List IntentName, Host, ConfigurationStatus, Error, ProvisioningStatus

# Network ATC event logs
Get-WinEvent -LogName "Microsoft-Windows-Networking-NetworkATC/Admin" -MaxEvents 50 |
    Select-Object TimeCreated, LevelDisplayName, Message | Format-Table -AutoSize

# View all Network ATC-managed resources
Get-NetIntentAllGoalStates | Format-List
```

### 11.3 Reset Network ATC State

If Network ATC is in a bad state and needs to start fresh:

```powershell
# Remove all intents
Get-NetIntent | ForEach-Object { Remove-NetIntent -Name $_.IntentName }

# Clean up any orphaned vSwitches
Get-VMSwitch | Remove-VMSwitch -Force

# Restart the Network ATC service
Restart-Service -Name "ovsdb-server" -Force

# Re-create intents
Add-NetIntent -ClusterName "HV-Cluster" -Name "Management-Compute" `
    -Management -Compute -AdapterName "Mgmt-1", "Mgmt-2"

Add-NetIntent -ClusterName "HV-Cluster" -Name "Storage" `
    -Storage -AdapterName "Storage-1", "Storage-2"
```

### 11.4 Disable RDMA for Non-RDMA NICs

If your NICs do not support RDMA (common in nested/lab environments):

```powershell
$adapterOverride = New-NetIntentAdapterPropertyOverrides
$adapterOverride.NetworkDirect = 0  # Disable RDMA

Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Storage" `
    -Storage `
    -AdapterName "Storage-1", "Storage-2" `
    -AdapterPropertyOverrides $adapterOverride
```

---

## 12. Appendix — PowerShell Quick Reference

### Core Network ATC Cmdlets

```powershell
# Intent management
Add-NetIntent                        # Create a new intent
Set-NetIntent                        # Modify an existing intent
Remove-NetIntent                     # Remove an intent
Get-NetIntent                        # List all intents

# Status monitoring
Get-NetIntentStatus                  # Provisioning and configuration status
Get-NetIntentAllGoalStates           # Full desired-state view
Set-NetIntentRetryState              # Retry a failed intent

# Overrides
New-NetIntentAdapterPropertyOverrides  # NIC-level overrides (RDMA, jumbo, etc.)
New-NetIntentStorageOverrides          # Storage-specific overrides  
New-NetIntentQosPolicyOverrides        # QoS bandwidth and policy overrides
New-NetIntentSiteOverrides             # Site-level overrides
New-NetIntentGlobalOverrides           # Cluster-wide global overrides
Set-NetIntentGlobalOverrides           # Apply global overrides
```

### End-to-End Example: Minimal 2-Intent Cluster Setup

```powershell
# 1. Install features on all nodes
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Install-WindowsFeature -Name Hyper-V, Failover-Clustering, NetworkATC `
        -IncludeManagementTools
}

# 2. Restart all nodes
Restart-Computer -ComputerName "HV01", "HV02", "HV03" -Force

# 3. Create the cluster (after reboot and domain join)
New-Cluster -Name "HV-Cluster" -Node "HV01", "HV02", "HV03" `
    -StaticAddress "172.16.10.20" -NoStorage

# 4. Deploy Network ATC intents
Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Management-Compute" `
    -Management -Compute `
    -AdapterName "Mgmt-1", "Mgmt-2"

Add-NetIntent -ClusterName "HV-Cluster" `
    -Name "Storage" `
    -Storage `
    -AdapterName "Storage-1", "Storage-2"

# 5. Wait for provisioning
do {
    $status = Get-NetIntentStatus
    $pending = $status | Where-Object ProvisioningStatus -ne "Completed"
    if ($pending) {
        Write-Host "Waiting for $($pending.Count) intent(s) to complete..."
        Start-Sleep -Seconds 30
    }
} while ($pending)

Write-Host "All Network ATC intents provisioned successfully."

# 6. Add storage and create CSV
Get-ClusterAvailableDisk | Add-ClusterDisk
Add-ClusterSharedVolume -Name "Cluster Disk 1"
Add-ClusterSharedVolume -Name "Cluster Disk 2"
Set-ClusterQuorum -DiskWitness "Cluster Disk 3"
```

---

## Related Guides

- [Hyper-V Failover Cluster Lab Guide](hyper-v-failover-cluster-lab-guide.md) — Manual step-by-step cluster setup with SET vSwitches
