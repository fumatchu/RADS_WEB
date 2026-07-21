# Forward & Reverse Zones

---

## Zone List

Zones are grouped into two cards — **Forward Zones** and **Reverse Zones** — each showing a live count and a
green status dot. Every zone shows its name and a **Samba** badge (or a distinct badge if it's a
[Hybrid DNS](docs/dns/hybrid-dns.md) zone managed by BIND instead).

---

## Per-Zone Actions

| Action | What it does |
|---|---|
| **Records ▾** | Browse the records in this zone |
| **Add Record** | Create a new record (A, AAAA, CNAME, PTR, SRV, TXT, etc. depending on zone type) |
| **Refresh** | Reload this zone's records |
| **Validate ▾** | Run validation checks against the zone |
| **Delete** | Remove the zone |

---

## Searching

The search box at the top of the page filters across zones and records at once — useful once a domain has more
than a handful of zones.

---

## Adding a Zone

**+ Add Zone** on either the Forward Zones or Reverse Zones card opens a form scoped to that zone type.

---

## Next Step

➡️ [Hybrid DNS](docs/dns/hybrid-dns.md)
