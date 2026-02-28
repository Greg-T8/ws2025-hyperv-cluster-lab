<#
.SYNOPSIS
Validates local administrator credentials without WinRM.

.DESCRIPTION
Reads Hyper-V credentials from terraform.tfvars (or explicit parameters) and
uses the native Windows LogonUser API to confirm whether credentials are valid.

.CONTEXT
3-node local Hyper-V failover cluster lab

.AUTHOR
Greg Tate

.NOTES
Program: Confirm-LocalAdminCredential.ps1
#>

[CmdletBinding()]
param(
    [string]$UserName,

    [string]$Password,

    [string]$TfvarsPath = '.\terraform.tfvars'
)

$Main = {
    . $Helpers

    $resolvedTfvarsPath = Resolve-TfvarsPath -InputPath $TfvarsPath
    $credentialInput = Get-CredentialInput -ResolvedTfvarsPath $resolvedTfvarsPath -InputUserName $UserName -InputPassword $Password
    $result = Confirm-LocalCredential -InputUserName $credentialInput.UserName -InputPassword $credentialInput.Password
    Show-ValidationResult -Result $result

    if (-not $result.IsValid) {
        exit 1
    }
}

$Helpers = {
    #region INPUT
    # Resolve tfvars path to a full path when available.
    function Resolve-TfvarsPath {
        param(
            [Parameter(Mandatory)]
            [string]$InputPath
        )

        # Return absolute path for existing files, otherwise return original value.
        if (Test-Path -Path $InputPath) {
            return (Resolve-Path -Path $InputPath).Path
        }

        return $InputPath
    }

    # Build final username/password from parameters or terraform.tfvars.
    function Get-CredentialInput {
        param(
            [Parameter(Mandatory)]
            [string]$ResolvedTfvarsPath,

            [string]$InputUserName,

            [string]$InputPassword
        )

        $effectiveUserName = $InputUserName
        $effectivePassword = $InputPassword

        # Load missing values from terraform.tfvars when either input is absent.
        if ([string]::IsNullOrWhiteSpace($effectiveUserName) -or [string]::IsNullOrWhiteSpace($effectivePassword)) {
            if (-not (Test-Path -Path $ResolvedTfvarsPath)) {
                throw "terraform.tfvars was not found at path '$ResolvedTfvarsPath'. Provide -UserName and -Password explicitly."
            }

            $tfvarsRaw = Get-Content -Path $ResolvedTfvarsPath -Raw
            $tfvarsUser = [regex]::Match($tfvarsRaw, '(?m)^\s*hyperv_user\s*=\s*"([^"]+)"').Groups[1].Value
            $tfvarsPassword = [regex]::Match($tfvarsRaw, '(?m)^\s*hyperv_password\s*=\s*"([^"]+)"').Groups[1].Value

            if ([string]::IsNullOrWhiteSpace($effectiveUserName)) {
                $effectiveUserName = $tfvarsUser
            }

            if ([string]::IsNullOrWhiteSpace($effectivePassword)) {
                $effectivePassword = $tfvarsPassword
            }
        }

        # Ensure both credential fields are present before validation.
        if ([string]::IsNullOrWhiteSpace($effectiveUserName) -or [string]::IsNullOrWhiteSpace($effectivePassword)) {
            throw 'Credential values are missing. Set hyperv_user/hyperv_password in tfvars or pass -UserName and -Password.'
        }

        return [PSCustomObject]@{
            UserName = $effectiveUserName
            Password = $effectivePassword
        }
    }
    #endregion

    #region VALIDATION
    # Validate username and password by attempting local Windows logon.
    function Confirm-LocalCredential {
        param(
            [Parameter(Mandatory)]
            [string]$InputUserName,

            [Parameter(Mandatory)]
            [string]$InputPassword
        )

        # Compile native P/Invoke methods once for the current session.
        Add-NativeLogonType

        $normalizedUserName = $InputUserName -replace '\\\\', '\'
        $parsed = Split-AccountName -AccountName $normalizedUserName
        $token = [IntPtr]::Zero
        $isValid = [NativeLogon]::LogonUser($parsed.UserName, $parsed.Domain, $InputPassword, 2, 0, [ref]$token)
        $win32Code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()

        # Release native token handle to prevent handle leaks.
        if ($token -ne [IntPtr]::Zero) {
            [void][NativeLogon]::CloseHandle($token)
        }

        $errorText = ([ComponentModel.Win32Exception]$win32Code).Message

        return [PSCustomObject]@{
            InputUserName       = $InputUserName
            NormalizedUserName  = $normalizedUserName
            ParsedDomain        = $parsed.Domain
            ParsedUserName      = $parsed.UserName
            IsValid             = $isValid
            Win32Code           = $win32Code
            Win32Message        = $errorText
        }
    }

    # Parse account names from DOMAIN\User, user@domain, or bare username formats.
    function Split-AccountName {
        param(
            [Parameter(Mandatory)]
            [string]$AccountName
        )

        # Map known account naming formats into LogonUser domain and username fields.
        if ($AccountName -match '^[^\\]+\\[^\\]+$') {
            $parts = $AccountName -split '\\', 2
            return [PSCustomObject]@{ Domain = $parts[0]; UserName = $parts[1] }
        }

        if ($AccountName -like '*@*') {
            return [PSCustomObject]@{ Domain = $null; UserName = $AccountName }
        }

        return [PSCustomObject]@{ Domain = '.'; UserName = $AccountName }
    }

    # Add a native helper type for LogonUser and CloseHandle.
    function Add-NativeLogonType {
        # Skip compilation when the type is already available.
        if ('NativeLogon' -as [type]) {
            return
        }

        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeLogon
{
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LogonUser(
        string lpszUsername,
        string lpszDomain,
        string lpszPassword,
        int dwLogonType,
        int dwLogonProvider,
        out IntPtr phToken);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@
    }
    #endregion

    #region OUTPUT
    # Print a concise validation summary suitable for troubleshooting.
    function Show-ValidationResult {
        param(
            [Parameter(Mandatory)]
            [PSCustomObject]$Result
        )

        [PSCustomObject]@{
            InputUserName      = $Result.InputUserName
            NormalizedUserName = $Result.NormalizedUserName
            ParsedDomain       = $Result.ParsedDomain
            ParsedUserName     = $Result.ParsedUserName
            IsValid            = $Result.IsValid
            Win32Code          = $Result.Win32Code
            Win32Message       = $Result.Win32Message
        } |
            Format-List |
            Out-String |
            Write-Host
    }
    #endregion
}

try {
    Push-Location -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
    & $Main
}
finally {
    Pop-Location
}
