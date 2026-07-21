# Replication

A live view of DRS (Directory Replication Service) health between this domain controller and every partner it
replicates with directly, plus a one-click way to force a fresh replication cycle on demand.

---

## The Diagram

Each domain controller is drawn as its own node, labeled with its name and its site. A line connects two DCs
that replicate directly with each other, labeled with:

- Both sites involved (not just the resolved site link's own name — showing both ends makes it obvious at a
  glance which sites are talking, even when one of them is still the default site)
- A live status pill — green when healthy, red with a failure count when not

Hover a line to see the actual [site link](docs/sites/site-links.md) name, cost, and replication interval that
governs it (or that it's an intra-site link, which has no site link object of its own).

---

## Issue Banner

If any partner is reporting a problem, a banner appears above the diagram:

```text
⚠ 1 replication issue found
RADS50 ↔ RADS51: 1 consecutive failure(s) — replication attempt failed
```

This same data feeds the Replication row on the [Directory Health](docs/dashboard/directory-health.md) card and
the red/yellow escalation on the [System Monitor](docs/dashboard/system-monitor.md) bell — all three read from
one source, so they can never disagree with each other.

---

## Force Replication

The **⚡ Force Replication** button next to Refresh triggers an on-demand inbound DRS replication cycle against
every current partner, across all 5 standard naming contexts (domain, configuration, schema, and both DNS
application partitions). It's the same operation the installer runs on first join, just available whenever you
need it afterward.

When it finishes, a toast reports per-partner results:

```text
Replication forced successfully — RADS51: 5/5 OK
```

and the diagram/banner reload immediately so a cleared failure count shows right away, instead of waiting for
the next automatic poll.

> Force Replication only pulls **inbound** (this DC ← partner) — there's no remote-execute access to force a
> partner's own outbound side. If a partner needs the same treatment, run it from that partner's own dashboard.

---

## Why a Cleared Network Issue Doesn't Always Clear the Banner Instantly

Samba tracks a partner's `consecutiveFailures` counter as part of the replication metadata itself, and that
counter is **sticky** — it only resets to 0 once a replication attempt actually *succeeds*, not simply because
the partner becomes reachable again. If a DC was briefly down, DC Ping and Kerberos checks on
[Directory Health](docs/dashboard/directory-health.md) will show green again immediately (they're live checks,
recomputed every poll), while the Replication row can stay red until the next replication cycle actually
completes. Force Replication is the fastest way to trigger that cycle on demand rather than waiting.

---

## Next Step

➡️ [Group Policy Objects](docs/policy/gpo.md)
