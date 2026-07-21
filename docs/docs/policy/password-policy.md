# Password Policy & PSOs

---

## Domain Default Password Policy

The domain-wide password policy — minimum length, complexity, history, lockout threshold, and age — applies to
every account unless overridden by a fine-grained policy below.

---

## Fine-Grained Password Policies (PSOs)

PSOs let you apply a *different* password policy to specific users or groups — for example, a stricter policy
for administrative accounts than the domain default.

- **+ New PSO** — create a fine-grained password policy and assign it to users or groups
- **↻ Refresh** — reload the PSO list

When more than one PSO applies to the same user (directly or through group membership), AD resolves the
conflict using each PSO's precedence value — RADS-WEB shows this so it's clear which policy actually wins for
a given account.

---

## Next Step

➡️ [Generate RSAT File](docs/sysadmin/rsat.md)
