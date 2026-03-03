In Cisco UCS (Intersight-managed), **LACP is not configured on the blade vNIC itself** the way it would be on a traditional server NIC. Blades connect to the Fabric Interconnect (FI), and LACP only applies in specific locations.

You need to check three places to determine what’s happening.

---

# 1. Check the vNIC Template (Blade-Level)

This tells you whether the host-facing interface is part of any port-channel behavior.

### In Intersight

1. Go to **Profiles → Server Profiles**
2. Open the profile attached to your blade
3. Go to **vNICs**
4. Open each vNIC (Fabric A and Fabric B)
5. Review:

   * Fabric ID (A or B)
   * Placement
   * Adapter Policy
   * QoS Policy
   * Network Control Policy

You are looking for:

* **No port-channel configuration**
* No LACP mode setting (there normally isn’t one per blade)
* Each vNIC pinned to a single fabric

In UCS B-Series, per-blade LACP is not typically configured. If someone attempted to treat blade vNICs like rack server interfaces, that would be incorrect.

---

# 2. Check FI Uplink Port-Channel (Where LACP Actually Lives)

LACP in UCS exists:

* Between Fabric Interconnect → Upstream switches

It does **NOT** exist:

* Between blade → Fabric Interconnect

### In Intersight

Go to:

**Infrastructure → Fabric Interconnects**

Select Fabric A:

* Go to **Ports**
* Look for **Port Channels**

Open any port-channel and verify:

* Mode: Active (LACP)
* Member ports
* Upstream connectivity

Repeat for Fabric B.

If LACP is configured, it will be here — not at the blade level.

---

# 3. Confirm the Host Is Not Expecting LACP

On the Windows host, if you are using:

* LBFO in LACP mode → this is wrong for UCS blades
* SET → this is correct

Check:

```powershell
Get-VMSwitch
```

If SET:

* It runs in Switch Independent mode
* It does not use LACP
* Each NIC operates independently

If LBFO:
Check:

```powersshell
Get-NetLbfoTeam
```

If it shows:

* TeamingMode = LACP

That is a misconfiguration for UCS blades.

---

# Critical Design Rule for UCS B-Series

Correct Design:

Blade:

* vNIC-A → Fabric A
* vNIC-B → Fabric B
* No LACP per blade

Fabric Interconnect:

* LACP configured northbound only
* FI handles upstream aggregation

Windows:

* SET
* Switch Independent
* Dynamic load balancing

Incorrect Design:

* Windows LBFO with LACP
* Attempting to form port-channel between blade and FI
* Per-blade LACP expectations

---

# Why This Matters for Your Sluggish Performance

If:

* Windows team is LACP
* But FI does not see blade ports as port-channel members

Traffic hashing collapses to a single path or misbehaves.

That can absolutely explain:

* Slow Windows Updates
* DNS SRV lookup failures
* KMS oddities

---

# Quick Validation Checklist for You

On Windows:

* Are you using SET?
* Is teaming mode Switch Independent?

In Intersight:

* Are blade vNICs simply assigned Fabric A / Fabric B?
* Is LACP only configured on FI uplinks?

---

If you tell me:

* Are you using SET or LBFO?
* What does `Get-VMSwitch` show?
* What does `Get-NetLbfoTeam` show?

I can immediately confirm whether LACP mismatch is your root cause.
