# FSMO Roles

The five Flexible Single Master Operations roles — PDC Emulator, RID Master, Schema Master, Domain Naming
Master, and Infrastructure Master — are each held by exactly one domain controller at a time. This tab shows
current holders and lets you move them.

---

## Transfer vs. Seize

| Action | When to use it |
|---|---|
| **Transfer** | The current holder is online and reachable — a graceful, coordinated handoff |
| **Seize** | The current holder is permanently offline and will not come back — a forced takeover |

> **Seizing is a last resort.** After a seize, the previous holder must be demoted (or, if truly gone,
> removed from AD's metadata) before it can ever come back online — bringing back a seized-from DC without
> demoting it first can corrupt the directory.

---

## Making a Change

Select a target domain controller from the dropdown for the role you want to move, then Transfer or Seize.
RADS-WEB shows an in-app confirmation before either action — nothing happens on a single click.

Both actions authenticate using the same Kerberos ticket as the rest of Active Directory management; no
separate credentials are needed.

---

## Where Else This Appears

The same FSMO view is also reachable from a domain controller's entry under
[Computers](docs/ad/computers.md), for a quicker path when you're already looking at that machine.

---

## Next Step

➡️ [Replication](docs/sites/replication.md)
