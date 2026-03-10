# NIC Team Download Test

To test the download performance of the NIC team, we will use the following PowerShell command to download a 1GB file from OVH's proof server:

```powershell
$ProgressPreference = 'SilentlyContinue'
Measure-Command {
    Invoke-WebRequest https://proof.ovh.net/files/1Gb.dat -OutFile $env:TEMP\1GB.bin
}
```

**Result**: No significant difference was observed between the standalone NIC, the LFBO NIC team, and the SET NIC team, with all achieving similar download speeds.

**Standalone NIC**:

<img src='.img/2026-03-10-14-57-37.png' width=600>
<img src='.img/2026-03-10-14-57-56.png' width=600>
<img src='.img/2026-03-10-14-58-22.png' width=600>

**LFBO Team**:
<img src='.img/2026-03-10-14-58-43.png' width=300>
<img src='.img/2026-03-10-14-58-50.png' width=300>

<img src='.img/2026-03-10-14-59-09.png' width=600>
<img src='.img/2026-03-10-14-59-16.png' width=600>
<img src='.img/2026-03-10-14-59-22.png' width=600>

**SET Team**:
<img src='.img/2026-03-10-14-59-36.png' width=400>
<img src='.img/2026-03-10-15-00-01.png' width=600>
<img src='.img/2026-03-10-15-01-25.png' width=600>
<img src='.img/2026-03-10-15-02-20.png' width=600>
