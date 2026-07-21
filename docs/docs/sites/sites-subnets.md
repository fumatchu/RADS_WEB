# Sites & Subnets

---

## Sites

Each AD site is shown as its own card. RADS-WEB adds a row of green **FQDN pills** on every site card, listing
which domain controllers currently belong to that site — so you can see placement at a glance without opening
[Domain Controllers](docs/sites/domain-controllers.md) separately.

A brand-new forest starts with a single site, `Default-First-Site-Name`. RADS-WEB displays this as **Default
Site** in most places for readability, while the underlying AD object name is unchanged.

---

## Subnets

The Subnets tab maps IP subnets (in CIDR form) to the site that owns them. This is what tells a client — or
another domain controller — which site it belongs to based on its IP address, and drives which DC it prefers
to talk to.

---

## Next Step

➡️ [Site Links](docs/sites/site-links.md)
