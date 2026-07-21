# System Monitor

The bell icon in the header is a single place that surfaces anything on this server needing attention, pulled
together from every other part of the dashboard.

---

## What Feeds the Monitor

| Source | Severity | Example |
|---|---|---|
| A monitored service down | 🔴 Red | Samba, DNS, DHCP, Firewall, or Fail2Ban not running |
| An unreachable peer DC | 🔴 Red | Another known domain controller failing DC Ping and/or Kerberos |
| Not authenticated to AD | 🔴 Red | No active Kerberos ticket for the signed-in session |
| Resource usage critical | 🔴 Red | CPU, memory, or disk over the critical threshold |
| A running service blocked by the firewall | 🟡 Yellow | e.g. DHCP is running but its port isn't open |
| Resource usage elevated | 🟡 Yellow | A resource over the warning (but not critical) threshold |
| Reboot required | 🟡 Yellow | A previous update needs a reboot to fully take effect |
| A replication issue | 🟡 Yellow | A DRS partner reporting consecutive failures |

A peer DC being fully unreachable is treated with the same severity as a local service being down — both turn
the bell red — while a replication hiccup (which is often transient and self-heals on the next replication
cycle) stays yellow.

---

## Clicking Through

Every row in the dropdown is clickable and takes you straight to the relevant page — a blocked service opens
System Tools with that service highlighted, a replication issue opens Sites & Services → Replication, an
unreachable peer opens the Dashboard.

---

## When Everything's Fine

If nothing needs attention, the dropdown simply reads:

```text
✓ All monitored services are running.
```

---

## Next Step

➡️ [Server Switcher](docs/dashboard/server-switcher.md)
