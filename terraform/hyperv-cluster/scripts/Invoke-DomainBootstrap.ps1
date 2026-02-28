<#
.SYNOPSIS
Promotes a domain controller and joins cluster hosts to the domain.

.DESCRIPTION
Uses PowerShell Direct to configure AD DS on the domain controller VM and
join Hyper-V host VMs to the domain so all hosts are ready for login.

.CONTEXT
3-node local Hyper-V failover cluster lab (Goose Creek ISD)

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

    Wait-ForVmPowerShell -VmName $DomainControllerName -GuestCredential $GuestCredential
    Initialize-DomainController -VmName $DomainControllerName -GuestCredential $GuestCredential -DomainName $DomainName -DomainControllerIPv4 $DomainControllerIPv4 -DomainControllerPrefixLength $DomainControllerPrefixLength -SafeModePassword $SafeModePassword
    Wait-ForDomainReady -VmName $DomainControllerName -GuestCredential $GuestCredential -DomainName $DomainName

    Join-ClusterNodesToDomain -NodeNames $ClusterNodes -GuestCredential $GuestCredential -DomainName $DomainName -DomainControllerIPv4 $DomainControllerIPv4 -DomainAdminUsername $GuestAdminUsername
    Confirm-HostsReady -NodeNames $ClusterNodes -GuestCredential $GuestCredential -DomainName $DomainName
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
    #endregion

    #region VM_READINESS
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
        Invoke-Command -VMName $VmName -Credential $GuestCredential -ScriptBlock {
            param(
                [string]$DomainName,
                [string]$DomainControllerIPv4,
                [int]$DomainControllerPrefixLength,
                [SecureString]$SafeModePassword
            )

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

            Install-ADDSForest \
                -DomainName $DomainName \
                -InstallDns \
                -SafeModeAdministratorPassword $SafeModePassword \
                -Force:$true \
                -NoRebootOnCompletion:$false
        } -ArgumentList $DomainName, $DomainControllerIPv4, $DomainControllerPrefixLength, $SafeModePassword -ErrorAction Stop
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
            [PSCredential]$GuestCredential,

            [Parameter(Mandatory)]
            [string]$DomainName,

            [Parameter(Mandatory)]
            [string]$DomainControllerIPv4,

            [Parameter(Mandatory)]
            [string]$DomainAdminUsername
        )

        # Join each node and restart it if domain membership changes.
        foreach ($nodeName in $NodeNames) {
            Wait-ForVmPowerShell -VmName $nodeName -GuestCredential $GuestCredential
            $domainAdminPasswordSecure = ConvertTo-SecureString -String $env:GUEST_ADMIN_PASSWORD -AsPlainText -Force

            Invoke-Command -VMName $nodeName -Credential $GuestCredential -ScriptBlock {
                param(
                    [string]$DomainName,
                    [string]$DomainControllerIPv4,
                    [string]$DomainAdminUsername,
                    [SecureString]$DomainAdminPassword
                )

                # Exit when the node is already in the target domain.
                $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                if ($computerSystem.PartOfDomain -and $computerSystem.Domain -ieq $DomainName) {
                    return
                }

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
            } -ArgumentList $DomainName, $DomainControllerIPv4, $DomainAdminUsername, $domainAdminPasswordSecure -ErrorAction Stop

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
            [PSCredential]$GuestCredential,

            [Parameter(Mandatory)]
            [string]$DomainName
        )

        # Validate each node reports domain membership.
        foreach ($nodeName in $NodeNames) {
            $isJoined = Invoke-Command -VMName $nodeName -Credential $GuestCredential -ScriptBlock {
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
