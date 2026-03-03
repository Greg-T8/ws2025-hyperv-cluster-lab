If other DNS queries succeed but the SRV lookup for `_vlmcs._tcp` fails, the issue is almost certainly one of these:

* the SRV record does not exist in DNS
* you are querying the wrong DNS suffix / zone
* the record exists but is in a different DNS view/scope (less common)
* you have a delegated `_tcp` zone (rare, but it happens) and delegation is broken

### 1) Confirm you’re querying the correct FQDN

KMS auto-discovery requires an SRV record named:

`_vlmcs._tcp.<AD DNS domain>`

Example: if the AD domain is `corp.contoso.com`, the query must be:

`_vlmcs._tcp.corp.contoso.com`

Run:

```powershell
ipconfig /all
```

Check:

* **Primary DNS Suffix**
* **Connection-specific DNS Suffix Search List**

Then query explicitly using the AD DNS domain:

```powershell
nslookup -type=SRV _vlmcs._tcp.<your-ad-domain-fqdn>
```

If you’ve been querying a different suffix (like a “client.com” zone vs AD zone), you’ll get exactly this symptom: normal records work, `_vlmcs._tcp` doesn’t.

---

### 2) Verify the SRV record exists (authoritative check)

From a DNS server (or using RSAT DNS tools), verify the record exists in the zone:

* Forward Lookup Zones

  * `<your-ad-domain-fqdn>`

    * `_tcp` (folder)

      * `_vlmcs` (SRV)

If you can’t use the GUI, from a machine with DNS tools:

```powershell
Get-DnsServerResourceRecord -ZoneName "<your-ad-domain-fqdn>" -RRType SRV | `
  Where-Object HostName -like "*_vlmcs*"
```

If nothing returns, KMS auto-discovery cannot work until it’s created.

---

### 3) If `_tcp` “doesn’t work” but other records do, check for zone delegation

This is the key detail you mentioned: “nested within `_tcp`”.

In Microsoft DNS, `_tcp` is normally just a node inside the zone, not a separate zone. But someone *can* create a separate delegated zone like:

* `_tcp.<domain>`

If that exists and delegation is broken, then:

* A/AAAA/CNAME records in the parent zone resolve fine
* Queries under `_tcp` fail

On a DNS server, check whether `_tcp.<domain>` exists as its own zone.

If it does:

* Either remove that zone (if it’s a mistake), or
* Fix delegation/NS records so clients can resolve `_tcp` names.

You can detect this quickly from a client with `nslookup`:

```powershell
nslookup -type=SOA _tcp.<your-ad-domain-fqdn>
```

* If it returns an SOA, `_tcp` is acting like a zone.
* If it returns NXDOMAIN but the parent zone exists, that’s a strong indicator the structure is wrong (or delegation is broken).

---

### 4) Validate with “set d2” to see where it fails

This will show referrals and whether you’re hitting the correct authority:

```powershell
nslookup
set d2
set debug
server <dns-server-ip>
-type=SRV _vlmcs._tcp.<your-ad-domain-fqdn>
```

Look for:

* NXDOMAIN (record doesn’t exist)
* REFUSED / SERVFAIL (delegation/view issue)
* Response coming from an unexpected DNS server

---

### 5) Fix paths depending on what you find

**If SRV record is missing:**
Create it in the AD-integrated zone:

* Service: `_vlmcs`
* Protocol: `_tcp`
* Port: `1688`
* Host offering this service: `<kms-host-fqdn>`
* Priority/weight: defaults are fine

**If `_tcp.<domain>` is a separate zone and broken:**
Remove it (if erroneous) or fix delegation so it points to the correct DNS servers.

**If the record exists but clients can’t see it:**
Check for:

* split-brain DNS (internal vs external zone mismatch)
* conditional forwarders
* DNS policies/scopes (rare, but possible)
* querying a non-authoritative server due to NIC/team DNS settings

Given your earlier “teaming causes weirdness” symptom, also confirm the teamed interface DNS settings didn’t change which DNS server gets used.

---

Most likely outcome based on your description: `_vlmcs` SRV record is missing in the AD DNS zone, or `_tcp.<domain>` was accidentally created as a separate zone/delegation and isn’t authoritative.

If you tell me the exact domain you’re querying (redact if needed: `corp.example.com`) and the exact `nslookup` output, I can identify which case it is immediately.
