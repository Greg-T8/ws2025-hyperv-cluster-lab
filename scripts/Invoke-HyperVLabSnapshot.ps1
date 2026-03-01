<#
.SYNOPSIS
Creates, restores, or deletes Hyper-V VM snapshots for all Terraform lab VMs.

.DESCRIPTION
Finds Terraform lab VMs by prefix and optional VM path, then either creates a
checkpoint on each VM, restores each VM to a checkpoint name, or deletes a
named checkpoint from each VM.

.CONTEXT
3-node local Hyper-V failover cluster lab

.AUTHOR
Greg Tate

.NOTES
Program: Invoke-HyperVLabSnapshot.ps1
#>

[CmdletBinding()]
param(
	[Parameter()]
	[ValidateSet('Create', 'Revert', 'Delete')]
	[string]$Action = 'Create',

	[Parameter()]
	[string]$SnapshotName,

	[Parameter()]
	[string]$VmPrefix,

	[Parameter()]
	[string]$VmPath,

	[Parameter()]
	[switch]$StartPreviouslyRunning
)

$Main = {
	. $Helpers

	# Load Terraform defaults from tfvars when prefix/path are not passed in.
	$tfVarsPath = Join-Path -Path $PSScriptRoot -ChildPath '..\terraform\terraform.tfvars'
	$resolvedPrefix = Resolve-ParameterValue -ExplicitValue $VmPrefix -TfVarsPath $tfVarsPath -VariableName 'vm_prefix'
	$resolvedPath = Resolve-ParameterValue -ExplicitValue $VmPath -TfVarsPath $tfVarsPath -VariableName 'vm_path'

	# Create a timestamped name when creating checkpoints and no name is supplied.
	$resolvedSnapshotName = Resolve-SnapshotName -RequestedName $SnapshotName -Action $Action

	# Resolve all target lab VMs and retry without path filtering when needed.
	$targetVms = Get-TargetVm -Prefix $resolvedPrefix -PathFilter $resolvedPath
	if ((-not $targetVms) -and (-not [string]::IsNullOrWhiteSpace($resolvedPath))) {
		$targetVms = Get-TargetVm -Prefix $resolvedPrefix -PathFilter ''
	}

	# Exit with a clear error when no matching VMs are available.
	if (-not $targetVms) {
		throw "No VMs were found for prefix '$resolvedPrefix'. Deploy the lab VMs first or pass -VmPrefix/-VmPath explicitly."
	}

	# Dispatch the requested snapshot operation.
	if ($Action -eq 'Create') {
		New-LabCheckpoint -VmList $targetVms -Name $resolvedSnapshotName
		return
	}

	# Delete the named snapshot on every target VM when requested.
	if ($Action -eq 'Delete') {
		Remove-LabCheckpoint -VmList $targetVms -Name $resolvedSnapshotName
		return
	}

	Restore-LabCheckpoint -VmList $targetVms -Name $resolvedSnapshotName -StartPrevious:$StartPreviouslyRunning
}

$Helpers = {
	# Return an explicit parameter value or read a fallback value from terraform.tfvars.
	function Resolve-ParameterValue {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[AllowEmptyString()]
			[string]$ExplicitValue,

			[Parameter(Mandatory)]
			[string]$TfVarsPath,

			[Parameter(Mandatory)]
			[string]$VariableName
		)

		# Use an explicitly supplied value when one is provided.
		if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
			return $ExplicitValue
		}

		# Return nothing when tfvars does not exist, allowing later validation to fail clearly.
		if (-not (Test-Path -Path $TfVarsPath)) {
			return ''
		}

		# Extract a quoted string variable from terraform.tfvars using simple line parsing.
		$matchingLine = Get-Content -Path $TfVarsPath |
			Where-Object {
				$_ -match "^\s*$VariableName\s*="
			} |
			Select-Object -First 1
		if ($matchingLine) {
			$valuePart = ($matchingLine -split '=', 2)[1].Trim()
			if ($valuePart.StartsWith('"') -and $valuePart.EndsWith('"')) {
				return $valuePart.Trim('"')
			}
		}

		return ''
	}

	# Validate and normalize the snapshot name based on the selected action.
	function Resolve-SnapshotName {
		[CmdletBinding()]
		param(
			[Parameter()]
			[string]$RequestedName,

			[Parameter(Mandatory)]
			[ValidateSet('Create', 'Revert', 'Delete')]
			[string]$Action
		)

		# Require a snapshot name for restore and delete operations.
		if (($Action -eq 'Revert' -or $Action -eq 'Delete') -and [string]::IsNullOrWhiteSpace($RequestedName)) {
			throw "SnapshotName is required when Action is $Action."
		}

		# Generate a deterministic timestamped name when creating checkpoints.
		if ($Action -eq 'Create' -and [string]::IsNullOrWhiteSpace($RequestedName)) {
			return (Get-Date -Format 'yyyyMMdd-HHmmss')
		}

		return $RequestedName
	}

	# Get all Hyper-V VMs that belong to this Terraform lab environment.
	function Get-TargetVm {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[string]$Prefix,

			[Parameter()]
			[AllowEmptyString()]
			[string]$PathFilter
		)

		# Query by naming convention and apply optional path filtering.
		$vms = Get-VM -Name "$Prefix-*" -ErrorAction SilentlyContinue |
			Sort-Object -Property Name

		# Keep only VMs that live under the Terraform VM path when one is available.
		if (-not [string]::IsNullOrWhiteSpace($PathFilter)) {
			$vms = $vms |
				Where-Object {
					$_.Path -like "$PathFilter*"
				}
		}

		return @($vms)
	}

	# Create a checkpoint with the provided name on every target VM.
	function New-LabCheckpoint {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[object[]]$VmList,

			[Parameter(Mandatory)]
			[string]$Name
		)

		# Prevent partial checkpoint creation when the name already exists.
		$existing = @()
		foreach ($vm in $VmList) {
			$snapshot = Get-VMSnapshot -VMName $vm.Name -Name $Name -ErrorAction SilentlyContinue
			if ($snapshot) {
				$existing += $vm.Name
			}
		}

		# Fail fast if any VM already has the requested snapshot name.
		if ($existing.Count -gt 0) {
			$joined = $existing -join ', '
			throw "Snapshot '$Name' already exists on: $joined"
		}

		# Create the checkpoint on each VM.
		foreach ($vm in $VmList) {
			# Enable checkpoint support when Terraform configured the VM with disabled checkpoints.
			if ($vm.CheckpointType -eq 'Disabled') {
				Set-VM -Name $vm.Name -CheckpointType Standard -ErrorAction Stop | Out-Null
				Write-Host "Enabled checkpoints on $($vm.Name)"
			}

			Checkpoint-VM -VMName $vm.Name -SnapshotName $Name -ErrorAction Stop | Out-Null
			Write-Host "Created snapshot '$Name' on $($vm.Name)"
		}
	}

	# Restore each VM to the provided checkpoint name with validation and optional restart.
	function Restore-LabCheckpoint {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[object[]]$VmList,

			[Parameter(Mandatory)]
			[string]$Name,

			[Parameter(Mandatory)]
			[bool]$StartPrevious
		)

		# Verify every target VM has the requested snapshot before making changes.
		$missing = @()
		foreach ($vm in $VmList) {
			$snapshot = Get-VMSnapshot -VMName $vm.Name -Name $Name -ErrorAction SilentlyContinue
			if (-not $snapshot) {
				$missing += $vm.Name
			}
		}

		# Stop immediately when one or more VMs do not contain the named snapshot.
		if ($missing.Count -gt 0) {
			$joined = $missing -join ', '
			throw "Snapshot '$Name' does not exist on: $joined"
		}

		# Track VMs that were running so they can be returned to their prior state.
		$runningVmNames = @()
		foreach ($vm in $VmList) {
			if ($vm.State -eq 'Running') {
				$runningVmNames += $vm.Name
			}
		}

		# Power off running VMs before restore to avoid interactive prompts and state drift.
		foreach ($vmName in $runningVmNames) {
			Stop-VM -Name $vmName -TurnOff -Force -Confirm:$false -ErrorAction Stop
			Write-Host "Stopped VM $vmName before restore"
		}

		# Restore the named snapshot on each VM.
		foreach ($vm in $VmList) {
			Restore-VMSnapshot -VMName $vm.Name -Name $Name -Confirm:$false -ErrorAction Stop
			Write-Host "Restored VM $($vm.Name) to snapshot '$Name'"
		}

		# Restart VMs that were running before restore when requested.
		if ($StartPrevious) {
			foreach ($vmName in $runningVmNames) {
				Start-VM -Name $vmName -ErrorAction Stop | Out-Null
				Write-Host "Started VM $vmName"
			}
		}
	}

	# Delete the provided checkpoint name from each VM after full validation.
	function Remove-LabCheckpoint {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[object[]]$VmList,

			[Parameter(Mandatory)]
			[string]$Name
		)

		# Verify every target VM has the requested snapshot before deleting anything.
		$missing = @()
		foreach ($vm in $VmList) {
			$snapshot = Get-VMSnapshot -VMName $vm.Name -Name $Name -ErrorAction SilentlyContinue
			if (-not $snapshot) {
				$missing += $vm.Name
			}
		}

		# Stop immediately when one or more VMs do not contain the named snapshot.
		if ($missing.Count -gt 0) {
			$joined = $missing -join ', '
			throw "Snapshot '$Name' does not exist on: $joined"
		}

		# Remove the named snapshot from each VM.
		foreach ($vm in $VmList) {
			Remove-VMSnapshot -VMName $vm.Name -Name $Name -Confirm:$false -ErrorAction Stop
			Write-Host "Deleted snapshot '$Name' on $($vm.Name)"
		}
	}
}

try {
	Push-Location -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
	& $Main
}
finally {
	Pop-Location
}
