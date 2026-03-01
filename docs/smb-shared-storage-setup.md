# SMB Shared Storage Setup for Hyper-V Failover Clustering

This walkthrough covers configuring an **SMB 3.x file share** as shared storage for a Windows Server 2025 Hyper-V failover cluster. SMB shares hosted on the domain controller (or a dedicated file server) provide a straightforward alternative to iSCSI or shared VHDX when building a nested lab environment.

This guide is a companion to the [Hyper-V Failover Cluster Lab Guide](hyper-v-failover-cluster-lab-guide.md) and replaces the shared VHDX approach described in Phase 4 — Storage Configuration, Section 6.1.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 — Prepare the File Server](#3-phase-1--prepare-the-file-server)
4. [Phase 2 — Create SMB Shares](#4-phase-2--create-smb-shares)
5. [Phase 3 — Configure SMB Permissions](#5-phase-3--configure-smb-permissions)
6. [Phase 4 — Configure Cluster Nodes](#6-phase-4--configure-cluster-nodes)
7. [Phase 5 — Verify Connectivity](#7-phase-5--verify-connectivity)
8. [Phase 6 — Integrate with Failover Clustering](#8-phase-6--integrate-with-failover-clustering)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Overview

### Why SMB for Cluster Storage?

SMB 3.x (available since Windows Server 2012 R2 and fully mature in Windows Server 2025) supports features required for Hyper-V shared storage:

| Feature | Benefit |
|---|---|
| SMB Multichannel | Aggregates bandwidth across multiple NICs |
| SMB Direct (RDMA) | Near-zero latency when RDMA NICs are available |
| Transparent Failover | Seamless reconnection during brief server interruptions |
| Continuous Availability | Persistent handles survive file server failover |
| VSS Remote File Share | Supports application-consistent backups of VMs on SMB shares |

### Architecture

In this lab, the domain controller (`TEST-DC01`) doubles as the SMB file server. For production workloads, use a dedicated file server or a Scale-Out File Server (SOFS) cluster.

| Component | Role | IP Address |
|---|---|---|
| TEST-DC01 | Domain controller + SMB file server | 172.16.10.10 |
| HV01 | Cluster node | 172.16.10.11 |
| HV02 | Cluster node | 172.16.10.12 |
| HV03 | Cluster node | 172.16.10.13 |

### Storage Layout

| Share Name | UNC Path | Purpose | Size |
|---|---|---|---|
| ClusterVMs | `\\TEST-DC01\ClusterVMs` | VM virtual hard disks and configurations | 200 GB+ |
| ClusterWitness | `\\TEST-DC01\ClusterWitness` | File share witness for quorum | 5 GB |

---

## 2. Prerequisites

- Domain controller (`TEST-DC01`) is operational with Active Directory and DNS
- All cluster nodes are domain-joined to `test.lab`
- Management network connectivity (172.16.10.0/24) between all nodes and the file server
- The `File Server` role is available on the file server (installed by default on Windows Server)

---

## 3. Phase 1 — Prepare the File Server

Run all commands in this phase on `TEST-DC01`.

### 3.1 Install the File Server Role

The File Server role is typically installed by default, but verify and add it if missing:

```powershell
# Verify the File Server role is installed
Get-WindowsFeature -Name FS-FileServer | Select-Object Name, InstallState

# Install if not present
Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools
```

### 3.2 Create Storage Directories

```powershell
# Create directory for VM storage
New-Item -Path "D:\Shares\ClusterVMs" -ItemType Directory -Force

# Create directory for the file share witness
New-Item -Path "D:\Shares\ClusterWitness" -ItemType Directory -Force
```

> **Note**: Use a separate physical disk or volume (D: drive) for share storage whenever possible. Keeping share data off the OS volume avoids I/O contention.

---

## 4. Phase 2 — Create SMB Shares

### 4.1 Create the VM Storage Share

```powershell
# Create the share for cluster VM storage
New-SmbShare -Name "ClusterVMs" `
    -Path "D:\Shares\ClusterVMs" `
    -Description "Hyper-V cluster VM storage" `
    -FullAccess "test\Domain Admins" `
    -CachingMode None `
    -FolderEnumerationMode AccessBased
```

> **Important**: Set `-CachingMode None` to disable client-side caching. Cached Hyper-V files can cause data corruption.

### 4.2 Create the File Share Witness Share

```powershell
# Create the share for the cluster quorum witness
New-SmbShare -Name "ClusterWitness" `
    -Path "D:\Shares\ClusterWitness" `
    -Description "Cluster file share witness" `
    -FullAccess "test\Domain Admins" `
    -CachingMode None
```

### 4.3 Verify Share Creation

```powershell
# List shares on the file server
Get-SmbShare | Where-Object Name -notlike "*$" |
    Select-Object Name, Path, Description | Format-Table -AutoSize
```

---

## 5. Phase 3 — Configure SMB Permissions

Cluster nodes access the SMB share using their **computer accounts**. Both NTFS and share permissions must grant access.

### 5.1 Configure Share Permissions

```powershell
# Grant Full Control to each cluster node's computer account
$nodes = @("HV01$", "HV02$", "HV03$")

foreach ($node in $nodes) {
    # VM storage share
    Grant-SmbShareAccess -Name "ClusterVMs" `
        -AccountName "test\$node" `
        -AccessRight Full `
        -Force
}

# Grant the cluster name object (CNO) access to the witness share
Grant-SmbShareAccess -Name "ClusterWitness" `
    -AccountName "test\HV-Cluster$" `
    -AccessRight Full `
    -Force
```

> **Note**: The cluster name object (`HV-Cluster$`) is the Active Directory computer account created when the failover cluster is formed. If the cluster doesn't exist yet, grant permissions to the node computer accounts and add the CNO after cluster creation.

### 5.2 Configure NTFS Permissions

```powershell
# Grant NTFS Full Control to cluster node computer accounts on the VM share
$vmPath = "D:\Shares\ClusterVMs"

foreach ($node in $nodes) {
    $acl = Get-Acl -Path $vmPath
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "test\$node", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($rule)
    Set-Acl -Path $vmPath -AclObject $acl
}

# Grant NTFS Full Control to the CNO on the witness share
$witnessPath = "D:\Shares\ClusterWitness"
$acl = Get-Acl -Path $witnessPath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "test\HV-Cluster$", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl -Path $witnessPath -AclObject $acl
```

### 5.3 Verify Permissions

```powershell
# Verify share permissions
Get-SmbShareAccess -Name "ClusterVMs" | Format-Table -AutoSize
Get-SmbShareAccess -Name "ClusterWitness" | Format-Table -AutoSize

# Verify NTFS permissions
(Get-Acl -Path "D:\Shares\ClusterVMs").Access |
    Select-Object IdentityReference, FileSystemRights | Format-Table -AutoSize
```

---

## 6. Phase 4 — Configure Cluster Nodes

Run the following on **each cluster node** (HV01, HV02, HV03).

### 6.1 Verify SMB Client Configuration

```powershell
# Confirm SMB Multichannel is enabled (default in WS2025)
Get-SmbClientConfiguration | Select-Object EnableMultichannel

# Confirm SMB signing is enabled
Get-SmbClientConfiguration | Select-Object RequireSecuritySignature
```

### 6.2 Set Default Hyper-V Storage Paths to the SMB Share

```powershell
# Point Hyper-V default paths to the SMB share
Set-VMHost -VirtualMachinePath "\\TEST-DC01\ClusterVMs" `
           -VirtualHardDiskPath "\\TEST-DC01\ClusterVMs"
```

### 6.3 Test SMB Access from Each Node

```powershell
# Test share access (run on each cluster node)
Test-Path "\\TEST-DC01\ClusterVMs"
Test-Path "\\TEST-DC01\ClusterWitness"

# Create and remove a test file
New-Item -Path "\\TEST-DC01\ClusterVMs\test-$env:COMPUTERNAME.txt" -ItemType File -Force
Remove-Item -Path "\\TEST-DC01\ClusterVMs\test-$env:COMPUTERNAME.txt" -Force
```

---

## 7. Phase 5 — Verify Connectivity

### 7.1 Test SMB Connection Details

```powershell
# View active SMB sessions from the file server
Get-SmbSession | Select-Object ClientComputerName, ClientUserName, Dialect |
    Format-Table -AutoSize

# View active SMB connections from a cluster node
Get-SmbConnection | Select-Object ServerName, ShareName, Dialect, NumOpens |
    Format-Table -AutoSize
```

### 7.2 Verify SMB Dialect

Windows Server 2025 should negotiate SMB 3.1.1. Confirm the dialect is 3.x:

```powershell
# Check the negotiated SMB dialect
Get-SmbConnection -ServerName "TEST-DC01" |
    Select-Object ServerName, ShareName, Dialect
```

Expected output:

```
ServerName ShareName    Dialect
---------- ---------    -------
TEST-DC01  ClusterVMs   3.1.1
TEST-DC01  ClusterWitness 3.1.1
```

### 7.3 Test SMB Multichannel (Optional)

If multiple NICs are available between the file server and cluster nodes:

```powershell
# Check multichannel connections
Get-SmbMultichannelConnection -ServerName "TEST-DC01" |
    Select-Object ServerName, ClientIPAddress, ServerIPAddress, ClientInterfaceIndex |
    Format-Table -AutoSize
```

---

## 8. Phase 6 — Integrate with Failover Clustering

After creating the failover cluster (see [Phase 6 — Failover Clustering](hyper-v-failover-cluster-lab-guide.md#8-phase-6--failover-clustering) in the main guide), configure the cluster to use the SMB shares.

### 8.1 Configure File Share Witness

```powershell
# Set the cluster quorum to use a file share witness
Set-ClusterQuorum -FileShareWitness "\\TEST-DC01\ClusterWitness"

# Verify quorum configuration
Get-ClusterQuorum | Select-Object Cluster, QuorumResource, QuorumType
```

### 8.2 Create Highly Available VMs on the SMB Share

With SMB storage, you create VMs directly on the UNC path instead of on Cluster Shared Volumes:

```powershell
# Create a VM on the SMB share
New-VM -Name "ProdVM01" `
    -MemoryStartupBytes 4GB `
    -NewVHDPath "\\TEST-DC01\ClusterVMs\ProdVM01\ProdVM01.vhdx" `
    -NewVHDSizeBytes 100GB `
    -Generation 2

# Add the VM to the cluster for high availability
Add-ClusterVirtualMachineRole -VMName "ProdVM01"
```

### 8.3 Live Migration with SMB Storage

Live migration works seamlessly with SMB storage because all nodes access the same UNC path. No storage migration is needed — only the VM state transfers between nodes:

```powershell
# Migrate a VM to another node
Move-ClusterVirtualMachineRole -Name "ProdVM01" -Node "HV02" -MigrationType Live
```

---

## 9. Troubleshooting

### Access Denied When Accessing Shares

```powershell
# Verify the computer account has share and NTFS permissions
Get-SmbShareAccess -Name "ClusterVMs"
(Get-Acl "D:\Shares\ClusterVMs").Access | Format-Table IdentityReference, FileSystemRights

# Test access using the computer account context (run on the cluster node)
Test-Path "\\TEST-DC01\ClusterVMs"
```

If access fails, confirm the node is domain-joined and its computer account exists in Active Directory:

```powershell
Get-ADComputer -Identity "HV01"
```

### SMB Dialect Below 3.x

If the negotiated dialect is below 3.0, check for GPO restrictions or mismatched server/client versions:

```powershell
# Check the maximum SMB version on the server
Get-SmbServerConfiguration | Select-Object EnableSMB2Protocol

# Check the client
Get-SmbClientConfiguration | Select-Object EnableSMB2Protocol
```

### Slow Performance

```powershell
# Check if SMB Multichannel is active
Get-SmbMultichannelConnection -ServerName "TEST-DC01"

# Check if SMB signing is causing overhead (expected in domain environments)
Get-SmbServerConfiguration | Select-Object RequireSecuritySignature, EnableSecuritySignature
```

### Quorum Witness Failures

```powershell
# Verify the cluster can access the witness share
Invoke-Command -ComputerName "HV01" -ScriptBlock {
    Test-Path "\\TEST-DC01\ClusterWitness"
}

# Check cluster quorum status
Get-ClusterQuorum
Get-ClusterResource | Where-Object ResourceType -eq "File Share Witness" |
    Select-Object Name, State, OwnerNode
```
