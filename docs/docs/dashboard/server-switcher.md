# Server Switcher

The FQDN pill in the header (e.g. `FQDN rads50.test.int (this server)`) doubles as a quick way to jump between
domain controllers without remembering hostnames.

---

## How It Works

Click the pill and a dropdown opens listing every other known domain controller — pulled from AD's Sites
topology, the same source used elsewhere in the app. Each row shows the DC's name and its site.

Click a row and your browser navigates directly to that DC's own RADS-WEB dashboard (`https://<that DC>/`) —
a plain link-out, not a data fetch. You'll sign in there independently; each RADS-WEB instance is its own
self-contained dashboard for the server it runs on.

---

## Why Not a Unified Fleet View?

An earlier design considered pulling live data from every DC into one combined dashboard (an "API fan-out").
That's a meaningfully bigger feature — it needs each DC's dashboard to expose data to the others, with its own
authentication story between peers — and was deliberately scoped down for now in favor of this simpler,
zero-new-infrastructure link-out. See the note on peer checks in
[Directory Health](docs/dashboard/directory-health.md) for the same reasoning.

---

## Next Step

➡️ [Users & Groups](docs/ad/users-groups.md)
