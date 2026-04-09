<#
.SYNOPSIS
Configures a Hyper-V cluster node and optionally creates a failover cluster.

.DESCRIPTION
Runs locally on each cluster node to apply host baseline settings, create SET virtual
switches, configure host vNIC networking and NIC hardware tuning, and set Hyper-V host
defaults. The script auto-detects the current host by matching $env:COMPUTERNAME against
the $Config block.

When -CreateCluster is specified (run on one node only after all nodes are configured),
the script validates the cluster, creates it with -NoStorage, renames cluster networks,
and configures live migration with Kerberos authentication and a dedicated subnet.

Prerequisites:
  - Windows Server 2025 Datacenter installed on all nodes
  - All nodes domain-joined with DNS pointing to the domain controller
  - Physical or virtual NICs named to match $Config.Switches NIC patterns
  - PowerShell remoting enabled between nodes (for -CreateCluster)

.PARAMETER CreateCluster
Create the failover cluster and configure live migration. Run on one node only
after all nodes have been individually configured.

.PARAMETER SkipReboot
Suppress automatic reboot after installing Hyper-V and Failover Clustering roles.
The script will warn and exit; re-run after a manual reboot.

.CONTEXT
3-node Hyper-V failover cluster HV environment (Windows Server 2025 Datacenter)

.AUTHOR
Greg Tate

.NOTES
Program: Initialize-HyperVClusterNode.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$CreateCluster,

    [Parameter()]
    [switch]$SkipReboot
)

#region CONFIGURATION
# Per-host IP assignments, cluster settings, SET vSwitch definitions, and tuning parameters.
# Edit this block to match your environment before running the script.
$Config = {
    $physicalNicNames = [ordered]@{
        Mgmt         = @('pNIC-Mgmt-1', 'pNIC-Mgmt-2')
        Interconnect = @('pNIC-Interconnect-1', 'pNIC-Interconnect-2')
        Compute      = @('pNIC-Compute-1', 'pNIC-Compute-2')
    }

    $subnetConfig = [ordered]@{
        MgmtSubnet          = '192.168.148.0'
        MgmtPrefixLength    = 24
        ClusterSubnet       = '10.10.10.0'
        ClusterPrefixLength = 24
        LiveMigrationSubnet = '10.10.20.0'
        LiveMigrationPrefixLength = 24
    }

    @{
        # ---- Cluster Settings ----
        ClusterName          = 'HV-Cluster'
        ClusterStaticAddress = '192.168.148.50'
        DomainName           = 'test.lab'
        DnsServer            = '192.168.148.10'

        # ---- Physical NIC Names ----
        PhysicalNicNames = $physicalNicNames

        # ---- Per-Host Configuration ----
        Hosts = [ordered]@{
            'TEST-HV01' = @{
                MgmtIP          = '192.168.148.51'
                ClusterIP       = '10.10.10.11'
                LiveMigrationIP = '10.10.20.21'
            }
            'TEST-HV02' = @{
                MgmtIP          = '192.168.148.52'
                ClusterIP       = '10.10.10.12'
                LiveMigrationIP = '10.10.20.22'
            }
            'TEST-HV03' = @{
                MgmtIP          = '192.168.148.53'
                ClusterIP       = '10.10.10.13'
                LiveMigrationIP = '10.10.20.23'
            }
        }

        # ---- Subnet Configuration ----
        MgmtSubnet                = $subnetConfig.MgmtSubnet
        MgmtPrefixLength          = $subnetConfig.MgmtPrefixLength
        ClusterSubnet             = $subnetConfig.ClusterSubnet
        ClusterPrefixLength       = $subnetConfig.ClusterPrefixLength
        LiveMigrationSubnet       = $subnetConfig.LiveMigrationSubnet
        LiveMigrationPrefixLength = $subnetConfig.LiveMigrationPrefixLength

        # ---- SET Virtual Switch Definitions ----
        Switches = [ordered]@{
            Mgmt         = @{
                NetAdapterName       = $physicalNicNames.Mgmt
                AllowManagementOS    = $true
                MinimumBandwidthMode = 'None'
            }
            Interconnect = @{
                NetAdapterName       = $physicalNicNames.Interconnect
                AllowManagementOS    = $true
                MinimumBandwidthMode = 'Weight'
            }
            Compute      = @{
                NetAdapterName       = $physicalNicNames.Compute
                AllowManagementOS    = $false
                MinimumBandwidthMode = 'None'
            }
        }
        LoadBalancingAlgorithm = 'HyperVPort'

        # ---- Host vNIC Naming ----
        MgmtVNicName          = 'Mgmt - Host Management'
        ClusterVNicName       = 'InterConnect - Cluster Heartbeat'
        LiveMigrationVNicName = 'InterConnect - Live Migration'

        # ---- QoS Bandwidth Weights (Interconnect Switch) ----
        LiveMigrationBandwidthWeight = 50
        ClusterBandwidthWeight       = 10

        # ---- Jumbo Frames (Interconnect Only) ----
        JumboFrameValue = '9014 Bytes'

        # ---- Hyper-V Host Settings ----
        DefaultVMPath                   = 'C:\Hyper-V'
        NumaSpanningEnabled             = $true
        EnableEnhancedSessionMode       = $true
        MaximumVirtualMachineMigrations = 2

        # ---- Live Migration Settings ----
        MigrationPerformanceOption  = 'SMB'
        MigrationAuthenticationType = 'Kerberos'
        MigrationPriority           = 1

        # ---- Cluster Network Names and Roles ----
        # Role: 0 = Not used, 1 = Cluster only, 3 = Cluster and client
        ClusterNetworks = [ordered]@{
            Management    = @{ Subnet = $subnetConfig.MgmtSubnet;          Role = 3 }
            Cluster       = @{ Subnet = $subnetConfig.ClusterSubnet;       Role = 1 }
            LiveMigration = @{ Subnet = $subnetConfig.LiveMigrationSubnet; Role = 1 }
        }

        # ---- NIC Hardware Tuning (Physical Hosts) ----
        PhysicalNicPattern    = 'pNIC-*'
        VmqState              = 'Enabled'
        VmmqState             = 'Enabled'
        RssState              = 'Enabled'
        ArfsState             = 'Enabled'
        InterruptScalingState = 'Enabled'
        ChecksumOffloadState  = 'RxTxEnabled'
        LsoState              = 'Enabled'
        LroIPv4State          = 'Disabled'
        LroIPv6State          = 'Disabled'
        VmqMaxProcessors      = 16
        RssQueues             = '16'
        ReceiveBuffers        = '2048'
        TransmitBuffers       = '1024'
        CompletionQueueSize   = '128'
        RssProfile            = 'Closest'
        InterruptModeration   = 'Adaptive'

        # ---- Host vNIC Tuning (InterConnect) ----
        HostVNicRssState             = 'Enabled'
        HostVNicChecksumOffloadState = 'RxTxEnabled'
        HostVNicLsoState             = 'Enabled'
    }
}
#endregion

$Main = {
    . $Helpers

    # Evaluate configuration and resolve the current host entry.
    $cfg     = & $Config
    $hostCfg = Resolve-HostEntry -Config $cfg

    Write-Host "`n=== Configuring $($hostCfg.Name) ===" -ForegroundColor Cyan

    # Phase 1 — Enable remote management, ICMP, and high-performance power plan.
    Set-HostBaseline

    # Phase 2 — Install Hyper-V and Failover Clustering roles.
    $rebootNeeded = Install-HyperVRole
    if ($rebootNeeded) { return }

    # Phase 2 — Configure Hyper-V host defaults (paths, NUMA, session mode, migration limit).
    Set-HyperVHostSetting -Config $cfg

    # Phase 3 — Create SET virtual switches (Mgmt, Interconnect, Compute).
    New-SetVirtualSwitch -Config $cfg

    # Phase 3 — Rename default host vNICs and add the Live Migration vNIC.
    Set-HostVNic -Config $cfg

    # Phase 3 — Enable Jumbo Frames on Interconnect host vNICs.
    Set-JumboFrame -Config $cfg

    # Phase 3 — Assign per-node IP addresses and DNS on host vNICs.
    Set-HostVNicIpAddress -Config $cfg -HostConfig $hostCfg

    # Phase 3 — Set load balancing algorithm on all SET switches.
    Set-SwitchTeamSetting -Config $cfg

    # Phase 3 — Assign QoS bandwidth weights on Interconnect vNICs.
    Set-QosBandwidthWeight -Config $cfg

    # Phase 3 — Apply NIC hardware tuning (silently skipped in nested Hyper-V environments).
    Set-PhysicalNicTuning -Config $cfg

    # Phase 3 — Apply host vNIC tuning on InterConnect adapters.
    Set-HostVNicTuning -Config $cfg

    # Phase 6 + 8 — Create the failover cluster and configure live migration.
    if ($CreateCluster) {
        $liveMigrationSubnetCidr = Get-SubnetCidr -SubnetAddress $cfg.LiveMigrationSubnet -PrefixLength $cfg.LiveMigrationPrefixLength

        New-HVCluster -Config $cfg
        Set-ClusterNetworkLabel -Config $cfg
        Enable-HVLiveMigration -Config $cfg -MigrationSubnet $liveMigrationSubnetCidr
    }

    Write-Host "`nConfiguration complete for $($hostCfg.Name).`n" -ForegroundColor Green

    # Generate a post-configuration report from actual system state and export to CSV.
    $report     = Get-ConfigurationReport -Config $cfg
    $reportPath = Export-ConfigurationReport -Report $report
    Write-Host "  Configuration report exported to $reportPath" -ForegroundColor Green

    # Output report objects to the pipeline for optional piping (Format-Table, etc.).
    $report
}

$Helpers = {

    #region HOST DETECTION
    # Resolve the current computer name to a host entry in the configuration block.

    function Resolve-HostEntry {
        # Match the current computer name to a configured host and return its IP assignments.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $hostname = $env:COMPUTERNAME

        # Throw if the current host is not defined in the configuration.
        if (-not $Config.Hosts.Contains($hostname)) {
            $validNames = ($Config.Hosts.Keys -join ', ')
            throw "Host '$hostname' not found in configuration. Valid hosts: $validNames"
        }

        $entry = $Config.Hosts[$hostname]

        [PSCustomObject]@{
            Name            = $hostname
            MgmtIP          = $entry.MgmtIP
            ClusterIP       = $entry.ClusterIP
            LiveMigrationIP = $entry.LiveMigrationIP
        }
    }

    #endregion

    #region HOST BASELINE
    # Enable remote management, firewall rules, and power settings.

    function Set-HostBaseline {
        # Enable RDP, PowerShell remoting, ICMP firewall rules, and high-performance power plan.

        # Enable Remote Desktop.
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name 'fDenyTSConnections' -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

        # Enable PowerShell remoting.
        Enable-PSRemoting -Force

        # Allow inbound ICMP echo requests (ping).
        Enable-NetFirewallRule -DisplayName 'File and Printer Sharing (Echo Request - ICMPv4-In)'
        Enable-NetFirewallRule -DisplayName 'File and Printer Sharing (Echo Request - ICMPv6-In)'

        # Set high-performance power plan.
        powercfg /setactive SCHEME_MIN

        Write-Host '  Host baseline configured (RDP, PSRemoting, ICMP, power plan)' -ForegroundColor DarkGray
    }

    function Install-HyperVRole {
        # Install Hyper-V and Failover Clustering roles and return whether a reboot is pending.

        # Validate CPU virtualization prerequisites before attempting role installation.
        # Confirm-HyperVInstallPrerequisite

        $features = Get-WindowsFeature -Name Hyper-V, Failover-Clustering
        $missing  = $features | Where-Object { $_.InstallState -ne 'Installed' }

        # Skip installation if all features are already present.
        if (-not $missing) {
            Write-Host '  Hyper-V and Failover Clustering already installed' -ForegroundColor DarkGray
            return $false
        }

        Write-Host '  Installing Hyper-V and Failover Clustering...' -ForegroundColor Yellow

        try {
            $result = Install-WindowsFeature -Name Hyper-V, Failover-Clustering -IncludeManagementTools -ErrorAction Stop
        }
        catch {
            $installError = $_.Exception.Message

            # Provide nested-lab specific remediation when Hyper-V reports BIOS virtualization is disabled.
            if ($installError -match 'virtualization support is not enabled in the BIOS') {
                $guidance = @(
                    'Hyper-V/Failover-Clustering installation failed: nested virtualization is not exposed to this guest OS.',
                    'Run these commands on the parent Hyper-V host while this VM is Off:',
                    "  Stop-VM -Name $env:COMPUTERNAME -Force",
                    "  Set-VMMemory -VMName $env:COMPUTERNAME -DynamicMemoryEnabled `$false -StartupBytes 8GB",
                    "  Set-VMProcessor -VMName $env:COMPUTERNAME -ExposeVirtualizationExtensions `$true -CompatibilityForMigrationEnabled `$false",
                    "  Set-VM -Name $env:COMPUTERNAME -AutomaticCheckpointsEnabled `$false",
                    "  Get-VMProcessor -VMName $env:COMPUTERNAME | Select-Object ExposeVirtualizationExtensions, CompatibilityForMigrationEnabled",
                    "  Start-VM -Name $env:COMPUTERNAME",
                    'Then run this script again inside the VM.'
                ) -join [Environment]::NewLine

                throw $guidance
            }

            throw "Hyper-V/Failover-Clustering installation failed. $installError"
        }

        # Stop execution when installation reports a failed state.
        if (-not $result.Success) {
            $failedFeatures = @($result.FeatureResult | Where-Object { -not $_.Success } | ForEach-Object { $_.Name })
            if ($failedFeatures.Count -eq 0) {
                $failedFeatures = @('UnknownFeature')
            }

            $failedList = $failedFeatures -join ', '
            throw "Feature installation did not complete successfully. Failed feature(s): $failedList"
        }

        # Handle reboot requirement after feature installation.
        if ($result.RestartNeeded -eq 'Yes') {
            if ($SkipReboot) {
                Write-Warning 'A reboot is required to complete feature installation. Re-run this script after rebooting.'
                return $true
            }

            Write-Host '  Restarting to complete feature installation. Re-run this script after reboot.' -ForegroundColor Yellow
            Restart-Computer -Force
            return $true
        }

        Write-Host '  Hyper-V and Failover Clustering installed successfully' -ForegroundColor DarkGray
        return $false
    }

    function Confirm-HyperVInstallPrerequisite {
        # Ensure CPU virtualization and SLAT prerequisites are available before installing Hyper-V.

        $processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

        $failedChecks = @()

        # Verify hardware virtualization extensions are available in the current OS context.
        if (-not $processor.VMMonitorModeExtensions) {
            $failedChecks += 'VMMonitorModeExtensions'
        }

        # Verify SLAT support required by Hyper-V.
        if (-not $processor.SecondLevelAddressTranslationExtensions) {
            $failedChecks += 'SecondLevelAddressTranslationExtensions'
        }

        # Warn if VirtualizationFirmwareEnabled is False (expected in nested VMs — not a blocking check).
        if (-not $processor.VirtualizationFirmwareEnabled) {
            Write-Warning ('VirtualizationFirmwareEnabled is False. ' +
                'This is normal inside nested VMs and does not prevent Hyper-V installation.')
        }

        # Exit early with actionable guidance when prerequisites are missing.
        if ($failedChecks.Count -gt 0) {
            $failedList = $failedChecks -join ', '
            $guidance = @(
                'Hyper-V prerequisites are missing in this OS context.',
                "Failed check(s): $failedList",
                'If this server is a nested VM, run these commands on the parent Hyper-V host (while VM is Off):',
                "  Stop-VM -Name $env:COMPUTERNAME -Force",
                "  Set-VMProcessor -VMName $env:COMPUTERNAME -ExposeVirtualizationExtensions `$true",
                "  Start-VM -Name $env:COMPUTERNAME",
                'Then run this script again inside the VM.'
            ) -join [Environment]::NewLine

            throw $guidance
        }
    }

    function Set-HyperVHostSetting {
        # Configure Hyper-V host defaults for VM paths, NUMA spanning, session mode, and migration limit.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        # Set default VM and VHD storage paths.
        Set-VMHost -VirtualMachinePath $Config.DefaultVMPath `
                   -VirtualHardDiskPath $Config.DefaultVMPath

        # Enable NUMA spanning for cross-boundary memory allocation.
        Set-VMHost -NumaSpanningEnabled $Config.NumaSpanningEnabled

        # Enable enhanced session mode for improved VM console integration.
        Set-VMHost -EnableEnhancedSessionMode $Config.EnableEnhancedSessionMode

        # Set maximum concurrent live migrations.
        Set-VMHost -MaximumVirtualMachineMigrations $Config.MaximumVirtualMachineMigrations

        Write-Host "  Hyper-V host defaults configured (VM path: $($Config.DefaultVMPath))" -ForegroundColor DarkGray
    }

    #endregion

    #region SET VIRTUAL SWITCH NETWORKING
    # Create SET switches, configure host vNICs, IP addressing, QoS, and jumbo frames.

    function New-SetVirtualSwitch {
        # Create SET virtual switches for Mgmt, Interconnect, and Compute traffic.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        foreach ($name in $Config.Switches.Keys) {
            $sw = $Config.Switches[$name]

            # Skip if the switch already exists.
            if (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue) {
                Write-Host "  SET vSwitch '$name' already exists - skipping" -ForegroundColor DarkGray
                continue
            }

            # Warn that RDP will drop briefly during Mgmt switch creation.
            if ($name -eq 'Mgmt') {
                Write-Host "  Creating '$name' SET vSwitch (RDP will drop briefly)..." -ForegroundColor Yellow
            }
            else {
                Write-Host "  Creating '$name' SET vSwitch..." -ForegroundColor Yellow
            }

            New-VMSwitch -Name $name `
                -EnableEmbeddedTeaming $true `
                -NetAdapterName $sw.NetAdapterName `
                -AllowManagementOS $sw.AllowManagementOS `
                -MinimumBandwidthMode $sw.MinimumBandwidthMode | Out-Null
        }

        Write-Host '  SET virtual switches configured' -ForegroundColor DarkGray
    }

    function Set-HostVNic {
        # Rename default host vNICs and add the Live Migration vNIC on the Interconnect switch.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $mgmtTarget    = "vEthernet ($($Config.MgmtVNicName))"
        $clusterTarget = "vEthernet ($($Config.ClusterVNicName))"

        # Rename the Mgmt host vNIC if it still has the default name.
        if (Get-NetAdapter -Name 'vEthernet (Mgmt)' -ErrorAction SilentlyContinue) {
            Rename-NetAdapter -Name 'vEthernet (Mgmt)' -NewName $mgmtTarget
        }

        # Rename the Interconnect host vNIC (OS adapter and Hyper-V management adapter).
        if (Get-NetAdapter -Name 'vEthernet (Interconnect)' -ErrorAction SilentlyContinue) {
            Rename-NetAdapter -Name 'vEthernet (Interconnect)' -NewName $clusterTarget
            Rename-VMNetworkAdapter -ManagementOS -Name 'Interconnect' -NewName $Config.ClusterVNicName
        }

        # Add the Live Migration host vNIC if it does not already exist.
        if (-not (Get-VMNetworkAdapter -ManagementOS -Name $Config.LiveMigrationVNicName -ErrorAction SilentlyContinue)) {
            Add-VMNetworkAdapter -ManagementOS -Name $Config.LiveMigrationVNicName -SwitchName 'Interconnect'
        }

        Write-Host '  Host vNICs configured (Mgmt, Cluster Heartbeat, Live Migration)' -ForegroundColor DarkGray
    }

    function Set-JumboFrame {
        # Enable Jumbo Frames (MTU 9014) on Interconnect host vNICs.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $vnics = @(
            "vEthernet ($($Config.ClusterVNicName))",
            "vEthernet ($($Config.LiveMigrationVNicName))"
        )

        # Apply jumbo frame setting to each Interconnect host vNIC.
        foreach ($vnic in $vnics) {
            Set-NetAdapterAdvancedProperty -Name $vnic `
                -DisplayName 'Jumbo Packet' `
                -DisplayValue $Config.JumboFrameValue `
                -ErrorAction SilentlyContinue
        }

        Write-Host "  Jumbo Frames set to $($Config.JumboFrameValue) on Interconnect vNICs" -ForegroundColor DarkGray
    }

    function Set-HostVNicIpAddress {
        # Assign per-node IP addresses to Cluster and Live Migration vNICs and set DNS.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config,

            [Parameter(Mandatory)]
            [PSCustomObject]$HostConfig
        )

        $clusterAlias = "vEthernet ($($Config.ClusterVNicName))"
        $lmAlias      = "vEthernet ($($Config.LiveMigrationVNicName))"
        $mgmtAlias    = "vEthernet ($($Config.MgmtVNicName))"

        # Assign Cluster Heartbeat IP if not already configured.
        $existingCluster = Get-NetIPAddress -InterfaceAlias $clusterAlias -IPAddress $HostConfig.ClusterIP -ErrorAction SilentlyContinue
        if (-not $existingCluster) {
            New-NetIPAddress -InterfaceAlias $clusterAlias `
                -IPAddress $HostConfig.ClusterIP `
                -PrefixLength $Config.ClusterPrefixLength | Out-Null
        }

        # Assign Live Migration IP if not already configured.
        $existingLM = Get-NetIPAddress -InterfaceAlias $lmAlias -IPAddress $HostConfig.LiveMigrationIP -ErrorAction SilentlyContinue
        if (-not $existingLM) {
            New-NetIPAddress -InterfaceAlias $lmAlias `
                -IPAddress $HostConfig.LiveMigrationIP `
                -PrefixLength $Config.LiveMigrationPrefixLength | Out-Null
        }

        # Set DNS to the domain controller on the Management vNIC.
        Set-DnsClientServerAddress -InterfaceAlias $mgmtAlias `
            -ServerAddresses $Config.DnsServer

        Write-Host "  IP addresses assigned (Cluster: $($HostConfig.ClusterIP), LM: $($HostConfig.LiveMigrationIP))" -ForegroundColor DarkGray
    }

    function Set-SwitchTeamSetting {
        # Set the load balancing algorithm on all SET virtual switches.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        foreach ($name in $Config.Switches.Keys) {
            Set-VMSwitchTeam -Name $name -LoadBalancingAlgorithm $Config.LoadBalancingAlgorithm
        }

        Write-Host "  SET load balancing set to $($Config.LoadBalancingAlgorithm)" -ForegroundColor DarkGray
    }

    function Set-QosBandwidthWeight {
        # Assign QoS minimum bandwidth weights to Interconnect host vNICs.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        # Weight Live Migration for burst throughput priority under contention.
        Set-VMNetworkAdapter -ManagementOS `
            -Name $Config.LiveMigrationVNicName `
            -MinimumBandwidthWeight $Config.LiveMigrationBandwidthWeight

        # Weight Cluster Heartbeat for low-latency guaranteed bandwidth.
        Set-VMNetworkAdapter -ManagementOS `
            -Name $Config.ClusterVNicName `
            -MinimumBandwidthWeight $Config.ClusterBandwidthWeight

        Write-Host "  QoS weights assigned (LM: $($Config.LiveMigrationBandwidthWeight), Cluster: $($Config.ClusterBandwidthWeight))" -ForegroundColor DarkGray
    }

    #endregion

    #region NIC TUNING
    # Physical NIC hardware tuning and host vNIC performance settings.

    function ConvertTo-EnabledStateBoolean {
        # Convert an Enabled/Disabled state string to a boolean.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateSet('Enabled', 'Disabled')]
            [string]$State
        )

        $State -eq 'Enabled'
    }

    function Set-PhysicalNicTuning {
        # Apply VMQ, RSS, offload, queue, and interrupt tuning to physical NICs.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $adapters = Get-NetAdapter -Name $Config.PhysicalNicPattern -ErrorAction SilentlyContinue

        # Exit silently when no physical NICs match (nested Hyper-V environment).
        if (-not $adapters) {
            Write-Host '  No physical NICs matching pattern - skipping hardware tuning' -ForegroundColor DarkGray
            return
        }

        $vmqEnabled = ConvertTo-EnabledStateBoolean -State $Config.VmqState
        $rssEnabled = ConvertTo-EnabledStateBoolean -State $Config.RssState

        # Enable VMQ with max processor cap.
        foreach ($a in $adapters) {
            Set-NetAdapterVmq -Name $a.Name -Enabled $vmqEnabled `
                -MaxProcessors $Config.VmqMaxProcessors -ErrorAction SilentlyContinue
        }

        # Enable VMMQ (Virtual Machine Multi-Queue).
        foreach ($a in $adapters) {
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Virtual Machine Multi-Queue' -DisplayValue $Config.VmmqState -ErrorAction SilentlyContinue
        }

        # Enable RSS and set NUMA-aware profile.
        foreach ($a in $adapters) {
            Set-NetAdapterRss -Name $a.Name -Enabled $rssEnabled `
                -Profile $Config.RssProfile -ErrorAction SilentlyContinue
        }

        # Enable accelerated receive flow steering and interrupt scaling.
        foreach ($a in $adapters) {
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Accelerated Receive Flow Steering' -DisplayValue $Config.ArfsState -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Interrupt Scaling' -DisplayValue $Config.InterruptScalingState -ErrorAction SilentlyContinue
        }

        # Tune queue counts and ring buffer sizes.
        foreach ($a in $adapters) {
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Maximum Number of RSS Queues' -DisplayValue $Config.RssQueues -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Receive Buffers' -DisplayValue $Config.ReceiveBuffers -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Transmit Buffers' -DisplayValue $Config.TransmitBuffers -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Completion Queue Size' -DisplayValue $Config.CompletionQueueSize -ErrorAction SilentlyContinue
        }

        # Enable checksum offloads (Tx + Rx, IPv4 + IPv6).
        foreach ($a in $adapters) {
            Set-NetAdapterChecksumOffload -Name $a.Name `
                -TcpIPv4 $Config.ChecksumOffloadState -UdpIPv4 $Config.ChecksumOffloadState `
                -TcpIPv6 $Config.ChecksumOffloadState -UdpIPv6 $Config.ChecksumOffloadState -ErrorAction SilentlyContinue
        }

        # Enable Large Send Offload.
        if ($Config.LsoState -eq 'Enabled') {
            foreach ($a in $adapters) {
                Enable-NetAdapterLso -Name $a.Name -ErrorAction SilentlyContinue
            }
        }
        else {
            foreach ($a in $adapters) {
                Disable-NetAdapterLso -Name $a.Name -ErrorAction SilentlyContinue
            }
        }

        # Disable Large Receive Offload (interferes with Hyper-V vSwitch).
        foreach ($a in $adapters) {
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Large Receive Offload (IPv4)' -DisplayValue $Config.LroIPv4State -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Large Receive Offload (IPv6)' -DisplayValue $Config.LroIPv6State -ErrorAction SilentlyContinue
        }

        # Set interrupt moderation to Adaptive.
        foreach ($a in $adapters) {
            Set-NetAdapterAdvancedProperty -Name $a.Name `
                -DisplayName 'Interrupt Moderation' -DisplayValue $Config.InterruptModeration -ErrorAction SilentlyContinue
        }

        Write-Host '  Physical NIC tuning applied (VMQ, RSS, offloads, queues)' -ForegroundColor DarkGray
    }

    function Set-HostVNicTuning {
        # Apply RSS, checksum offload, and LSO tuning to InterConnect host vNICs.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $vnics = @(
            "vEthernet ($($Config.ClusterVNicName))",
            "vEthernet ($($Config.LiveMigrationVNicName))"
        )

        $hostVNicRssEnabled = ConvertTo-EnabledStateBoolean -State $Config.HostVNicRssState

        # Enable RSS with NUMA-aware profile.
        foreach ($vnic in $vnics) {
            Set-NetAdapterRss -Name $vnic -Enabled $hostVNicRssEnabled -Profile $Config.RssProfile
        }

        # Enable checksum offloads (Tx + Rx, IPv4 + IPv6).
        foreach ($vnic in $vnics) {
            Set-NetAdapterChecksumOffload -Name $vnic `
                -TcpIPv4 $Config.HostVNicChecksumOffloadState -UdpIPv4 $Config.HostVNicChecksumOffloadState `
                -TcpIPv6 $Config.HostVNicChecksumOffloadState -UdpIPv6 $Config.HostVNicChecksumOffloadState
        }

        # Enable Large Send Offload.
        if ($Config.HostVNicLsoState -eq 'Enabled') {
            foreach ($vnic in $vnics) {
                Enable-NetAdapterLso -Name $vnic
            }
        }
        else {
            foreach ($vnic in $vnics) {
                Disable-NetAdapterLso -Name $vnic
            }
        }

        Write-Host '  InterConnect host vNIC tuning applied (RSS, checksum, LSO)' -ForegroundColor DarkGray
    }

    #endregion

    #region CLUSTER CREATION AND LIVE MIGRATION
    # Failover cluster creation, network labeling, and live migration configuration.

    function New-HVCluster {
        # Validate nodes and create the failover cluster with no storage.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $nodes = @($Config.Hosts.Keys)

        # Skip if a cluster already exists on this node.
        if (Get-Cluster -ErrorAction SilentlyContinue) {
            Write-Host '  Cluster already exists - skipping creation' -ForegroundColor DarkGray
            return
        }

        Write-Host '  Validating cluster configuration...' -ForegroundColor Yellow
        Test-Cluster -Node $nodes -Include 'Inventory', 'Network', 'System Configuration'
        Write-Host '  Validation report saved to C:\Windows\Cluster\Reports' -ForegroundColor DarkGray

        Write-Host '  Creating failover cluster (no storage)...' -ForegroundColor Yellow
        New-Cluster -Name $Config.ClusterName `
            -Node $nodes `
            -StaticAddress $Config.ClusterStaticAddress `
            -NoStorage

        Write-Host "  Cluster '$($Config.ClusterName)' created at $($Config.ClusterStaticAddress)" -ForegroundColor DarkGray
    }

    function Set-ClusterNetworkLabel {
        # Rename cluster networks by subnet and assign their communication roles.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        foreach ($label in $Config.ClusterNetworks.Keys) {
            $net        = $Config.ClusterNetworks[$label]
            $clusterNet = Get-ClusterNetwork | Where-Object { $_.Address -eq $net.Subnet }

            # Rename and set role if the subnet is found in the cluster.
            if ($clusterNet) {
                $clusterNet.Name = $label
                $clusterNet.Role = $net.Role
            }
            else {
                Write-Warning "Cluster network with subnet $($net.Subnet) not found - skipping '$label'"
            }
        }

        Write-Host '  Cluster networks renamed and roles assigned' -ForegroundColor DarkGray
    }

    function Enable-HVLiveMigration {
        # Enable live migration on all nodes and configure performance, auth, and network settings.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config,

            [Parameter(Mandatory)]
            [string]$MigrationSubnet
        )

        $nodes       = @($Config.Hosts.Keys)
        $perfOption  = $Config.MigrationPerformanceOption
        $authType    = $Config.MigrationAuthenticationType
        $migSubnet   = $MigrationSubnet
        $migPriority = $Config.MigrationPriority
        $mgmtSubnet  = $Config.MgmtSubnet

        # Enable live migration on all cluster nodes.
        Invoke-Command -ComputerName $nodes -ScriptBlock {
            Enable-VMMigration
        }

        # Configure migration performance option and authentication type.
        Invoke-Command -ComputerName $nodes -ScriptBlock {
            Set-VMHost -VirtualMachineMigrationPerformanceOption $using:perfOption
            Set-VMHost -VirtualMachineMigrationAuthenticationType $using:authType
        }

        # Add the dedicated live migration subnet and remove the management subnet.
        Invoke-Command -ComputerName $nodes -ScriptBlock {
            Add-VMMigrationNetwork -Subnet $using:migSubnet -Priority $using:migPriority -ErrorAction SilentlyContinue

            $mgmtNet = Get-VMMigrationNetwork |
                Where-Object { $_.Subnet -like "$($using:mgmtSubnet)*" }

            if ($mgmtNet) {
                Remove-VMMigrationNetwork -Subnet $mgmtNet.Subnet
            }
        }

        Write-Host "  Live migration configured ($perfOption, $authType, subnet $migSubnet)" -ForegroundColor DarkGray
    }

    function Get-SubnetCidr {
        # Build CIDR notation from a subnet address and prefix length.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$SubnetAddress,

            [Parameter(Mandatory)]
            [int]$PrefixLength
        )

        "$SubnetAddress/$PrefixLength"
    }

    #endregion

    #region CONFIGURATION REPORT
    # Query actual system state and export a post-configuration report to CSV.

    function Get-ConfigurationReport {
        # Collect actual system state across all configuration areas and return uniform PSCustomObjects.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [hashtable]$Config
        )

        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

        # Helper to add a row with consistent schema.
        $addRow = {
            param([string]$Category, [string]$Item, [string]$Property, [string]$Value)
            $rows.Add([PSCustomObject]@{
                Category = $Category
                Item     = $Item
                Property = $Property
                Value    = $Value
            })
        }

        # ---- Host Identity ----
        & $addRow 'Host Identity' $env:COMPUTERNAME 'ComputerName' $env:COMPUTERNAME
        & $addRow 'Host Identity' $env:COMPUTERNAME 'Domain'       $Config.DomainName
        & $addRow 'Host Identity' $env:COMPUTERNAME 'DnsServer'    $Config.DnsServer

        # ---- SET Virtual Switches ----
        $switches = Get-VMSwitch -ErrorAction SilentlyContinue
        foreach ($sw in $switches) {
            $teamMembers = ($sw.NetAdapterInterfaceDescriptions | Sort-Object) -join '; '
            & $addRow 'SET Virtual Switch' $sw.Name 'SwitchType'          $sw.SwitchType
            & $addRow 'SET Virtual Switch' $sw.Name 'EmbeddedTeaming'     $sw.EmbeddedTeamingEnabled
            & $addRow 'SET Virtual Switch' $sw.Name 'TeamMembers'         $teamMembers
            & $addRow 'SET Virtual Switch' $sw.Name 'AllowManagementOS'   $sw.AllowManagementOS
            & $addRow 'SET Virtual Switch' $sw.Name 'BandwidthReservationMode' $sw.BandwidthReservationMode
        }

        # ---- Host vNICs & IP Addresses ----
        $hostVNics = Get-VMNetworkAdapter -ManagementOS -ErrorAction SilentlyContinue
        foreach ($vnic in $hostVNics) {
            $adapterName = "vEthernet ($($vnic.Name))"
            $ips = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue

            & $addRow 'Host vNIC' $vnic.Name 'SwitchName' $vnic.SwitchName

            # Report each IPv4 address assigned to the vNIC.
            foreach ($ip in $ips) {
                & $addRow 'Host vNIC' $vnic.Name 'IPAddress'    $ip.IPAddress
                & $addRow 'Host vNIC' $vnic.Name 'PrefixLength' $ip.PrefixLength
            }
        }

        # ---- Hyper-V Host Settings ----
        $vmHost = Get-VMHost -ErrorAction SilentlyContinue
        if ($vmHost) {
            & $addRow 'Hyper-V Host' $env:COMPUTERNAME 'VirtualMachinePath'              $vmHost.VirtualMachinePath
            & $addRow 'Hyper-V Host' $env:COMPUTERNAME 'VirtualHardDiskPath'             $vmHost.VirtualHardDiskPath
            & $addRow 'Hyper-V Host' $env:COMPUTERNAME 'NumaSpanningEnabled'             $vmHost.NumaSpanningEnabled
            & $addRow 'Hyper-V Host' $env:COMPUTERNAME 'EnableEnhancedSessionMode'       $vmHost.EnableEnhancedSessionMode
            & $addRow 'Hyper-V Host' $env:COMPUTERNAME 'MaximumVirtualMachineMigrations' $vmHost.MaximumVirtualMachineMigrations
        }

        # ---- QoS Bandwidth Weights ----
        foreach ($vnic in $hostVNics) {
            # Only report QoS weights for vNICs with a non-zero weight.
            if ($vnic.BandwidthSetting -and $vnic.BandwidthSetting.MinimumBandwidthWeight -gt 0) {
                & $addRow 'QoS Bandwidth' $vnic.Name 'MinimumBandwidthWeight' $vnic.BandwidthSetting.MinimumBandwidthWeight
            }
        }

        # ---- Jumbo Frames ----
        $interconnectVNics = @(
            "vEthernet ($($Config.ClusterVNicName))",
            "vEthernet ($($Config.LiveMigrationVNicName))"
        )
        foreach ($alias in $interconnectVNics) {
            $jumbo = Get-NetAdapterAdvancedProperty -Name $alias -DisplayName 'Jumbo Packet' -ErrorAction SilentlyContinue
            if ($jumbo) {
                & $addRow 'Jumbo Frames' $alias 'JumboPacket' $jumbo.DisplayValue
            }
        }

        # ---- NIC Tuning (Physical NICs) ----
        $physicalNics = Get-NetAdapter -Name $Config.PhysicalNicPattern -ErrorAction SilentlyContinue
        if ($physicalNics) {
            foreach ($nic in $physicalNics) {
                $vmq = Get-NetAdapterVmq -Name $nic.Name -ErrorAction SilentlyContinue
                if ($vmq) {
                    & $addRow 'NIC Tuning' $nic.Name 'VmqEnabled'      $vmq.Enabled
                    & $addRow 'NIC Tuning' $nic.Name 'VmqMaxProcessors' $vmq.MaxProcessors
                }

                $rss = Get-NetAdapterRss -Name $nic.Name -ErrorAction SilentlyContinue
                if ($rss) {
                    & $addRow 'NIC Tuning' $nic.Name 'RssEnabled' $rss.Enabled
                    & $addRow 'NIC Tuning' $nic.Name 'RssProfile' $rss.Profile
                }

                $cso = Get-NetAdapterChecksumOffload -Name $nic.Name -ErrorAction SilentlyContinue
                if ($cso) {
                    & $addRow 'NIC Tuning' $nic.Name 'ChecksumOffload-TcpIPv4' $cso.TcpIPv4
                    & $addRow 'NIC Tuning' $nic.Name 'ChecksumOffload-UdpIPv4' $cso.UdpIPv4
                }

                # Collect key advanced properties.
                $advProps = @('Virtual Machine Multi-Queue', 'Receive Buffers', 'Transmit Buffers',
                              'Interrupt Moderation', 'Maximum Number of RSS Queues')
                foreach ($propName in $advProps) {
                    $adv = Get-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $propName -ErrorAction SilentlyContinue
                    if ($adv) {
                        $safeKey = $propName -replace ' ', ''
                        & $addRow 'NIC Tuning' $nic.Name $safeKey $adv.DisplayValue
                    }
                }
            }
        }

        # ---- Cluster Info (conditional) ----
        $cluster = Get-Cluster -ErrorAction SilentlyContinue
        if ($cluster) {
            & $addRow 'Cluster' $cluster.Name 'ClusterName'   $cluster.Name
            & $addRow 'Cluster' $cluster.Name 'ClusterDomain' $cluster.Domain

            # Report each cluster network with its role and subnet.
            $clusterNets = Get-ClusterNetwork -ErrorAction SilentlyContinue
            foreach ($net in $clusterNets) {
                & $addRow 'Cluster Network' $net.Name 'Address' $net.Address
                & $addRow 'Cluster Network' $net.Name 'Role'    $net.Role
                & $addRow 'Cluster Network' $net.Name 'State'   $net.State
            }

            # Report live migration settings from the local host.
            if ($vmHost) {
                & $addRow 'Live Migration' $env:COMPUTERNAME 'VirtualMachineMigrationEnabled'        $vmHost.VirtualMachineMigrationEnabled
                & $addRow 'Live Migration' $env:COMPUTERNAME 'MigrationAuthenticationType'           $vmHost.VirtualMachineMigrationAuthenticationType
                & $addRow 'Live Migration' $env:COMPUTERNAME 'MigrationPerformanceOption'            $vmHost.VirtualMachineMigrationPerformanceOption
                & $addRow 'Live Migration' $env:COMPUTERNAME 'MaximumVirtualMachineMigrations'       $vmHost.MaximumVirtualMachineMigrations
            }

            # Report configured migration networks.
            $migNets = Get-VMMigrationNetwork -ErrorAction SilentlyContinue
            foreach ($mn in $migNets) {
                & $addRow 'Live Migration' $mn.Subnet 'MigrationSubnet' $mn.Subnet
                & $addRow 'Live Migration' $mn.Subnet 'Priority'        $mn.Priority
            }
        }

        $rows.ToArray()
    }

    function Export-ConfigurationReport {
        # Export the report object array to a timestamped CSV in $PSScriptRoot.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [PSCustomObject[]]$Report
        )

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $fileName  = "HyperV-Config-Report_${env:COMPUTERNAME}_${timestamp}.csv"
        $filePath  = Join-Path -Path $PSScriptRoot -ChildPath $fileName

        # Write the report rows to CSV without type metadata.
        $Report | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8

        $filePath
    }

    #endregion
}

try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
