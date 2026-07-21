# Scopes & Leases

---

## DHCP Scopes

Each scope card lets you configure the subnet's range, routers, DNS servers, lease time, and other Kea options,
then **Save Scope** to apply the change. Kea picks up scope changes without needing a full service restart for
most edits.

---

## Active Leases

Below the scopes, an **Active Leases** table shows every current lease — client IP, MAC address, hostname (if
known), and expiration. Use the subnet dropdown to filter leases down to one scope, and **⟳ Refresh** to pull
the latest state from Kea.

---

## Next Step

➡️ [DNS / DHCP Integration](docs/dhcp/dns-integration.md)
