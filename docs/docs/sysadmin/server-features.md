# Server Features

Enable and configure optional server roles that run alongside Samba AD on this box — DNS (always present, as
part of Samba), and DHCP (Kea) when this server is also acting as the network's DHCP provider.

---

## Enabling DHCP

Turning on the DHCP feature installs and configures Kea DHCP4, then hands off to
[Scopes & Leases](docs/dhcp/scopes-leases.md) for day-to-day scope management.

---

## Next Step

➡️ [System Updates](docs/sysadmin/system-updates.md)
