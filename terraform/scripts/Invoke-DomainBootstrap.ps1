<#
.SYNOPSIS
Promotes a domain controller and joins cluster hosts to the domain.

.DESCRIPTION
Uses PowerShell Direct to configure AD DS on the domain controller VM and
join Hyper-V host VMs to the domain so all hosts are ready for login.

.CONTEXT
3-node local Hyper-V failover cluster lab

.AUTHOR
Greg Tate

.NOTES
Program: Invoke-DomainBootstrap.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$DomainControllerName,

    [Parameter(Mandatory)]
    [string]$ClusterNodeNames,

    [Parameter(Mandatory)]
    [string]$ClusterNodeInternalIPv4s,

    [Parameter(Mandatory)]
    [string]$GuestAdminUsername,

    [Parameter(Mandatory)]
    [string]$DomainControllerIPv4,

    [Parameter(Mandatory)]
    [int]$DomainControllerPrefixLength
)

$RetryCount = 45
$RetryDelaySeconds = 20

$Main = {
    . $Helpers

    Confirm-Input

    $GuestCredential = New-GuestCredential
    $SafeModePassword = ConvertTo-SecureString -String $env:DOMAIN_SAFE_MODE_PASSWORD -AsPlainText -Force
    $ClusterNodes = Get-ClusterNodeList
    $ClusterNodeInternalIPs = Get-ClusterNodeInternalIpList

    # Power on cluster nodes so Windows installation begins immediately.
    Start-ClusterNodeVMs -VmNames $ClusterNodes

    # Launch parallel background waits for cluster node Windows installations.
    $nodeJobs = Start-ParallelNodeWait -VmNames $ClusterNodes -GuestCredential $GuestCredential

    # Set up the domain controller in the foreground while nodes install.
    Wait-ForVmPowerShell -VmName $DomainControllerName -GuestCredential $GuestCredential
    Initialize-DomainController -VmName $DomainControllerName -GuestCredential $GuestCredential -DomainName $DomainName -DomainControllerIPv4 $DomainControllerIPv4 -DomainControllerPrefixLength $DomainControllerPrefixLength -SafeModePassword $SafeModePassword

    # Build a domain-qualified credential for the DC after AD promotion.
    $domainNetBIOS = $DomainName.Split('.')[0]
    $DomainCredential = [PSCredential]::new("$domainNetBIOS\$($GuestCredential.UserName)", $GuestCredential.Password)
    Wait-ForDomainReady -VmName $DomainControllerName -GuestCredential $DomainCredential -DomainName $DomainName

    # Ensure all cluster nodes finished Windows installation before domain join.
    Complete-ParallelNodeWait -Jobs $nodeJobs

    # Rename cluster nodes to match their Hyper-V VM names.
    Set-ClusterNodeHostname -NodeNames $ClusterNodes -GuestCredential $GuestCredential

    Join-ClusterNodesToDomain -NodeNames $ClusterNodes -NodeIPv4Addresses $ClusterNodeInternalIPs -PrefixLength $DomainControllerPrefixLength -GuestCredential $GuestCredential -DomainName $DomainName -DomainControllerIPv4 $DomainControllerIPv4 -DomainAdminUsername $GuestAdminUsername
    Confirm-HostsReady -NodeNames $ClusterNodes -DomainCredential $DomainCredential -DomainName $DomainName
}

$Helpers = {
    #region VALIDATION
    # Validate input and environment values required for bootstrap.
    function Confirm-Input {
        # Confirm required secret environment variables are present.
        if ([string]::IsNullOrWhiteSpace($env:GUEST_ADMIN_PASSWORD)) {
            throw 'GUEST_ADMIN_PASSWORD environment variable is required.'
        }

        if ([string]::IsNullOrWhiteSpace($env:DOMAIN_SAFE_MODE_PASSWORD)) {
            throw 'DOMAIN_SAFE_MODE_PASSWORD environment variable is required.'
        }

        if ([string]::IsNullOrWhiteSpace($ClusterNodeNames)) {
            throw 'ClusterNodeNames input cannot be empty.'
        }

        if ([string]::IsNullOrWhiteSpace($ClusterNodeInternalIPv4s)) {
            throw 'ClusterNodeInternalIPv4s input cannot be empty.'
        }
    }
    #endregion

    #region CREDENTIALS
    # Build local administrator credential used for PowerShell Direct sessions.
    function New-GuestCredential {
        # Convert plaintext environment password into a secure credential.
        $securePassword = ConvertTo-SecureString -String $env:GUEST_ADMIN_PASSWORD -AsPlainText -Force
        return [PSCredential]::new($GuestAdminUsername, $securePassword)
    }

    # Parse and normalize the comma-delimited cluster host list.
    function Get-ClusterNodeList {
        # Build a clean array of VM names from the incoming list.
        return $ClusterNodeNames.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    # Parse and normalize the comma-delimited cluster node internal IPv4 list.
    function Get-ClusterNodeInternalIpList {
        # Build a clean array of IPv4 addresses from the incoming list.
        $nodeIps = $ClusterNodeInternalIPv4s.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        # Ensure each cluster node has exactly one configured internal IPv4 address.
        $nodeNames = Get-ClusterNodeList
        if ($nodeIps.Count -ne $nodeNames.Count) {
            throw "ClusterNodeInternalIPv4s count [$($nodeIps.Count)] must match ClusterNodeNames count [$($nodeNames.Count)]."
        }

        return $nodeIps
    }
    #endregion

    #region VM_READINESS
    # Start cluster node VMs on the Hyper-V host after AD services are confirmed.
    function Start-ClusterNodeVMs {
        param(
            [Parameter(Mandatory)]
            [string[]]$VmNames
        )

        # Power on each cluster node that is not already running.
        foreach ($vmName in $VmNames) {
            $vm = Get-VM -Name $vmName -ErrorAction Stop
            if ($vm.State -ne 'Running') {
                Write-Host "[$vmName] Starting VM..."
                Start-VM -Name $vmName -ErrorAction Stop
            } else {
                Write-Host "[$vmName] VM is already running."
            }
        }
    }

    # Wait until PowerShell Direct connectivity is available for a VM.
    function Wait-ForVmPowerShell {
        param(
            [Parameter(Mandatory)]
            [string]$VmName,

            [Parameter(Mandatory)]
            [PSCredential]$GuestCredential
        )

        # Retry guest command execution until the VM is responsive.
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock { 'Ready' } -ErrorAction Stop | Out-Null
                Write-Host "[$VmName] PowerShell Direct is ready."
                return
            }
            catch {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }

        throw "Timed out waiting for PowerShell Direct access to VM [$VmName]."
    }

    # Launch parallel background jobs to wait for PowerShell Direct on cluster nodes.
    function Start-ParallelNodeWait {
        param(
            [Parameter(Mandatory)]
            [string[]]$VmNames,

            [Parameter(Mandatory)]
            [PSCredential]$GuestCredential
        )

        Write-Host "Waiting for PowerShell Direct on $($VmNames.Count) cluster nodes in parallel..."

        # Start one background job per cluster node.
        $jobs = foreach ($vmName in $VmNames) {
            Start-Job -ScriptBlock {
                param($VmName, $Username, $MaxRetries, $RetryDelay)

                # Reconstruct guest credential from inherited environment variable.
                $securePwd = ConvertTo-SecureString -String $env:GUEST_ADMIN_PASSWORD -AsPlainText -Force
                $cred = [PSCredential]::new($Username, $securePwd)

                # Retry guest command execution until the VM is responsive.
                for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
                    try {
                        Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock { 'Ready' } -ErrorAction Stop | Out-Null
                        return "[$VmName] PowerShell Direct is ready."
                    }
                    catch {
                        Start-Sleep -Seconds $RetryDelay
                    }
                }

                throw "Timed out waiting for PowerShell Direct access to VM [$VmName]."
            } -ArgumentList $vmName, $GuestCredential.UserName, $RetryCount, $RetryDelaySeconds
        }

        return $jobs
    }

    # Collect results from parallel cluster node wait jobs.
    function Complete-ParallelNodeWait {
        param(
            [Parameter(Mandatory)]
            [System.Management.Automation.Job[]]$Jobs
        )

        # Wait for each job and propagate any failures.
        foreach ($job in $Jobs) {
            $output = Receive-Job -Job $job -Wait -AutoRemoveJob -ErrorAction Stop

            foreach ($line in $output) {
                Write-Host $line
            }
        }
    }
    #endregion

    #region HOSTNAME
    # Rename cluster nodes whose hostname does not match the Hyper-V VM name.
    function Set-ClusterNodeHostname {
        param(
            [Parameter(Mandatory)]
            [string[]]$NodeNames,

            [Parameter(Mandatory)]
            [PSCredential]$GuestCredential
        )

        # Check and rename each node if the current hostname differs.
        foreach ($nodeName in $NodeNames) {
            $currentName = Invoke-Command -VMName $nodeName -Credential $GuestCredential -ScriptBlock {
                $env:COMPUTERNAME
            } -ErrorAction Stop

            if ($currentName -eq $nodeName) {
                Write-Host "[$nodeName] Hostname is already correct."
                continue
            }

            Write-Host "[$nodeName] Renaming from '$currentName' to '$nodeName'..."

            # Rename the computer and restart to apply the new hostname.
            Invoke-Command -VMName $nodeName -Credential $GuestCredential -ScriptBlock {
                param([string]$NewName)

                # Create setup log directory and start transcript.
                New-Item -Path 'C:\setup' -ItemType Directory -Force | Out-Null
                Start-Transcript -Path 'C:\setup\Set-ClusterNodeHostname.log' -Append

                try {
                    Rename-Computer -NewName $NewName -Force -Restart
                } finally {
                    Stop-Transcript -ErrorAction SilentlyContinue
                }
            } -ArgumentList $nodeName -ErrorAction Stop

            Wait-ForVmPowerShell -VmName $nodeName -GuestCredential $GuestCredential
            Write-Host "[$nodeName] Hostname rename completed."
        }
    }
    #endregion

    #region DOMAIN_CONTROLLER
    # Install and configure AD DS forest on the domain controller VM.
    function Initialize-DomainController {
        param(
            [Parameter(Mandatory)]
            [string]$VmName,

            [Parameter(Mandatory)]
            [PSCredential]$GuestCredential,

            [Parameter(Mandatory)]
            [string]$DomainName,

            [Parameter(Mandatory)]
            [string]$DomainControllerIPv4,

            [Parameter(Mandatory)]
            [int]$DomainControllerPrefixLength,

            [Parameter(Mandatory)]
            [SecureString]$SafeModePassword
        )

        # Configure static IP and promote the VM to domain controller when needed.
        # AD promotion triggers a reboot that drops the PowerShell Direct session.
        # Tolerate the expected disconnection error and let Wait-ForDomainReady handle recovery.
        try {
            Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
                param(
                    [string]$DomainName,
                    [string]$DomainControllerIPv4,
                    [int]$DomainControllerPrefixLength,
                    [SecureString]$SafeModePassword
                )

                # Create setup log directory and start transcript.
                New-Item -Path 'C:\setup' -ItemType Directory -Force | Out-Null
                Start-Transcript -Path 'C:\setup\Initialize-DomainController.log' -Append

                try {

                # Select an internal adapter candidate for the domain network.
                $candidateConfig = Get-NetIPConfiguration |
                    Where-Object {
                        $_.NetAdapter.Status -eq 'Up' -and
                        $_.NetAdapter.HardwareInterface -and
                        $null -eq $_.IPv4DefaultGateway
                    } |
                    Select-Object -First 1

                # Fall back to any active hardware adapter if needed.
                if (-not $candidateConfig) {
                    $candidateConfig = Get-NetIPConfiguration |
                        Where-Object {
                            $_.NetAdapter.Status -eq 'Up' -and
                            $_.NetAdapter.HardwareInterface
                        } |
                        Select-Object -First 1
                }

                if (-not $candidateConfig) {
                    throw 'No active network adapter was found in the guest VM.'
                }

                # Remove existing IPv4 addresses and set the required static DC address.
                $existingV4 = Get-NetIPAddress -InterfaceIndex $candidateConfig.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '169.254.*' }

                foreach ($address in $existingV4) {
                    Remove-NetIPAddress -InterfaceIndex $candidateConfig.InterfaceIndex -IPAddress $address.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
                }

                New-NetIPAddress -InterfaceIndex $candidateConfig.InterfaceIndex -IPAddress $DomainControllerIPv4 -PrefixLength $DomainControllerPrefixLength -AddressFamily IPv4 -ErrorAction SilentlyContinue | Out-Null

                # Point DNS to local DC resolver.
                Set-DnsClientServerAddress -InterfaceIndex $candidateConfig.InterfaceIndex -ServerAddresses @('127.0.0.1', $DomainControllerIPv4)

                # Exit early when this VM is already a DC in the target domain.
                $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                if ($computerSystem.PartOfDomain -and $computerSystem.Domain -ieq $DomainName) {
                    return
                }

                # Install AD DS feature and promote new forest.
                Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
                Import-Module -Name ADDSDeployment

                Install-ADDSForest `
                    -DomainName $DomainName `
                    -InstallDns `
                    -SafeModeAdministratorPassword $SafeModePassword `
                    -Force:$true `
                    -NoRebootOnCompletion:$false

                } finally {
                    Stop-Transcript -ErrorAction SilentlyContinue
                }
            } -ArgumentList $DomainName, $DomainControllerIPv4, $DomainControllerPrefixLength, $SafeModePassword -ErrorAction Stop
        }
        catch {
            # AD promotion reboots the DC which terminates the PowerShell Direct session.
            if ($_.Exception.Message -match 'socket target process has ended|transport connection|broken pipe') {
                Write-Host "DC reboot detected after AD promotion (expected). Waiting for domain services..."
            }
            else {
                throw
            }
        }
    }

    # Wait until the AD domain controller is online and serving the domain.
    function Wait-ForDomainReady {
        param(
            [Parameter(Mandatory)]
            [string]$VmName,

            [Parameter(Mandatory)]
            [PSCredential]$GuestCredential,

            [Parameter(Mandatory)]
            [string]$DomainName
        )

        # Retry domain health checks until AD services are online.
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                Wait-ForVmPowerShell -VmName $VmName -GuestCredential $GuestCredential

                $domainIsReady = Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
                    param([string]$DomainName)

                    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                    $ntdsService = Get-Service -Name NTDS -ErrorAction SilentlyContinue

                    return ($computerSystem.PartOfDomain -and $computerSystem.Domain -ieq $DomainName -and $ntdsService.Status -eq 'Running')
                } -ArgumentList $DomainName -ErrorAction Stop

                if ($domainIsReady) {
                    Write-Host "[$VmName] Active Directory domain is ready."
                    return
                }
            }
            catch {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }

        throw "Domain controller [$VmName] did not reach a ready state for domain [$DomainName]."
    }
    #endregion

    #region DOMAIN_JOIN
    # Join all cluster host VMs to the domain.
    function Join-ClusterNodesToDomain {
        param(
            [Parameter(Mandatory)]
            [string[]]$NodeNames,

            [Parameter(Mandatory)]
            [string[]]$NodeIPv4Addresses,

            [Parameter(Mandatory)]
            [int]$PrefixLength,

            [Parameter(Mandatory)]
            [PSCredential]$GuestCredential,

            [Parameter(Mandatory)]
            [string]$DomainName,

            [Parameter(Mandatory)]
            [string]$DomainControllerIPv4,

            [Parameter(Mandatory)]
            [string]$DomainAdminUsername
        )

        # Join each node and restart it if domain membership changes.
        for ($index = 0; $index -lt $NodeNames.Count; $index++) {
            $nodeName = $NodeNames[$index]
            $nodeInternalIPv4 = $NodeIPv4Addresses[$index]

            Wait-ForVmPowerShell -VmName $nodeName -GuestCredential $GuestCredential
            $domainAdminPasswordSecure = ConvertTo-SecureString -String $env:GUEST_ADMIN_PASSWORD -AsPlainText -Force

            # Domain join triggers a restart that drops the PowerShell Direct session.
            # Tolerate the expected disconnection and let Wait-ForVmPowerShell handle recovery.
            try {
                Invoke-Command -VMName $nodeName -Credential $GuestCredential -ScriptBlock {
                    param(
                        [string]$DomainName,
                        [string]$NodeInternalIPv4,
                        [int]$PrefixLength,
                        [string]$DomainControllerIPv4,
                        [string]$DomainAdminUsername,
                        [SecureString]$DomainAdminPassword
                    )

                    # Create setup log directory and start transcript.
                    New-Item -Path 'C:\setup' -ItemType Directory -Force | Out-Null
                    Start-Transcript -Path 'C:\setup\Join-ClusterNodeToDomain.log' -Append

                    try {

                    # Exit when the node is already in the target domain.
                    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                    if ($computerSystem.PartOfDomain -and $computerSystem.Domain -ieq $DomainName) {
                        return
                    }

                    # Select an internal adapter candidate for static node addressing.
                    $candidateConfig = Get-NetIPConfiguration |
                        Where-Object {
                            $_.NetAdapter.Status -eq 'Up' -and
                            $_.NetAdapter.HardwareInterface -and
                            $null -eq $_.IPv4DefaultGateway
                        } |
                        Select-Object -First 1

                    # Fall back to any active hardware adapter if needed.
                    if (-not $candidateConfig) {
                        $candidateConfig = Get-NetIPConfiguration |
                            Where-Object {
                                $_.NetAdapter.Status -eq 'Up' -and
                                $_.NetAdapter.HardwareInterface
                            } |
                            Select-Object -First 1
                    }

                    if (-not $candidateConfig) {
                        throw 'No active network adapter was found in the guest VM.'
                    }

                    # Remove existing IPv4 addresses and set the required static node address.
                    $existingV4 = Get-NetIPAddress -InterfaceIndex $candidateConfig.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -notlike '169.254.*' }

                    foreach ($address in $existingV4) {
                        Remove-NetIPAddress -InterfaceIndex $candidateConfig.InterfaceIndex -IPAddress $address.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
                    }

                    New-NetIPAddress -InterfaceIndex $candidateConfig.InterfaceIndex -IPAddress $NodeInternalIPv4 -PrefixLength $PrefixLength -AddressFamily IPv4 -ErrorAction Stop | Out-Null

                    # Set DNS on all active hardware adapters to the domain controller.
                    Get-NetAdapter |
                        Where-Object {
                            $_.Status -eq 'Up' -and
                            $_.HardwareInterface
                        } |
                        ForEach-Object {
                            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses @($DomainControllerIPv4)
                        }

                    # Build domain admin credential and perform domain join.
                    $domainCredential = [PSCredential]::new("$DomainAdminUsername@$DomainName", $DomainAdminPassword)

                    Add-Computer -DomainName $DomainName -Credential $domainCredential -Force -Restart

                    } finally {
                        Stop-Transcript -ErrorAction SilentlyContinue
                    }
                } -ArgumentList $DomainName, $nodeInternalIPv4, $PrefixLength, $DomainControllerIPv4, $DomainAdminUsername, $domainAdminPasswordSecure -ErrorAction Stop
            }
            catch {
                # Domain join restarts the node which terminates the PowerShell Direct session.
                if ($_.Exception.Message -match 'socket target process has ended|transport connection|broken pipe') {
                    Write-Host "[$nodeName] Reboot detected after domain join (expected)."
                }
                else {
                    throw
                }
            }

            Wait-ForVmPowerShell -VmName $nodeName -GuestCredential $GuestCredential
            Write-Host "[$nodeName] Domain join completed."
        }
    }
    #endregion

    #region VERIFICATION
    # Verify every cluster host can log in with domain credentials.
    function Confirm-HostsReady {
        param(
            [Parameter(Mandatory)]
            [string[]]$NodeNames,

            [Parameter(Mandatory)]
            [PSCredential]$DomainCredential,

            [Parameter(Mandatory)]
            [string]$DomainName
        )

        # Validate each node reports domain membership using the domain credential.
        foreach ($nodeName in $NodeNames) {
            Wait-ForVmPowerShell -VmName $nodeName -GuestCredential $DomainCredential

            $isJoined = Invoke-Command -VMName $nodeName -Credential $DomainCredential -ScriptBlock {
                param([string]$DomainName)

                $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                return ($computerSystem.PartOfDomain -and $computerSystem.Domain -ieq $DomainName)
            } -ArgumentList $DomainName -ErrorAction Stop

            if (-not $isJoined) {
                throw "[$nodeName] is not joined to domain [$DomainName]."
            }

            Write-Host "[$nodeName] is ready for domain login."
        }
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
