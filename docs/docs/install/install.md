# Install Guide

This section walks through deploying RADS-WEB, from a bare Rocky Linux install to a working dashboard.

---

## Overview

The installation process consists of:

1. Reviewing [Requirements](docs/install/requirements.md)
2. Running the bootstrap installer
3. Choosing an install type — a first domain controller, or joining an existing forest
4. Letting the installer provision Samba AD (or join an existing domain) and deploy RADS-WEB

---

## Start the Installer

As root, on the server you're installing:

```bash
curl -fsSL https://raw.githubusercontent.com/fumatchu/RADS_WEB/main/RADS_WEB-Installer.sh | bash
```

The bootstrap script:

- Confirms you're running as root, on Rocky Linux 10.0+
- Installs a handful of small dependencies (`wget`, `git`, `ipcalc`, `dialog`)
- Clones the RADS_WEB repository
- Launches the main installer, which asks which kind of install this is

---

## Choose an Install Type

```text
Select Installation Type

1) Install First Domain Controller (new AD forest)
2) Join Existing AD Forest (additional Domain Controller)
```

- **Install First Domain Controller** — provisions a brand-new AD forest on this server. Use this for the very
  first RADS-WEB server in your environment.
  ➡️ [First Domain Controller](docs/install/first-server.md)

- **Join Existing AD Forest** — adds this server as an additional domain controller in a forest that already
  exists (perhaps installed with RADS-WEB previously, or an existing Samba/Windows AD forest).
  ➡️ [Join Existing Domain](docs/install/secondary-server.md)

---

## Recommended Approach

- Use a clean, minimal Rocky Linux install
- Assign a static IP address before or during install
- Ensure internet access is available for the duration of the install
- Avoid installing additional packages before running the RADS-WEB installer — let it manage its own
  dependencies so nothing conflicts with the Samba AD build

---

## After Install

Once the installer finishes, RADS-WEB is reachable over HTTPS at the server's hostname (a self-signed
certificate is generated automatically — your browser will warn once, which is expected). Sign in with the
domain `Administrator` account to authenticate against Active Directory and unlock the dashboard.

---

## Next Step

➡️ Begin with: **Requirements**, then pick your install type above.
