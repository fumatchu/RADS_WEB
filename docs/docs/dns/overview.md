# DNS Overview

RADS-WEB manages Samba's AD-integrated DNS server directly — the same DNS service every domain controller runs
to resolve the domain and locate other DCs, GC servers, and Kerberos KDCs via SRV records.

---

## Where It Lives

The DNS Management page shows a **Samba Internal** badge by default, confirming zones are stored in Active
Directory itself (not a flat-file BIND config) and replicate along with the rest of the directory via DRS.

---

## What You Can Do

- Create, view, and delete forward and reverse zones
- Add, edit, and delete DNS records within a zone
- Validate a zone
- Search across zones and records

See [Forward & Reverse Zones](docs/dns/zones.md) for the zone management screen, and
[Hybrid DNS](docs/dns/hybrid-dns.md) for layering standalone BIND-managed zones alongside Samba's.

---

## Next Step

➡️ [Forward & Reverse Zones](docs/dns/zones.md)
