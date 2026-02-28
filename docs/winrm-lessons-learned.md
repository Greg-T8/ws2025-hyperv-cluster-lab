# WinRM Configuration: Lessons Learned for the Terraform Hyper-V Provider

This document captures every WinRM issue encountered while configuring the
[taliesins/hyperv](https://registry.terraform.io/providers/taliesins/hyperv)
Terraform provider to manage a local Hyper-V host, along with the fixes
applied. Use it as a pre-flight checklist before running `terraform apply`
on a fresh Windows workstation.

---

## 1. WinRM Service Must Be Running

**Symptom** — `dial tcp 127.0.0.1:5986: connectex: No connection could be
made because the target machine actively refused it.`

**Root Cause** — The WinRM service (`WinRM`) was not running and had no
listeners configured.

**Fix**

```powershell
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
winrm quickconfig -quiet
```

**Verification**

```powershell
Get-Service WinRM                               # Status = Running
winrm enumerate winrm/config/listener           # At least one listener present
Test-NetConnection -ComputerName localhost -Port 5985   # TcpTestSucceeded = True
```

---

## 2. Network Profile Must Be Private (Not Public)

**Symptom** — `WinRM firewall exception will not work since one of the
network connection types on this machine is set to Public.`

**Root Cause** — Hyper-V virtual switches (`vEthernet (Internal Switch)`,
`vEthernet (Ethernet vSwitch)`) default to the **Public** network category.
WinRM refuses to open firewall exceptions or set `AllowUnencrypted = true`
when any adapter is Public.

**Fix**

```powershell
Get-NetConnectionProfile |
    Where-Object NetworkCategory -eq 'Public' |
    Set-NetConnectionProfile -NetworkCategory Private
```

**Verification**

```powershell
Get-NetConnectionProfile | Format-Table Name, InterfaceAlias, NetworkCategory
# All adapters should show Private or Domain
```

> **Note:** This setting can revert after reboot or when Hyper-V virtual
> switches are recreated. Check it again if WinRM errors reappear.

---

## 3. AllowUnencrypted Must Be Enabled for HTTP

**Symptom** — `http response error: 401 - invalid content type` when using
HTTP (port 5985) with NTLM authentication.

**Root Cause** — WinRM defaults to `AllowUnencrypted = false` on both the
service and client sides. The Hyper-V provider's Go-based WinRM client
requires this setting when operating over plain HTTP.

**Fix**

```powershell
# Service side
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true

# Client side
Set-Item -Path WSMan:\localhost\Client\AllowUnencrypted -Value $true
```

**Verification**

```powershell
Get-Item WSMan:\localhost\Service\AllowUnencrypted   # Value = true
Get-Item WSMan:\localhost\Client\AllowUnencrypted    # Value = true
```

---

## 4. Basic Auth Must Be Enabled on the Service

**Symptom** — Persistent `401` responses even after enabling
`AllowUnencrypted`.

**Root Cause** — WinRM service had `Basic = false` by default. While NTLM
is the primary auth method for this provider, enabling Basic auth removes
an additional negotiation failure path.

**Fix**

```powershell
winrm set winrm/config/service/auth '@{Basic="true"}'
```

**Verification**

```powershell
winrm get winrm/config/service/auth
# Basic = true, Negotiate = true, Kerberos = true
```

---

## 5. LocalAccountTokenFilterPolicy Must Be Set

**Symptom** — `401` or `Access is denied` when authenticating with a local
administrator account that is not the built-in `Administrator`.

**Root Cause** — Windows UAC remote restrictions strip the admin token from
non-built-in administrator accounts during network logons. The Hyper-V
provider needs full administrative privileges to create VHDs and VMs.

**Fix**

```powershell
New-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy' `
    -Value 1 `
    -PropertyType DWord `
    -Force
```

**Verification**

```powershell
Get-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy'
# LocalAccountTokenFilterPolicy = 1
```

> **Note:** This setting is persistent across reboots. It weakens UAC
> remote restrictions for all local admin accounts. In a home lab this is
> acceptable; evaluate the risk for shared machines.

---

## 6. Microsoft-Linked Accounts Cannot Be Used

**Symptom** — `The user name or password is incorrect (0x8007052E)` inside
the provider's elevated-shell script at `RegisterTaskDefinition`.

**Root Cause** — The Terraform Hyper-V provider uses the Windows Task
Scheduler API (`RegisterTaskDefinition`) to run commands with elevation.
This API calls the full Windows logon service, which rejects Microsoft
Account-linked users because:

- The local cached password may differ from the online Microsoft Account
  password.
- Windows Hello / PIN credentials are not valid for programmatic logon.

The `ValidateCredentials` .NET API may return `True` against the local
cache, but Task Scheduler requires a real NTLM/Kerberos logon that fails
for Microsoft Accounts.

**Fix** — Use the **built-in local Administrator** account instead.

```powershell
# Enable and set a password for the built-in Administrator
Enable-LocalUser -Name Administrator
$pw = ConvertTo-SecureString 'YOUR_PASSWORD' -AsPlainText -Force
Set-LocalUser -Name Administrator -Password $pw
```

Then configure Terraform with:

```hcl
hyperv_user = "COMPUTERNAME\\Administrator"
```

**Verification**

```powershell
# Confirm Task Scheduler accepts the credentials
$svc = New-Object -ComObject Schedule.Service
$svc.Connect()
$folder = $svc.GetFolder('\')
$td = $svc.NewTask(0)
$td.RegistrationInfo.Description = 'credential test'
$td.Actions.Create(0).Path = 'cmd.exe'
$td.Actions.Item(1).Arguments = '/c echo ok'
$folder.RegisterTaskDefinition('TF_CRED_TEST', $td, 6, 'COMPUTERNAME\Administrator', 'YOUR_PASSWORD', 1)
$folder.DeleteTask('TF_CRED_TEST', 0)
Write-Host 'Task Scheduler credential test passed'
```

---

## 7. Use `localhost` Instead of `127.0.0.1`

**Symptom** — Kerberos/Negotiate authentication failures with error
`0x8009030e` (logon session does not exist) when connecting to `127.0.0.1`.

**Root Cause** — Kerberos SPN resolution does not work against raw IP
addresses. The Negotiate auth handler tries Kerberos first, fails, and may
not fall back to NTLM cleanly.

**Fix** — Set the provider host to `localhost`:

```hcl
hyperv_host = "localhost"
```

---

## 8. Increase Provider Timeout for Large Deployments

**Symptom** — `Command has already been closed` errors when creating
multiple VHDs or VMs in parallel.

**Root Cause** — The default `30s` provider timeout is too short for
operations like creating fixed-size VHDs (100 GB). The WinRM shell closes
before the operation completes.

**Fix**

```hcl
hyperv_timeout = "300s"
```

---

## Working Provider Configuration Summary

These are the Terraform variable values that resolved all issues:

| Variable           | Value                      | Why                                        |
|--------------------|----------------------------|--------------------------------------------|
| `hyperv_host`      | `localhost`                | Avoids Kerberos SPN issues with IP address |
| `hyperv_port`      | `5985`                     | HTTP listener (no TLS cert required)       |
| `hyperv_https`     | `false`                    | Matches HTTP listener                      |
| `hyperv_insecure`  | `true`                     | Skip cert validation (HTTP mode)           |
| `hyperv_use_ntlm`  | `true`                     | NTLM auth for local accounts               |
| `hyperv_user`      | `COMPUTERNAME\Administrator`| Built-in admin avoids Microsoft Account issues |
| `hyperv_timeout`   | `300s`                     | Prevents shell timeout on large VHDs       |

## Host-Side Prerequisites Checklist

Run these commands in an **elevated PowerShell** session before `terraform apply`:

```powershell
# 1. Start WinRM
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# 2. Set network profiles to Private
Get-NetConnectionProfile |
    Where-Object NetworkCategory -eq 'Public' |
    Set-NetConnectionProfile -NetworkCategory Private

# 3. Enable AllowUnencrypted (service and client)
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item -Path WSMan:\localhost\Client\AllowUnencrypted -Value $true

# 4. Enable Basic auth
winrm set winrm/config/service/auth '@{Basic="true"}'

# 5. Disable UAC remote token filtering
New-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy' `
    -Value 1 `
    -PropertyType DWord `
    -Force

# 6. Verify
winrm enumerate winrm/config/listener
Test-NetConnection -ComputerName localhost -Port 5985
```
