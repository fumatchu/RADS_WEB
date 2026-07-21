# Site Links

Site links define the replication transport between two or more sites — the cost, schedule, and replication
interval AD's KCC (Knowledge Consistency Checker) uses when building the actual replication topology.

---

## What's Shown

Each site link lists the sites it connects, its **cost** (lower cost is preferred when more than one path
exists between two sites), and its **replication interval**.

---

## Where This Shows Up Elsewhere

The [Replication](docs/sites/replication.md) diagram labels each connecting line with the site link governing
it (or **Intra-site** when both domain controllers share a single site, since same-site replication is
KCC-managed automatically and has no site link object of its own) — hover a line there to see the exact link
name, cost, and interval without leaving the diagram.

---

## Next Step

➡️ [Domain Controllers](docs/sites/domain-controllers.md)
