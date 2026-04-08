$shareName = "ClusterVMs"
$sharePath = "C:\ClusterVMs"

# Create folder/share if needed
New-Item -ItemType Directory -Path $sharePath -Force | Out-Null
if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $shareName -Path $sharePath | Out-Null
}

# Share ACL: cluster + node computer accounts
Grant-SmbShareAccess -Name $shareName -AccountName "TEST\HV-Cluster$" -AccessRight Full -Force
Grant-SmbShareAccess -Name $shareName -AccountName "TEST\TEST-HV01$" -AccessRight Full -Force
Grant-SmbShareAccess -Name $shareName -AccountName "TEST\TEST-HV02$" -AccessRight Full -Force
Grant-SmbShareAccess -Name $shareName -AccountName "TEST\TEST-HV03$" -AccessRight Full -Force

# NTFS ACL: same identities
icacls $sharePath /grant "TEST\HV-Cluster`$:(OI)(CI)F" `
                  "TEST\TEST-HV01`$:(OI)(CI)F" `
                  "TEST\TEST-HV02`$:(OI)(CI)F" `
                  "TEST\TEST-HV03`$:(OI)(CI)F" `
                  "SYSTEM:(OI)(CI)F" `
                  "Administrators:(OI)(CI)F" /T