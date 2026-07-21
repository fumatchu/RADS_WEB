# Hybrid DNS

An optional mode that layers standalone BIND-managed zones alongside Samba's AD-integrated ones — most useful
for dynamic-DNS zones fed by DHCP leases, which don't need (and shouldn't have) full AD replication overhead.

---

## Enabling It

The **Enable Hybrid DNS** button on the DNS Management page switches this server into hybrid mode. This is a
one-way migration — reverting to Samba-only DNS afterward requires manual steps, so enable it deliberately
rather than experimentally.

---

## How Zones Are Distinguished

Once enabled, the zone list merges both sources:

- Zones with a **Samba** badge live in Active Directory and replicate via DRS, same as always
- Zones without it are BIND-managed — typically dynamic-DNS zones that DHCP leases populate automatically as
  clients get addresses

Reverse zones created automatically by a DDNS-enabled DHCP scope appear here too, linked back to their parent
forward zone.

---

## DHCP Integration

A DHCP scope configured for dynamic DNS updates writes directly into its paired BIND zone as leases are
issued and released. See [DNS / DHCP Integration](docs/dhcp/dns-integration.md) for jumping between a scope and
its zone.

---

## Next Step

➡️ [DHCP Overview](docs/dhcp/overview.md)
