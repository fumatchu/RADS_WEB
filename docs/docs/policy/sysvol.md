# SYSVOL

SYSVOL is the shared folder every domain controller replicates, holding Group Policy templates and (by
default) logon scripts. RADS-WEB's Directory Health card checks that SYSVOL is present and readable as part of
this server's core health checks — a missing or unreadable SYSVOL almost always means something is wrong with
this DC's replication or with the underlying `samba` service.

---

## What This Tab Shows

The SYSVOL tab gives visibility into the SYSVOL share itself, complementing the Group Policy Objects tab, which
manages the *policy content* stored inside it.

---

## Next Step

➡️ [Password Policy & PSOs](docs/policy/password-policy.md)
