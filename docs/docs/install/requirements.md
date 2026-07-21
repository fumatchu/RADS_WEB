# Requirements

---

## Operating System

RADS-WEB installs onto a fresh **Rocky Linux 10.0+** server. The bootstrap installer checks this before doing
anything else and refuses to continue on an older release.

---

## Access

- Root access (the installer must be run as `root`)
- Working internet connectivity — the installer enables EPEL and other repos, runs a full `dnf` upgrade, and
  downloads the RADS-WEB application package from GitHub Releases

---

## Hardware

RADS-WEB runs comfortably on modest hardware — a Samba AD DC with the RADS-WEB dashboard, DNS, and (optionally)
DHCP does not need much more than a typical small-office domain controller would. Both physical and virtual
machines are supported; the installer detects VM guests and installs the appropriate guest tools automatically.

---

## Network

- A static IP address is strongly recommended. If the interface is on DHCP, the installer will offer to
  configure a static address as part of setup.
- A resolvable hostname/FQDN for the server.
- If this server is **joining an existing forest**, it needs network reachability to that forest's existing
  domain controller (DNS, LDAP, Kerberos, and RPC ports) before the join step will succeed.

---

## What You'll Need on Hand

| Install type | You'll need |
|---|---|
| First Domain Controller | The AD realm/domain name you want to provision, and an Administrator password (min. 8 characters) |
| Join Existing AD Forest | The FQDN of an existing, reachable domain controller, and the Administrator password for that domain |

---

## Next Step

➡️ [Install Guide](docs/install/install.md)
