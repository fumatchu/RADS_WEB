# Computers

Browse computer objects joined to the domain, including the domain controllers themselves.

---

## The Computers List

- **+ Add Computer** — pre-stage a computer account
- **↻ Refresh** — reload from AD
- Search — filter by name
- OS pills — filter the list by operating system, once computers have reported theirs

Select multiple computers to reveal a bulk **Delete** action.

---

## FSMO Roles (from a Computer)

Domain controller computer objects have quick access to the same FSMO Roles view found under
[Sites & Services](docs/sites/fsmo-roles.md) — transfer or seize a role directly from a DC's computer entry
without switching tabs.

---

## Demoting a Domain Controller

A domain controller's computer entry also exposes a **Demote** action, for permanently removing a DC from the
forest. RADS-WEB checks FSMO role placement first — you can't demote a DC that's still holding roles without
either transferring them first or explicitly seizing them elsewhere. A force-demote/cleanup path exists for a
DC that's already offline and needs to be removed from AD's metadata without being reachable itself.

---

## Next Step

➡️ [CN / OU](docs/ad/cn-ou.md)
