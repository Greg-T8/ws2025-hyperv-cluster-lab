<#
.SYNOPSIS
Runs Terraform apply after clearing Hyper-V credential environment variables.

.DESCRIPTION
Clears TF_VAR_hyperv_user and TF_VAR_hyperv_password from the current session so
Terraform prompts for credentials at runtime, then executes apply.

.CONTEXT
3-node local Hyper-V failover cluster lab

.AUTHOR
Greg Tate

.NOTES
Program: Invoke-TerraformApply.ps1
#>

[CmdletBinding()]
param()

$Main = {
    . $Helpers
    Invoke-TerraformApply
}

$Helpers = {
    # Clear session credential variables so Terraform prompts for values.
    function Invoke-TerraformApply {
        # Remove cached Hyper-V user and password values from this shell session.
        Remove-Item Env:TF_VAR_hyperv_user -ErrorAction SilentlyContinue
        Remove-Item Env:TF_VAR_hyperv_password -ErrorAction SilentlyContinue

        # Execute Terraform apply from the Terraform project root directory with interactive input enabled.
        tf apply -auto-approve -input=true
    }
}

try {
    Push-Location -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
    & $Main
}
finally {
    Pop-Location
}
