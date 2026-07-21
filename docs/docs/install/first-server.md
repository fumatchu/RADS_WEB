# First Domain Controller

Provisions a brand-new Active Directory forest on this server, using Samba built from SRPM (Rocky 10's stock
Samba packaging doesn't include the AD DC role), and deploys the RADS-WEB dashboard on top of it.

---

## Prerequisites

See [Requirements](docs/install/requirements.md). You'll be prompted for:

- **AD Realm** — e.g. `TEST.INT` (the installer suggests this server's own domain suffix as a default)
- **Administrator password** — minimum 8 characters, entered twice to confirm
- **NTP server** — an IP or FQDN, or press Enter to use `pool.ntp.org`

---

## Installation Steps

1. **System Checks** — confirms root access and Rocky Linux 10.0+
2. **SELinux** — checks current SELinux status/mode
3. **Existing Samba Check** — confirms Samba isn't already running on this box
4. **Network Interface** — detects the active interface
5. **IP Configuration** — offers to set a static IP if the interface is on DHCP
6. **Hostname** — validates/sets the server's hostname
7. **Internet Connectivity** — confirms outbound access before continuing
8. **Active Directory Configuration** — collects the realm, Administrator password, and NTP server
9. **Repository Setup** — enables EPEL and `dnf-plugins-core`
10. **System Upgrade** — runs a full `dnf upgrade`
11. **Base Packages** — installs required OS packages
12. **VM Guest Tools** — installs guest tools if running in a supported hypervisor
13. **NTP / Chrony** — configures time sync against the chosen NTP server
14. **Firewall** — opens the ports Samba AD and RADS-WEB need
15. **SELinux — Samba AD** — sets SELinux booleans/contexts for the AD DC role
16. **Building Samba from SRPM** — compiles a Samba AD DC-capable package for Rocky 10
17. **Samba AD Provisioning** — provisions the new forest with the realm/password collected earlier
18. **Active Directory Verification** — confirms the new domain is up and answering
19. **Python / FastAPI** — installs the Python runtime RADS-WEB's backend needs
20. **Deploy RADS-WEB Application** — downloads and installs the RADS-WEB application package
21. **SELinux — RADS-WEB** — sets SELinux contexts for the app
22. **TLS Certificate** — generates a self-signed certificate for HTTPS
23. **Apache VirtualHost (HTTPS)** — configures the reverse proxy in front of the RADS-WEB backend
24. **RADS-WEB Service** — installs and starts the systemd service
25. **Fail2ban** — configures brute-force protection
26. **RADS-WEB Update Check** — installs the periodic update checker
27. **Samba Update Monitor** — installs Samba-specific update monitoring
28. **DNF Automatic Security Updates** — enables automatic OS security patching
29. **Login Banner** — sets a console login banner
30. **Installation Summary** — prints a final report
31. **Cleanup** — removes temporary install artifacts

---

## Confirmation Screen

Before provisioning, the installer shows a summary and asks for confirmation:

```text
Provision Active Directory with these settings?

Realm:   TEST.INT
Domain:  TEST
DC FQDN: rads01.test.int
NTP:     pool.ntp.org
```

Review this carefully — the realm cannot be changed after provisioning without rebuilding the domain.

---

## After Install

RADS-WEB is reachable at `https://<hostname>/` once the installer finishes. Sign in with the `Administrator`
account you set during provisioning.

If you plan to add more domain controllers, continue with [Join Existing Domain](docs/install/secondary-server.md)
on the next server.

---

## Next Step

➡️ [Join Existing Domain](docs/install/secondary-server.md)
