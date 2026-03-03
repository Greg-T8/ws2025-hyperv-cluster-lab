If the UEFI shell is not present in the boot policy and you explicitly have:

* Boot Mode = UEFI
* Boot Device = Local Disk via MSTOR-RAID
* Windows Boot Manager selected

Then this is almost always one of three UCS firmware behaviors.

---

## 1. The Controller Is Not Presenting a Valid EFI Boot Entry

On Cisco UCS blades (B-200 M5 / M6), the RAID controller must expose an EFI boot entry. If Windows installed correctly but the EFI entry is not properly registered in firmware, UCS falls to the internal shell.

This happens when:

* Windows was installed in Legacy mode originally
* Or the EFI System Partition was not written correctly
* Or the boot order entry points to the disk, not the EFI file

### Validate Inside Windows

Run:

```powershell
bcdedit /enum firmware
```

You should see something like:

```
Windows Boot Manager
--------------------
path \EFI\Microsoft\Boot\bootmgfw.efi
```

If you do not see a firmware boot entry, that is the problem.

---

## 2. UCS Boot Policy Is Too Generic

Even if you selected “Local Disk,” UCS sometimes requires:

* Explicit UEFI boot option
* Targeting the controller AND LUN

Instead of:

```
Local Disk (MSTOR-RAID)
```

It sometimes needs:

```
UEFI: Windows Boot Manager
```

If that option is not selectable in Intersight, the EFI entry may not exist in firmware yet.

---

## 3. Secure Boot or UEFI Order Glitch (Common on M5/M6)

There is a known behavior on some UCS firmware versions where:

* UEFI shell loads first
* Even when not in boot list
* Until a proper EFI boot variable is registered

Typing `exit` just advances to the next valid entry.

This means firmware does not see your Windows Boot Manager as the first valid boot candidate.

---

# Immediate Remediation

On the Windows host:

### Rebuild EFI Boot Entry

```powershell
bcdboot C:\Windows /f UEFI
```

Then reboot.

This rewrites the EFI bootloader into firmware and usually fixes UCS dropping to shell.

---

# If That Does Not Fix It

Then check in UCS / Intersight:

* Boot Mode = UEFI (not Legacy)
* Ensure no “Embedded EFI Shell” option exists in hidden advanced settings
* Confirm MSTOR RAID virtual drive is marked bootable

Also verify:

In RAID controller BIOS:

* The virtual disk is marked as bootable
* EFI partition exists

---

# Why This Is Not a Windows Issue

Because:

* When you type `exit`, Windows boots fine
* That means disk and OS are correct
* Firmware simply does not have correct EFI priority

This is almost always an EFI variable registration issue.

---

# Most Likely Fix in Your Case

Run:

```powershell
bcdboot C:\Windows /f UEFI
```

Reboot.

If it boots straight into Windows afterward, the issue was missing EFI boot registration.

---

If it still boots to shell, I’ll want to know:

* RAID controller model (likely Cisco 12G/14G SAS MSTOR variant)
* UCS firmware version
* Whether this was a fresh install or conversion from legacy

That will narrow it immediately.
