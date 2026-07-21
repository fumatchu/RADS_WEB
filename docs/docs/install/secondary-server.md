# Join Existing Domain

Adds this server as an additional domain controller in an AD forest that already exists — whether that forest
was provisioned with RADS-WEB or not.

---

## Prerequisites

See [Requirements](docs/install/requirements.md). You'll need:

- The **FQDN of an existing, reachable Domain Controller** in the target forest
- The **Administrator password** for that domain

```text
Before You Begin

This installs RADS-WEB and joins this server to an
existing AD forest as an additional Domain Controller.

You will need:

  1. The FQDN of an existing, reachable Domain Controller
  2. The Administrator password for that domain
```

---

## Installation Steps

1. **System Checks**, **SELinux**, **Existing Samba Check**, **Network Interface**, **IP Configuration**,
   **Hostname**, **Internet Connectivity** — same checks as a first domain controller install
2. **Validation Prerequisites** — validates the target DC is reachable and the Administrator credentials work
   *before* making any changes to this server
3. **Active Directory — Join Existing Domain** — confirms the realm/domain derived from the target DC
4. **Repository Setup**, **System Upgrade**, **Base Packages**, **VM Guest Tools**, **NTP / Chrony**,
   **Firewall**, **SELinux — Samba AD** — same environment setup as a first DC install
5. **Building Samba from SRPM** — same custom Samba build as a first DC install
6. **Samba AD Domain Join** — joins this server to the existing forest as an additional domain controller
7. **Domain Join Verification** — confirms the join succeeded and this DC is visible in the domain
8. **Forcing Initial Replication (inbound)** — replicates a fresh copy of the directory from the existing DC
   across all 5 naming contexts, rather than waiting for Samba's normal replication schedule
9. **Python / FastAPI**, **Deploy RADS-WEB Application**, **SELinux — RADS-WEB**, **TLS Certificate**,
   **Apache VirtualHost (HTTPS)**, **RADS-WEB Service**, **Fail2ban**, **RADS-WEB Update Check**,
   **Samba Update Monitor**, **DNF Automatic Security Updates**, **Login Banner** — same as a first DC install
10. **Installation Summary** and **Cleanup**

---

## A Note on Replication

Step 8 forces an *inbound* replication cycle only — this new DC pulls a fresh copy of the directory from the
existing DC. The installer does not (and cannot) force the reverse direction, since it has no remote-execute
access to the other DC.

After the join, it's worth running `samba-tool drs showrepl` on the **existing** (anchor) DC once:

```bash
samba-tool drs showrepl
```

If it shows a failed replication attempt against the new DC, restart the `samba` service there:

```bash
systemctl restart samba
```

This addresses a known Samba DRS quirk where a long-running `samba` daemon can hold a stale cached credential
for a newly-joined replication partner, causing replication to that partner to fail even though the join itself
succeeded cleanly.

---

## After Install

RADS-WEB is reachable at `https://<hostname>/` once the installer finishes, showing this server's own view of
the (now shared) directory. From the dashboard, the [Server Switcher](docs/dashboard/server-switcher.md) lets
you jump directly to any other known domain controller's own RADS-WEB dashboard.

---

## Next Step

➡️ [Directory Health](docs/dashboard/directory-health.md)
