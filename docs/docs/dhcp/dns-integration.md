# DNS / DHCP Integration

When a DHCP scope has dynamic DNS updates enabled, its leases feed directly into a paired BIND DNS zone (see
[Hybrid DNS](docs/dns/hybrid-dns.md)) — no manual record creation needed as clients come and go.

---

## Jumping Between Scope and Zone

Both directions are one click:

- From a DHCP scope card, a **DNS** button opens that scope's paired zone directly in DNS Management
- From a reverse DNS zone card, a matching button jumps back to the DHCP scope that owns it

This keeps the two screens connected without needing to remember which subnet maps to which zone.

---

## Protecting Zones In Use

RADS-WEB won't let you accidentally reuse a BIND DDNS zone that's already claimed by another scope — the zone
picker in the scope editor excludes zones already assigned elsewhere, and the backend enforces the same rule
independently of the UI.

---

## Next Step

➡️ [Sites & Services Overview](docs/sites/overview.md)
