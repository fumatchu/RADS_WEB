# Directory Health

The Directory Health card is the first thing you see on the Dashboard — a real-time summary of this server's
AD/Samba health, plus reachability of every other known domain controller.

---

## This Server's Tiles

| Tile | What it checks |
|---|---|
| Samba DC | Whether the `samba` systemd service is running |
| Chrony NTP | Current clock offset from this server's configured NTP source |
| DC Ping | A live CLDAP query confirming the local DC responds |
| Kerberos | Whether the KDC is listening on port 88 |
| SYSVOL | Whether the SYSVOL policy share is present and readable |

Each tile shows a green or red status dot. A red dot on **DC Ping** or **Kerberos** almost always means the
`samba` service itself is down — those two checks are the fastest way to notice Samba has stopped.

---

## FSMO Role Cards

Below the tiles, five cards show the current holder of each FSMO (Flexible Single Master Operations) role:
PDC Emulator, RID Master, Schema Master, Domain Naming Master, and Infrastructure Master. See
[FSMO Roles](docs/sites/fsmo-roles.md) for transferring or seizing these.

---

## Replication

A Replication row shows this server's DRS replication status with each partner it replicates with directly,
including a consecutive-failure count when a link is unhealthy. This section pulls from the same data as the
[Replication](docs/sites/replication.md) diagram under Sites & Services, so the two can never disagree.

> If replication shows an issue, the overall Directory Health badge escalates from **HEALTHY** to **DEGRADED**
> even if every individual tile above is green — a real DRS problem should never hide behind an otherwise-clean
> health card.

---

## Other Domain Controllers

Below your own status, RADS-WEB shows a card **per other known domain controller** — pulled from AD's own Sites
topology, not a manually-maintained list. Each card includes:

- That DC's own **DC Ping** and **Kerberos** status, probed directly from this server over the network (a plain
  CLDAP query and a TCP connect to port 88 — no API call to that DC's own RADS-WEB instance, no new
  authentication)
- Its **replication link(s)**, in the same style as your own Replication row

Click any peer card to open that DC's own RADS-WEB dashboard directly.

> **Why only Ping and Kerberos for peers?** Those two checks are simple network-reachability probes this server
> can run against any host. Checks like "Samba service running" or "Chrony offset" are local-only observations —
> only the remote box's own RADS-WEB backend can report on those. Extending *those* to a full fleet view would
> need each DC's dashboard to expose data to the others (a peer API), which is intentionally out of scope for
> now — see [System Monitor](docs/dashboard/system-monitor.md) for how issues on any peer still surface.

---

## Overall Badge

The badge in the card header reflects the worst state across every check on the card:

| Badge | Meaning |
|---|---|
| **HEALTHY** | Everything checked is green |
| **DEGRADED** | A real issue was found (e.g. a replication problem), but the server is still functioning |
| **CRITICAL** | Multiple core checks (DC Ping, Kerberos, SYSVOL, Time Sync) are failing |

---

## Next Step

➡️ [System Monitor](docs/dashboard/system-monitor.md)
