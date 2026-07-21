# System Updates

System Updates covers three distinct update surfaces, each tracked and applied independently.

---

## OS Package Updates

Standard Rocky Linux `dnf` updates for everything *except* Samba. DNF's automatic security updates can also be
enabled during install, applying security patches on a schedule without manual intervention.

---

## Samba Updates

Samba is built from SRPM during install (Rocky 10's stock packaging doesn't include the AD DC role), so it's
tracked and updated separately from the rest of the OS rather than through a normal `dnf upgrade samba*`.

> RADS-WEB's own install and configuration are specifically designed to **survive an `httpd` (Apache) package
> upgrade via `dnf`**. Earlier versions edited mod_ssl's own `ssl.conf` directly to avoid a duplicate-Listen
> conflict — but `dnf` can silently replace an "untouched" package file on upgrade, discarding that edit and
> breaking Apache on the next restart. RADS-WEB no longer touches `ssl.conf` at all: its own VirtualHost simply
> avoids re-declaring the `Listen` directive `ssl.conf` already provides, and any files it does need (like a
> placeholder default certificate) are generated into their own paths instead of editing package-owned files in
> place. This was validated with a real `dnf downgrade` → `dnf upgrade` cycle against `httpd` before shipping.

---

## RADS-WEB Platform Updates

RADS-WEB's own application code — the dashboard and its backend — updates independently of both of the above,
so a new dashboard feature doesn't require (or wait on) an OS or Samba update cycle.

---

## Next Step

➡️ [System Tools](docs/sysadmin/system-tools.md)
