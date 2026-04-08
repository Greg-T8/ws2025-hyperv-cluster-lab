# Hyper-V Failover Cluster Lab Guide

This guide walks through the end-to-end process of building a **Windows Server 2025 Datacenter** Hyper-V failover cluster — from bare host configuration through to a fully operational cluster with Cluster Shared Volumes (CSV). It uses **Switch Embedded Teaming (SET)** for virtual switch configuration, which is the recommended approach for Windows Server 2025 Hyper-V deployments.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 — Host Configuration](#3-phase-1--host-configuration)
4. [Phase 2 — Install and Configure Hyper-V Role](#4-phase-2--install-and-configure-hyper-v-role)
5. [Phase 3 — Networking with SET Virtual Switches](#5-phase-3--networking-with-set-virtual-switches)
6. [Phase 4 — Storage Configuration](#6-phase-4--storage-configuration)
7. [Phase 5 — Active Directory Preparation](#7-phase-5--active-directory-preparation)
8. [Phase 6 — Failover Clustering](#8-phase-6--failover-clustering)
9. [Phase 7 — Cluster Shared Volumes](#9-phase-7--cluster-shared-volumes)
10. [Phase 8 — Configure Live Migration](#10-phase-8--configure-live-migration)
11. [Phase 9 — Validation and Testing](#11-phase-9--validation-and-testing)
12. [Appendix — PowerShell Quick Reference](#12-appendix--powershell-quick-reference)

---

## 1. Architecture Overview

This lab deploys a 3-node Hyper-V failover cluster with a dedicated domain controller, shared storage, and Active Directory.

| Component | Count | Specification |
|---|---|---|
| Cluster nodes | 3 | Gen 2, 4 vCPUs, 8 GB RAM (dynamic), 127 GB OS disk |
| Domain controller | 1 | Gen 2, 2 vCPUs, 4 GB RAM (dynamic), 127 GB OS disk |
| CSV shared disks | 2 | 100 GB fixed VHDX each |
| Witness disk | 1 | 5 GB fixed VHDX |

### Network Topology

The diagram below maps the NIC chain inside each cluster node guest OS, where VM vNICs act as physical adapters teamed into dedicated SET virtual switches.

```mermaid
%%{init: {
    "theme": "base",
    "themeVariables": {
        "background": "#FDFEFE",
        "primaryTextColor": "#323130",
        "lineColor": "#605E5C",
        "clusterBkg": "#F7FAFD",
        "clusterBorder": "#A7BDD4"
    }
}}%%
graph LR
    subgraph NODE["HV01 / HV02 / HV03 — Cluster Nodes (representative)"]
        subgraph GNICS["VM vNICs (physical adapters inside guest OS)"]
            M1["pNIC-Mgmt-1"]
            M2["pNIC-Mgmt-2"]
            IC1["pNIC-Interconnect-1"]
            IC2["pNIC-Interconnect-2"]
            CP1["pNIC-Compute-1"]
            CP2["pNIC-Compute-2"]
        end

        subgraph GSET["SET Virtual Switches"]
            SET_M["Mgmt\nSET · External"]
            SET_I["Interconnect\nSET · External"]
            SET_CP["Compute\nSET · External"]
        end

        subgraph GVNICS["Host vNICs"]
            HV_MGMT["Host Management\n192.168.148.x/24"]
            HV_CLUS["Cluster Heartbeat\n10.10.10.x/24"]
            HV_LM["Live Migration\n10.10.20.x/24"]
        end

        M1 & M2 --> SET_M
        IC1 & IC2 --> SET_I
        CP1 & CP2 --> SET_CP
        SET_M --> HV_MGMT
        SET_I --> HV_CLUS
        SET_I --> HV_LM
    end

    classDef mgmt fill:#DCEEFF,stroke:#2F78C4,stroke-width:1px,color:#1F2937;
    classDef cluster fill:#DDF4E4,stroke:#2E8B57,stroke-width:1px,color:#1F2937;
    classDef livemig fill:#EADFFD,stroke:#6F4BB8,stroke-width:1px,color:#1F2937;
    classDef vmnet fill:#FFE8CC,stroke:#C46A1A,stroke-width:1px,color:#1F2937;

    class M1,M2,SET_M,HV_MGMT mgmt;
    class IC1,IC2,SET_I,HV_CLUS,HV_LM cluster;
    class CP1,CP2,SET_CP vmnet;

    style NODE fill:#F6FAFD,stroke:#9FB3C8,stroke-width:1px,color:#1F2937
    style GNICS fill:#FFFFFF,stroke:#B9C7D6,stroke-width:1px,color:#1F2937
    style GSET fill:#FFFFFF,stroke:#B9C7D6,stroke-width:1px,color:#1F2937
    style GVNICS fill:#FFFFFF,stroke:#B9C7D6,stroke-width:1px,color:#1F2937
```

### Network Design

Each cluster node uses **six physical NICs** (or virtual NICs in a nested lab) organized into three SET teams:

| SET vSwitch | Member NICs | Traffic Type | Switch Type |
|---|---|---|---|
| `Mgmt` | pNIC-Mgmt-1, pNIC-Mgmt-2 | Host management, DNS, domain traffic | External |
| `Interconnect` | pNIC-Interconnect-1, pNIC-Interconnect-2 | Cluster heartbeat, live migration traffic | External |
| `Compute` | pNIC-Compute-1, pNIC-Compute-2 | Compute guest network traffic | External |

### IP Addressing

| Network | Subnet | Purpose |
|---|---|---|
| Management | 192.168.148.0/24 | Host management, AD, DNS |
| Cluster | 10.10.10.0/24 | Cluster-internal communication |
| Live Migration | 10.10.20.0/24 | VM live migration traffic |
| Compute | Varies | Compute guest traffic |

> **Note**: In classic single-site/single-subnet cluster designs, the Cluster and Live Migration networks typically do not need to be routable beyond the local segment. If cluster nodes span subnets or sites, those networks must be routable between nodes.
>
> **Addressing Example Note**: The IP ranges in this guide are example values only. Adjust all subnets and host IPs to match your environment and IPAM standards.

### Host and Cluster Service IP Mapping

| Host / Service | Management IP | Cluster IP | Live Migration IP | Notes |
|---|---|---|---|---|
| `HV01` | 192.168.148.51 | 10.10.10.11 | 10.10.20.21 | Node 1 |
| `HV02` | 192.168.148.52 | 10.10.10.12 | 10.10.20.22 | Node 2 |
| `HV03` | 192.168.148.53 | 10.10.10.13 | 10.10.20.23 | Node 3 |
| `HV-Cluster` (cluster service name/IP) | 192.168.148.50 | N/A | N/A | Cluster client access point |

---

## 2. Prerequisites

- **Host OS**: Windows Server 2025 Datacenter (or Windows 11/Windows Server 2022 with Hyper-V for nested lab)
- **Hardware**: Minimum 32 GB RAM, 500 GB free disk, CPU with SLAT support
- **Software**: PowerShell 7+, Windows Server 2025 Datacenter ISO
- **Network**: NICs matching your vSwitch design (physical or nested virtual adapters)
- All cluster nodes must share the same Windows Server version and edition

---

## 3. Phase 1 — Host Configuration

Run the following on **each cluster node** after installing Windows Server 2025 Datacenter.

### 3.1 Set Computer Name

```powershell
Rename-Computer -NewName "HV01" -Restart
# Repeat for HV02, HV03
```

### 3.2 Configure Windows Update

```powershell
# Install all pending updates
Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers
Import-Module PSWindowsUpdate
Get-WindowsUpdate -Install -AcceptAll -AutoReboot
```

### 3.3 Configure Remote Management

```powershell
# Enable remote desktop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Enable PowerShell remoting
Enable-PSRemoting -Force
```

### 3.4 Configure Power Settings

```powershell
powercfg /setactive SCHEME_MIN  # High performance
```

---

## 4. Phase 2 — Install and Configure Hyper-V Role

### 4.1 Install the Hyper-V Role

```powershell
Install-WindowsFeature -Name Hyper-V `
    -IncludeManagementTools `
    -Restart
```

<img src='.img/2026-03-01-10-13-17.png' width=800>

### 4.2 Configure Default Hyper-V Paths

```powershell
Set-VMHost -VirtualMachinePath "C:\Hyper-V" -VirtualHardDiskPath "C:\Hyper-V"
```

> **Note**: This initial path is intended for early host setup. After Cluster Shared Volumes are configured in Phase 7, update both defaults to `C:\ClusterStorage\Volume1` in Step 9.5.

### 4.3 Configure Hyper-V Host Settings

| Setting | Value | Description |
|---|---|---|
| NUMA Spanning | Enabled (`$true`) | Allows VMs to allocate memory across NUMA boundaries when a single NUMA node cannot satisfy the request. |
| Enhanced Session Mode | Enabled (`$true`) | Improves VM console usability by enabling richer guest/host integration in Hyper-V Manager sessions. |
| Maximum Virtual Machine Migrations | `2` | Limits concurrent live migrations per host to balance migration speed with workload stability. |

```powershell
# Enable NUMA spanning (useful for VMs larger than a single NUMA node)
Set-VMHost -NumaSpanningEnabled $true

# Configure enhanced session mode
Set-VMHost -EnableEnhancedSessionMode $true

# Set live migration settings (configured fully in Phase 8)
Set-VMHost -MaximumVirtualMachineMigrations 2
```

---

## 5. Phase 3 — Networking with SET Virtual Switches

**Switch Embedded Teaming (SET)** is the replacement for traditional NIC Teaming (LBFO) in Hyper-V environments starting with Windows Server 2016. SET is integrated directly into the Hyper-V virtual switch, providing NIC teaming functionality without a separate LBFO team. In Windows Server 2025, SET is the recommended and fully supported approach.

### 5.1 Why SET Over Traditional NIC Teaming

| Feature | LBFO (Legacy) | SET (Recommended) |
|---|---|---|
| Hyper-V integration | Separate layer | Built into vSwitch |
| Max team members | 32 | 8 |
| Supported in WS2025 | Deprecated | Fully supported |
| Management plane | Separate | Unified with vSwitch |

### 5.1a Design Principles (UCS Policy Alignment)

This configuration aligns with the Cisco UCS + Hyper-V migration design:

- **Three SET switches**: Mgmt, Interconnect (Cluster + Live Migration), Compute
- **MTU 9000 for Interconnect** (Live Migration + Storage traffic); Mgmt remains at 1500
- **Weight-based QoS** — avoid hard bandwidth caps; allow burst when capacity is available
- **HyperVPort load balancing** — deterministic behavior aligned with UCS fabric pinning
- **Offload and queue features enabled** — VMQ, VMMQ, RSS, and checksum offloads aligned to UCS adapter policy

### 5.2 Identify Physical Adapters

Before creating SET switches, identify the NICs on each node:

```powershell
Get-NetAdapter | Select-Object Name, InterfaceIndex, InterfaceDescription, Status, LinkSpeed | Sort-Object Name | Format-Table -AutoSize
```

<img src='.img/2026-04-07-14-13-50.png' width='800'>

<img src='.img/2026-04-07-14-14-33.png' width='700'>

### 5.3 Create the Management SET vSwitch

> **Note**: In the following process, the host will temporarily lose RDP connectivity (~30s) while the external virtual switch is created. During this process, network binding moves from the physical NIC to the new host virtual NIC (`vEthernet`), and the management IP configuration is carried over.

```powershell
# Create an external SET vSwitch for management traffic
New-VMSwitch -Name "Mgmt" `
    -EnableEmbeddedTeaming $true `
    -NetAdapterName "pNIC-Mgmt-1", "pNIC-Mgmt-2" `
    -AllowManagementOS $true `
    -MinimumBandwidthMode None

# Rename the host vNIC created by New-VMSwitch to match naming convention
Rename-NetAdapter -Name "vEthernet (Mgmt)" -NewName "vEthernet (Mgmt - Host Management)"
```

<img src='.img/2026-04-07-15-06-04.png' width=800>

### 5.4 Create the Interconnect SET vSwitch

```powershell
# Create an external SET vSwitch for cluster heartbeat and live migration traffic
New-VMSwitch -Name "Interconnect" `
    -EnableEmbeddedTeaming $true `
    -NetAdapterName "pNIC-Interconnect-1", "pNIC-Interconnect-2" `
    -AllowManagementOS $true `
    -MinimumBandwidthMode Weight

# Rename the default host vNIC and add a second host vNIC on the same switch
Rename-NetAdapter -Name "vEthernet (Interconnect)" -NewName "vEthernet (InterConnect - Cluster Heartbeat)"
# Keep the Hyper-V management vNIC object name aligned with the renamed host NIC alias
Rename-VMNetworkAdapter -ManagementOS -Name "Interconnect" -NewName "InterConnect - Cluster Heartbeat"
Add-VMNetworkAdapter -ManagementOS -Name "InterConnect - Live Migration" -SwitchName "Interconnect"
```

<img src='.img/2026-04-07-14-56-00.png' width=900>

<img src='.img/2026-04-07-14-57-14.png' width=700>

### 5.5 Create the Compute SET vSwitch

```powershell
# Create an external SET vSwitch for compute guest traffic
New-VMSwitch -Name "Compute" `
    -EnableEmbeddedTeaming $true `
    -NetAdapterName "pNIC-Compute-1", "pNIC-Compute-2" `
    -AllowManagementOS $false `
    -MinimumBandwidthMode None
```

<img src='.img/2026-04-07-14-58-11.png' width=500>

> **Tip**: Set `-AllowManagementOS $false` on the Compute vSwitch to keep host management traffic isolated from guest compute traffic.

### 5.5a Configure Jumbo Frames (Interconnect Only)

Enable MTU 9000 on the Interconnect host vNICs for Live Migration and Storage (CSV) traffic. The Management vNIC remains at the default 1500 MTU.

```powershell
# Enable Jumbo Frames on Interconnect host vNICs (MTU 9000 — Platinum QoS alignment)
Get-NetAdapter -Name "vEthernet (InterConnect - Cluster Heartbeat)", "vEthernet (InterConnect - Live Migration)" | 
  ForEach-Object {
    Set-NetAdapterAdvancedProperty -Name $_.Name -DisplayName "Jumbo Packet" -DisplayValue "9014 Bytes"
  }
```

<img src='.img/2026-04-08-11-58-25.png' width=800>

> **Note**: Ensure UCS vNIC policies and upstream switching also use MTU 9000 end-to-end. VM networks use 1500 or 9000 depending on workload requirements.

### 5.6 Configure IP Addresses on Host vNICs

```powershell
# Cluster vNIC — adjust IP per node (HV01=.11, HV02=.12, HV03=.13)
New-NetIPAddress -InterfaceAlias "vEthernet (InterConnect - Cluster Heartbeat)" `
    -IPAddress "10.10.10.11" `
    -PrefixLength 24

# Live Migration vNIC — adjust IP per node (HV01=.21, HV02=.22, HV03=.23)
New-NetIPAddress -InterfaceAlias "vEthernet (InterConnect - Live Migration)" `
    -IPAddress "10.10.20.21" `
    -PrefixLength 24
```

### 5.7 Configure SET Team Settings

```powershell
# Set load balancing algorithm (HyperVPort is the default and recommended for UCS)
Set-VMSwitchTeam -Name "Mgmt" -LoadBalancingAlgorithm HyperVPort
Set-VMSwitchTeam -Name "Interconnect" -LoadBalancingAlgorithm HyperVPort
Set-VMSwitchTeam -Name "Compute" -LoadBalancingAlgorithm HyperVPort
```

### 5.8 Configure QoS Policies (Recommended)

Weight-based QoS aligns with the UCS Platinum / Gold / Silver traffic model:

| Traffic | UCS QoS Tier | MTU |
|---|---|---|
| Live Migration | Platinum | 9000 |
| Storage (SMB/iSCSI) | Platinum | 9000 |
| VM Traffic | Gold | 1500 or 9000 |
| Management | Silver | 1500 |

```powershell
# Assign bandwidth weights to Interconnect host vNICs
Set-VMNetworkAdapter -ManagementOS -Name "InterConnect - Live Migration" -MinimumBandwidthWeight 50
Set-VMNetworkAdapter -ManagementOS -Name "InterConnect - Cluster Heartbeat" -MinimumBandwidthWeight 10
```

<img src='.img/2026-04-07-15-15-41.png' width=800>  

Rationale:

- Live Migration benefits from burst throughput — weight 50 gives priority when contention exists
- Cluster heartbeat traffic requires low latency but minimal bandwidth — weight 10 is sufficient; the 10 weight guarantees ~16.7% (10 / (50 + 10)) of the congested egress bandwidth from the InterConnect vSwitch

### 5.9 NIC Features and Tuning (Physical Host)

> **Note**: The following settings apply to **physical hosts** only. In a nested lab, virtual NICs do not expose hardware queue or offload properties — these commands will be silently ignored via `-ErrorAction SilentlyContinue`.

#### 5.9a VMQ, VMMQ, and RSS

| Setting | Value | Cmdlet / Property |
|---|---|---|
| VMQ | Enabled | `Set-NetAdapterVmq -Enabled $true` |
| VMMQ | Enabled | `Set-NetAdapterAdvancedProperty` — Virtual Machine Multi-Queue |
| RSS | Enabled | `Enable-NetAdapterRss` |
| Accelerated Receive Flow Steering | Enabled | `Set-NetAdapterAdvancedProperty` |
| Interrupt Scaling | Enabled | `Set-NetAdapterAdvancedProperty` |

**Why these settings matter:**

- **VMQ** assigns dedicated hardware queues per VM, offloading traffic classification from the host CPU to the NIC. This is required for SET hardware offload and reduces context switching.
- **VMMQ** extends VMQ by spreading a single VM's traffic across multiple queues and processors, preventing a single core from becoming a bottleneck on high-throughput workloads.
- **RSS** distributes incoming network traffic across multiple CPU cores using hash-based flow steering, preventing receive-side CPU saturation on busy adapters.
- **Accelerated Receive Flow Steering** dynamically steers flows to the optimal CPU, reducing inter-core traffic and improving cache locality.
- **Interrupt Scaling** distributes NIC interrupts across processors proportionally to load, avoiding hot-spotting on a single core.

```powershell
# Enable VMQ on all physical adapters (required for SET hardware offload)
Get-NetAdapter -Name "pNIC-*" | Set-NetAdapterVmq -Enabled $true

# Enable VMMQ (Virtual Machine Multi-Queue) if supported
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Virtual Machine Multi-Queue" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
}

# Enable RSS (Receive Side Scaling)
Get-NetAdapter -Name "pNIC-*" | Enable-NetAdapterRss

# Enable additional queue features
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Accelerated Receive Flow Steering" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Interrupt Scaling" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
}
```

<img src='.img/2026-04-08-12-09-18.png' width=700>

#### 5.9b Queue and Ring Buffer Tuning

| Setting | Recommended Value | Cmdlet / Property |
|---|---|---|
| VM Queues | 8–16 | `Set-NetAdapterVmq -MaxProcessors 16` |
| Receive Queue Count | 16 (CPU-aligned) | Advanced Property — Maximum Number of RSS Queues |
| Receive Ring Size | 2048 | Advanced Property — Receive Buffers |
| Transmit Ring Size | 1024 | Advanced Property — Transmit Buffers |
| Completion Ring Size | 128 | Advanced Property — Completion Queue Size |

**Why these settings matter:**

- **VM Queues (8–16)** — Allocates dedicated hardware queues per VM. Capping at 16 processors per queue prevents over-subscribing NIC resources while still parallelizing traffic across cores.
- **Receive Queue Count (16)** — Aligns RSS queues to available logical processors so inbound traffic is distributed evenly. Under-provisioning creates CPU hot spots; over-provisioning wastes NIC queue slots.
- **Receive Ring Size (2048)** — Larger receive buffers absorb traffic bursts (e.g., live migration, CSV sync) without dropping frames. Default values (256–512) are too low for sustained cluster workloads.
- **Transmit Ring Size (1024)** — Provides headroom for bursty outbound traffic. Prevents transmit stalls when multiple VMs generate concurrent egress flows.
- **Completion Ring Size (128)** — Ensures the NIC can signal completed I/O operations without backpressure. Undersized completion queues introduce latency spikes under load.

```powershell
# Tune queue and ring buffer settings (values are adapter-specific — adjust to match hardware)
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    # VM Queues target: 8–16 (cap at 16 processors per queue)
    Set-NetAdapterVmq -Name $_.Name -Enabled $true -MaxProcessors 16 -ErrorAction SilentlyContinue

    # Receive Queue Count target: 16 (or CPU-aligned)
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Maximum Number of RSS Queues" -DisplayValue "16" -ErrorAction SilentlyContinue

    # Receive Ring Size target: 2048
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Receive Buffers" -DisplayValue "2048" -ErrorAction SilentlyContinue

    # Transmit Ring Size target: 1024
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Transmit Buffers" -DisplayValue "1024" -ErrorAction SilentlyContinue

    # Completion Ring Size target: 128
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Completion Queue Size" -DisplayValue "128" -ErrorAction SilentlyContinue
}
```

<img src='.img/2026-04-08-12-05-30.png' width=700>

#### 5.9c Offload Settings

| Setting | Value | Cmdlet / Property |
|---|---|---|
| Checksum Offload (TCP/UDP, IPv4/IPv6) | RxTxEnabled | `Set-NetAdapterChecksumOffload` |
| Large Send Offload (LSO) | Enabled | `Enable-NetAdapterLso` |
| Large Receive Offload (LRO) | Disabled | Advanced Property — Large Receive Offload |

**Why these settings matter:**

- **Checksum Offload (RxTxEnabled)** — Moves TCP/UDP checksum computation from the host CPU to the NIC hardware for both transmit and receive paths. Frees CPU cycles for VM workloads and reduces per-packet processing latency.
- **LSO (Enabled)** — Allows the host to hand large data buffers to the NIC, which segments them into MTU-sized frames in hardware. Dramatically reduces CPU overhead for bulk transfers such as live migration and CSV replication.
- **LRO (Disabled)** — LRO coalesces multiple received packets into larger buffers before passing them up the stack. While beneficial for bare-metal workloads, LRO interferes with the Hyper-V virtual switch forwarding path and can cause packet corruption or dropped frames. Microsoft explicitly recommends disabling LRO on Hyper-V hosts.

```powershell
# Enable checksum offloads (Tx + Rx)
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    Set-NetAdapterChecksumOffload -Name $_.Name `
        -TcpIPv4 RxTxEnabled -UdpIPv4 RxTxEnabled `
        -TcpIPv6 RxTxEnabled -UdpIPv6 RxTxEnabled
}

# Enable Large Send Offload (LSO)
Get-NetAdapter -Name "pNIC-*" | Enable-NetAdapterLso

# Disable Large Receive Offload (LRO — causes issues with Hyper-V vSwitch)
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Large Receive Offload (IPv4)" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Large Receive Offload (IPv6)" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
}
```

<img src='.img/2026-04-08-12-06-04.png' width=700>

#### 5.9d Interrupt Mode and Coalescing

| Setting | Value | Cmdlet / Property |
|---|---|---|
| Interrupt Moderation | Adaptive | Advanced Property — Interrupt Moderation |

**Why this setting matters:**

- **Adaptive Interrupt Moderation** dynamically adjusts the interrupt coalescing rate based on current traffic volume. Under light load, interrupts fire promptly to keep latency low (important for cluster heartbeat). Under heavy load, the NIC batches interrupts to reduce CPU overhead (important for live migration and CSV throughput). A static setting would force a trade-off between latency and CPU efficiency; Adaptive gives the best of both.

```powershell
# Set interrupt moderation to Adaptive (MSI-X is typically configured at firmware level)
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    Set-NetAdapterAdvancedProperty -Name $_.Name `
        -DisplayName "Interrupt Moderation" -DisplayValue "Adaptive" -ErrorAction SilentlyContinue
}
```

<img src='.img/2026-04-08-12-07-02.png' width=800>

> **Note**: MSI-X interrupt mode is typically configured at the driver or firmware level (e.g., UCS adapter policy). Verify via `Get-NetAdapterHardwareInfo`.

#### 5.9e RSS Configuration

| Setting | Value | Cmdlet / Property |
|---|---|---|
| RSS | Enabled | `Set-NetAdapterRss -Enabled $true` |
| RSS Profile | Closest | `Set-NetAdapterRss -Profile Closest` |

**Why these settings matter:**

- **RSS Enabled** — Receive Side Scaling distributes inbound traffic across multiple processors using a per-flow hash. Without RSS, all receive processing lands on a single core, creating a throughput ceiling on high-traffic adapters.
- **Profile Closest** — Restricts RSS queue-to-processor assignments to the NUMA node closest to the NIC's PCIe slot. This minimizes cross-NUMA memory access, reducing latency and improving cache hit rates. Alternative profiles (`NUMAScaling`, `Conservative`) spread across remote NUMA nodes, which adds memory access penalty on multi-socket servers.

```powershell
# Enable RSS and set a NUMA-aware profile for optimal traffic distribution
Get-NetAdapter -Name "pNIC-*" | ForEach-Object {
    Set-NetAdapterRss -Name $_.Name `
    -Enabled $true `
    -Profile Closest
}
```

<img src='.img/2026-04-08-12-08-14.png' width=800>

#### 5.9f Host vNIC Tuning (InterConnect)

Some physical-adapter tuning cmdlets also apply to host virtual NICs created by `AllowManagementOS`. The matrix below shows which settings carry over:

| Setting | pNIC (`pNIC-*`) | Host vNIC (`vEthernet`) | Notes |
|---|---|---|---|
| RSS | Yes | Yes | Profile and hash settings |
| Checksum Offload | Yes | Yes | Tx + Rx offload |
| LSO | Yes | Yes | Large Send Offload v2 |
| VMQ / VMMQ | Yes | No | Hardware queue — pNIC only |
| Advanced Property | Yes | No | Driver-level tuning — pNIC only |

The following settings are applied to the InterConnect host vNICs:

| Setting | Value | Benefit |
|---|---|---|
| RSS — Enabled, Profile Closest | `Set-NetAdapterRss -Enabled $true -Profile Closest` | Distributes cluster heartbeat and live migration receive traffic across NUMA-local cores, preventing single-core bottlenecks on the host vNIC path |
| Checksum Offload — RxTxEnabled | `Set-NetAdapterChecksumOffload` (all protocols) | Offloads TCP/UDP checksum computation to the virtual path, reducing CPU cost for high-volume CSV and live migration flows |
| LSO — Enabled | `Enable-NetAdapterLso` | Allows large live migration buffers to be segmented efficiently, improving migration throughput and reducing per-packet CPU overhead |

> **Note**: The Management host vNIC (`vEthernet (Mgmt - Host Management)`) inherits default settings and does not require explicit tuning. The Compute vSwitch has no host vNIC (`AllowManagementOS $false`).

```powershell
# Define the InterConnect host vNICs
$interconnectVnics = @(
    "vEthernet (InterConnect - Cluster Heartbeat)",
    "vEthernet (InterConnect - Live Migration)"
)

# Enable RSS with NUMA-aware profile
$interconnectVnics | ForEach-Object {
    Set-NetAdapterRss -Name $_ -Enabled $true -Profile Closest
}

# Enable checksum offloads (Tx + Rx)
$interconnectVnics | ForEach-Object {
    Set-NetAdapterChecksumOffload -Name $_ `
        -TcpIPv4 RxTxEnabled -UdpIPv4 RxTxEnabled `
        -TcpIPv6 RxTxEnabled -UdpIPv6 RxTxEnabled
}

# Enable Large Send Offload
$interconnectVnics | ForEach-Object {
    Enable-NetAdapterLso -Name $_
}
```

<img src='.img/2026-04-08-12-08-50.png' width=700>

### 5.10 RDMA Guidance

Keep RDMA **disabled** unless explicitly deploying SMB Direct. Enabling RDMA requires full DCB/PFC/QoS configuration end-to-end across the host, switch fabric, and storage target.

### 5.11 Live Migration Guidance

Control live migration concurrency rather than capping bandwidth. Bandwidth caps should only be introduced if storage latency increases or VM traffic is impacted during migrations.

```powershell
# Limit concurrent migrations (already set in Phase 2 step 4.3)
Set-VMHost -MaximumVirtualMachineMigrations 2
```

> **Tip**: CDP and LLDP settings (for fabric visibility) are configured on the UCS side via adapter and network control policies — they are not host-level PowerShell settings.

### 5.12 Verify SET Configuration

```powershell
# Verify SET switches and bandwidth mode
Get-VMSwitch | Select-Object Name, SwitchType, EmbeddedTeamingEnabled, BandwidthReservationMode |
    Format-Table -AutoSize

# Verify team members
Get-VMSwitch | ForEach-Object {
    Write-Host "`n=== $($_.Name) ===" -ForegroundColor Cyan
    Get-VMSwitchTeam -Name $_.Name | Select-Object -ExpandProperty NetAdapterInterfaceDescription
}

# Verify host vNIC QoS weights
Get-VMNetworkAdapter -ManagementOS | Select-Object Name, SwitchName, MinimumBandwidthWeight |
    Format-Table -AutoSize

# Verify Jumbo Frames on Interconnect vNICs
Get-NetAdapterAdvancedProperty -Name "vEthernet (InterConnect - Cluster Heartbeat)", "vEthernet (InterConnect - Live Migration)" `
    -DisplayName "Jumbo Packet"

# Verify VMQ status (physical hosts)
Get-NetAdapterVmq -Name "pNIC-*" -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, BaseProcessorNumber, MaxProcessors | Format-Table -AutoSize

# Verify RSS state and profile configuration (physical hosts)
Get-NetAdapterRss -Name "pNIC-*" -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, Profile, TcpIPv4HashEnabled, UdpIPv4HashEnabled, TcpIPv6HashEnabled, UdpIPv6HashEnabled |
    Format-Table -AutoSize

# Verify checksum offload configuration/capabilities (physical hosts)
Get-NetAdapterChecksumOffload -Name "pNIC-*" -ErrorAction SilentlyContinue |
    Format-List Name, ChecksumOffloadHardwareCapabilities

# Verify RSS on InterConnect host vNICs
Get-NetAdapterRss -Name "vEthernet (InterConnect - Cluster Heartbeat)", "vEthernet (InterConnect - Live Migration)" |
    Select-Object Name, Enabled, Profile | Format-Table -AutoSize

# Verify checksum offload on InterConnect host vNICs
Get-NetAdapterChecksumOffload -Name "vEthernet (InterConnect - Cluster Heartbeat)", "vEthernet (InterConnect - Live Migration)" |
    Select-Object Name, TcpIPv4, UdpIPv4, TcpIPv6, UdpIPv6 | Format-Table -AutoSize

# Verify LSO on InterConnect host vNICs
Get-NetAdapterLso -Name "vEthernet (InterConnect - Cluster Heartbeat)", "vEthernet (InterConnect - Live Migration)" |
    Select-Object Name, V2IPv4Enabled, V2IPv6Enabled | Format-Table -AutoSize

# Verify connectivity between nodes
Test-NetConnection -ComputerName "192.168.148.52" -InformationLevel Detailed
Test-NetConnection -ComputerName "10.10.10.12" -InformationLevel Detailed
Test-NetConnection -ComputerName "10.10.20.22" -InformationLevel Detailed
```

---

## 6. Phase 4 — Storage Configuration

### 6.1 Prepare Shared Storage

For a physical cluster, shared storage is typically provided by an iSCSI target, Fibre Channel SAN, or Storage Spaces Direct (S2D). In this nested lab, you can use either shared VHDX disks or SMB file shares.

> **SMB Alternative**: For an SMB-based approach that uses a file share on the domain controller instead of shared VHDX disks, see the [SMB Shared Storage Setup](smb-shared-storage-setup.md) walkthrough. If using SMB storage, skip the remainder of this section and proceed to [Phase 5 — Active Directory Preparation](#7-phase-5--active-directory-preparation).

#### Initialize Shared Disks (on the first node only)

```powershell
# List raw disks
Get-Disk | Where-Object PartitionStyle -eq 'RAW' |
    Select-Object Number, Size, FriendlyName | Format-Table -AutoSize

# Initialize and format CSV disks
$csvDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -gt 50GB }
foreach ($disk in $csvDisks) {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel "CSV-Disk-$($disk.Number)" -Confirm:$false
}

# Initialize and format witness disk
$witnessDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -le 10GB }
Initialize-Disk -Number $witnessDisk.Number -PartitionStyle GPT
New-Partition -DiskNumber $witnessDisk.Number -UseMaximumSize -AssignDriveLetter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "Witness" -Confirm:$false
```

### 6.2 Bring Disks Online on All Nodes

```powershell
# On each remaining node, bring shared disks online
Get-Disk | Where-Object IsOffline | Set-Disk -IsOffline $false
Get-Disk | Where-Object IsReadOnly | Set-Disk -IsReadOnly $false
```

### 6.3 Configure SAN Policy

```powershell
# Set SAN policy to bring shared disks online automatically
Set-StorageSetting -NewDiskPolicy OnlineAll
```

---

## 7. Phase 5 — Active Directory Preparation

A single-forest Active Directory domain is required for failover clustering.

### 7.1 Promote the Domain Controller

On the dedicated domain controller VM (`TEST-DC01`):

```powershell
# Install AD DS role
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Configure static IP
New-NetIPAddress -InterfaceAlias "Ethernet" `
    -IPAddress "192.168.148.10" `
    -PrefixLength 24

Set-DnsClientServerAddress -InterfaceAlias "Ethernet" `
    -ServerAddresses "127.0.0.1", "192.168.148.10"

# Promote to domain controller
Import-Module ADDSDeployment

$safeModePassword = Read-Host -Prompt "Enter DSRM password" -AsSecureString

Install-ADDSForest `
    -DomainName "test.lab" `
    -InstallDns `
    -SafeModeAdministratorPassword $safeModePassword `
    -Force
```

### 7.2 Verify AD Services

```powershell
# After reboot, verify AD DS is running
Get-Service NTDS, DNS | Select-Object Name, Status
Get-ADDomain | Select-Object DnsRoot, Forest, DomainMode
```

### 7.3 Join Cluster Nodes to the Domain

On **each cluster node**:

```powershell
# Point DNS to domain controller
Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex `
    -ServerAddresses "192.168.148.10"
}

# Join the domain
$credential = Get-Credential -Message "Enter domain admin credentials (Administrator@test.lab)"
Add-Computer -DomainName "test.lab" -Credential $credential -Restart
```

### 7.4 Create a Cluster Service Account (Optional)

On the domain controller:

```powershell
# Create a dedicated service account for the cluster
New-ADUser -Name "svc-cluster" `
    -SamAccountName "svc-cluster" `
    -UserPrincipalName "svc-cluster@test.lab" `
    -AccountPassword (ConvertTo-SecureString "ClusterP@ss2025!" -AsPlainText -Force) `
    -Enabled $true `
    -PasswordNeverExpires $true

# Add to Domain Admins for lab simplicity (tighten for production)
Add-ADGroupMember -Identity "Domain Admins" -Members "svc-cluster"
```

---

## 8. Phase 6 — Failover Clustering

### 8.1 Install the Failover Clustering Feature

On **each cluster node**:

```powershell
Install-WindowsFeature -Name Failover-Clustering `
    -IncludeManagementTools `
    -Restart
```

### 8.2 Validate the Cluster Configuration

Run from **any one node** (validation tests all specified nodes):

```powershell
Test-Cluster -Node "HV01", "HV02", "HV03" -Include "Storage", "Inventory", "Network", "System Configuration"
```

Review the validation report carefully. Address any warnings or errors before proceeding. The report is saved to `C:\Windows\Cluster\Reports` by default.

### 8.3 Create the Failover Cluster

```powershell
New-Cluster -Name "HV-Cluster" `
    -Node "HV01", "HV02", "HV03" `
    -StaticAddress "192.168.148.50" `
    -NoStorage
```

> **Note**: Use `-NoStorage` to create the cluster without automatically adding eligible disks. Storage is added explicitly in the next phase.

### 8.4 Verify Cluster Formation

```powershell
Get-Cluster | Select-Object Name, Domain
Get-ClusterNode | Select-Object Name, State, DynamicWeight
Get-ClusterNetwork | Select-Object Name, Role, Address | Format-Table -AutoSize
```

### 8.5 Configure Cluster Networks

After cluster creation, rename and configure the cluster networks for clarity:

```powershell
# Rename cluster networks
(Get-ClusterNetwork | Where-Object Address -eq "192.168.148.0").Name = "Management"
(Get-ClusterNetwork | Where-Object Address -eq "10.10.10.0").Name = "Cluster"
(Get-ClusterNetwork | Where-Object Address -eq "10.10.20.0").Name = "LiveMigration"

# Set network roles
# 0 = Not used by cluster, 1 = Cluster only, 3 = Cluster and client
(Get-ClusterNetwork "Management").Role = 3
(Get-ClusterNetwork "Cluster").Role = 1
(Get-ClusterNetwork "LiveMigration").Role = 1
```

---

## 9. Phase 7 — Cluster Shared Volumes

### 9.1 Add Disks to the Cluster

```powershell
# Add all available shared disks to the cluster
Get-ClusterAvailableDisk | Add-ClusterDisk
```

### 9.2 Convert Data Disks to CSV

```powershell
# List cluster disks
Get-ClusterResource | Where-Object ResourceType -eq "Physical Disk" |
    Select-Object Name, State, OwnerGroup | Format-Table -AutoSize

# Convert the two data disks to Cluster Shared Volumes
Add-ClusterSharedVolume -Name "Cluster Disk 1"
Add-ClusterSharedVolume -Name "Cluster Disk 2"
```

CSV volumes are mounted at `C:\ClusterStorage\Volume1` and `C:\ClusterStorage\Volume2` on all nodes simultaneously.

### 9.3 Configure the Witness Disk

```powershell
# Set disk witness quorum
Set-ClusterQuorum -DiskWitness "Cluster Disk 3"

# Verify quorum configuration
Get-ClusterQuorum | Select-Object Cluster, QuorumResource, QuorumType
```

### 9.4 Verify CSV Health

```powershell
Get-ClusterSharedVolume | Select-Object Name, State, OwnerNode |
    Format-Table -AutoSize

# Verify CSV paths are accessible on all nodes
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Test-Path "C:\ClusterStorage\Volume1"
}
```

### 9.5 Update Default Hyper-V Paths to CSV

After CSV is online, point the default VM and VHDX paths to the shared volume on each cluster node:

```powershell
Set-VMHost -VirtualMachinePath "C:\ClusterStorage\Volume1" `
           -VirtualHardDiskPath "C:\ClusterStorage\Volume1"
```

---

## 10. Phase 8 — Configure Live Migration

### 10.1 Enable Live Migration

```powershell
# Enable live migration on all cluster nodes
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Enable-VMMigration
}
```

### 10.2 Configure Live Migration Networks

```powershell
# Restrict live migration to the dedicated live migration network
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    # Set migration to use specific subnet
    Set-VMHost -VirtualMachineMigrationPerformanceOption SMB

    # Add the live migration network
    Add-VMMigrationNetwork -Subnet "10.10.20.0/24" -Priority 1

    # Remove management network from migration (if present)
    $mgmtNet = Get-VMMigrationNetwork | Where-Object Subnet -like "192.168.148.*"
    if ($mgmtNet) {
        Remove-VMMigrationNetwork -Subnet $mgmtNet.Subnet
    }
}
```

### 10.3 Configure Live Migration Authentication

```powershell
# Configure Kerberos authentication for live migration (recommended)
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos
}
```

For Kerberos live migration, configure constrained delegation on each cluster node's computer account in Active Directory:

```powershell
# Run on the domain controller — configure delegation for each node pair
$nodes = "HV01$", "HV02$", "HV03$"
foreach ($source in $nodes) {
    foreach ($target in $nodes) {
        if ($source -ne $target) {
            $targetFqdn = ($target -replace '\$$', '') + ".test.lab"
            Set-ADComputer -Identity $source -Add @{
                'msDS-AllowedToDelegateTo' = @(
                    "Microsoft Virtual System Migration Service/$targetFqdn",
                    "cifs/$targetFqdn"
                )
            }
        }
    }
}
```

### 10.4 Test Live Migration

```powershell
# Create a test VM and migrate it
New-VM -Name "TestVM" -MemoryStartupBytes 512MB -NewVHDPath "C:\ClusterStorage\Volume1\TestVM\TestVM.vhdx" -NewVHDSizeBytes 20GB -Generation 2

# Add to cluster
Add-ClusterVirtualMachineRole -VMName "TestVM"

# Perform live migration
Move-ClusterVirtualMachineRole -Name "TestVM" -Node "HV02" -MigrationType Live
```

---

## 11. Phase 9 — Validation and Testing

### 11.1 Full Cluster Validation

```powershell
# Run full validation suite
Test-Cluster -Node "HV01", "HV02", "HV03"
```

### 11.2 Verify Cluster Health

```powershell
# Cluster overview
Get-Cluster | Format-List *

# Node status
Get-ClusterNode | Format-Table Name, State, DynamicWeight -AutoSize

# Network status
Get-ClusterNetwork | Format-Table Name, State, Role -AutoSize

# CSV status
Get-ClusterSharedVolume | Format-Table Name, State, OwnerNode -AutoSize

# Quorum status
Get-ClusterQuorum
```

### 11.3 Test Failover

```powershell
# Simulate node failure by stopping cluster service
Stop-ClusterNode -Name "HV01"

# Verify VMs migrated
Get-ClusterGroup | Format-Table Name, State, OwnerNode -AutoSize

# Bring node back
Start-ClusterNode -Name "HV01"
```

### 11.4 Verify SET vSwitch Redundancy

```powershell
# Check SET team status across all nodes
Invoke-Command -ComputerName "HV01", "HV02", "HV03" -ScriptBlock {
    Get-VMSwitch | Where-Object EmbeddedTeamingEnabled | ForEach-Object {
        [PSCustomObject]@{
            Node       = $env:COMPUTERNAME
            Switch     = $_.Name
            TeamStatus = (Get-VMSwitchTeam -Name $_.Name).TeamingMode
            Members    = ((Get-VMSwitchTeam -Name $_.Name).NetAdapterInterfaceDescription -join ', ')
        }
    }
} | Format-Table -AutoSize
```

---

## 12. Appendix — PowerShell Quick Reference

### SET vSwitch Management

```powershell
# List all SET switches
Get-VMSwitch | Where-Object EmbeddedTeamingEnabled | Format-Table Name, SwitchType

# Add a NIC to an existing SET team
Set-VMSwitchTeam -Name "Mgmt" -NetAdapterName "pNIC-Mgmt-1", "pNIC-Mgmt-2", "pNIC-Mgmt-3"

# Remove a NIC from a SET team (specify remaining members)
Set-VMSwitchTeam -Name "Mgmt" -NetAdapterName "pNIC-Mgmt-1", "pNIC-Mgmt-2"

# Change load balancing algorithm
Set-VMSwitchTeam -Name "Mgmt" -LoadBalancingAlgorithm Dynamic

# View team details
Get-VMSwitchTeam | Format-List *
```

### Cluster Quick Commands

```powershell
# Create a highly available VM
New-VM -Name "ProdVM01" -MemoryStartupBytes 4GB `
    -NewVHDPath "C:\ClusterStorage\Volume1\ProdVM01\ProdVM01.vhdx" `
    -NewVHDSizeBytes 100GB -Generation 2
Add-ClusterVirtualMachineRole -VMName "ProdVM01"

# Drain a node for maintenance
Suspend-ClusterNode -Name "HV01" -Drain

# Resume a node
Resume-ClusterNode -Name "HV01"

# Move all roles off a node
Get-ClusterGroup | Where-Object OwnerNode -eq "HV01" |
    Move-ClusterGroup -Node "HV02"
```

### Useful Diagnostic Commands

```powershell
# Cluster log
Get-ClusterLog -Destination "C:\Temp" -TimeSpan 60

# Cluster events
Get-WinEvent -LogName "Microsoft-Windows-FailoverClustering/Operational" -MaxEvents 50

# Network connectivity matrix
$nodes = "HV01", "HV02", "HV03"
foreach ($node in $nodes) {
    foreach ($target in $nodes) {
        if ($node -ne $target) {
            $result = Invoke-Command -ComputerName $node -ScriptBlock {
                Test-NetConnection -ComputerName $using:target -Port 445
            }
            Write-Host "$node -> $target : $($result.TcpTestSucceeded)"
        }
    }
}
```

---

## Related Guides

- [Network ATC Implementation Guide](network-atc-implementation-guide.md) — Simplified networking using Network ATC intent-based configuration
