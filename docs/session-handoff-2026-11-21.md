# Session handoff, 21 Nov 2026

Read this first if you are picking up ATAM_FLOW work. It says what was done in the last long session, what is live, what is waiting, and the working rules and traps learned. The older, broader [handoff.md](handoff.md) and [launch-checklist.md](launch-checklist.md) still apply.

## Where things are
- **Repo:** `Grobler96/ATAM_FLOW`. Work happens on the branch `oliverg/cool-archimedes-zdh5sq`; after every merge it is reset to `origin/main` and pushed (a fast-forward).
- **Supabase (live):** project `aobosyvlhgkxhjxkfzlz` (it is *named* "N8N_Daniel_Spooner"; the dashboard's `config.ts` points at it; `flow` schema). Migrations through **68** are applied.
- **n8n (live):** `atamcpi.app.n8n.cloud`. Credentials in use: `Supabase account 2` (`kMkjVWlBKm1G4EyA`), `Google Drive account` (`6MCjV2vIOBivhxC8`, signed in as the shared `ataminvoices@gmail.com` account).
- **Dashboard:** static app on GitHub Pages, rebuilt a few minutes after a merge to `main`.

## Done and merged this session (all live)
| PR | What |
|---|---|
| #45, #46 | **Orders & purchasing.** Sidebar: *All Orders*, an *In house* group with *IH Orders*, *3PD Orders* in the third-party group. **Create PO** shows the lines, splits one order into one PO per supplier from the **product catalogue**, pre-sets delivery (third-party orders straight to their decorator, others to our warehouse), opens the new PO, and **POs go live straight away** (no draft or approval; the supplier email is still queued and waits for one click). **Product catalogue** tab on Purchasing (CSV: Supplier, Item code, Cost, Preferred). **Decorator per order** (default DPS, changeable in the order drawer). Migration 67 (applied). See [purchasing.md](purchasing.md). |
| #47, #49 | Docs for the Drive artwork sync. |
| #48 | **Artwork from Google Drive.** DecoNetwork writes production files into Drive; an n8n workflow imports them. Migration 68 (applied), workflow `ATAM_FLOW · Artwork from Google Drive` (`9NPEGMStynVloDac`, **published**, every 15 minutes), a *Google Drive* tab on Artwork & Job Packs. See [artwork-drive-sync.md](artwork-drive-sync.md). |
| #55 | **Make third-party** bulk button on All Orders and IH Orders (one reason, uses the existing audited `set_scope` action; manager/admin). |
| #56 | **3PD Orders and IH Orders list every order** of that kind; a **Need buying** tab narrows them. |

## Open
- **PR #57 (draft, not merged):** Producers page renamed **3PD Producers**, moved under Settings in the menu, plus a card on the Settings page. The page address `#/producers` is deliberately unchanged (printed QR/scan links use it). Waiting for the owner to say merge.
- The owner said they have **a lot more updates to make today**; ask what is next.

## Waiting on people (not code)
- **Load the product catalogue CSV.** The catalogue only has 2 items. Until it is loaded, Create PO says items are "not in the catalogue" and asks for a supplier. Supplier names in the CSV must match a supplier name or code in Flow (ignoring case) or the whole file is refused with the problem rows listed.
- **No supplier has an email address**, so queued PO emails cannot send yet.
- **Approve the Drive files** on the Artwork screen (they arrive unapproved on purpose); a job pack stays blocked until areas are approved.
- Check the Google Drive tab for files that are *waiting* or *failed*.

## Known gaps
- Drive: worksheet PDFs are recorded but not attached to the order; no retry button for a *failed* file or place-by-hand; a Drive file only fills an existing DecoNetwork area row if the area spelling matches (otherwise it makes a new area). Matching onto an existing row has been tested locally, not yet on a live Priority Order. Only files from the last 7 days are looked at.
- The Drive login has **full Drive scope** (n8n's default) on an account that also holds invoices; read-only custom scopes (`drive.readonly`) were recommended and not yet done.
- "Make third-party" has no bulk reverse (use the order drawer, Changes & control tab).
- 3PD Orders: a decorator per order only decides PO delivery; it does not yet pre-fill the Send-to-producer dialog.

## Facts worth knowing
- Order number = `flow.orders.deco_order_id` (`order_ref` is `#` + it). Drive item folder name = `flow.order_lines.deco_line_id`. Drive file names: `order-<order>-<item>-<location>-<area>-<PROCESS>.dst`, underscores are spaces, `EMB` = embroidery.
- A manual scope setting always beats DecoNetwork's Priority flag. `flow.order_scope(o)` gives the answer.
- DecoNetwork's own artwork sync only covers **Priority Orders**.

## How to work here
- **Do not do outward or hard-to-reverse things unasked:** applying a migration to Supabase, publishing or editing a live n8n workflow, merging, sending email. The owner says "merge it", "apply the migration", "publish the workflow" when they want it. After a merge: mark the draft PR ready, merge, then unsubscribe from it.
- **Migrations:** write to `supabase/pending/`, test locally (`bash scripts/test-db.sh`; needs the Postgres 16 binaries; each feature has a suite in `supabase/tests/`), apply with the Supabase tool only when asked, then move the file to `supabase/migrations/` and update the header comment. Check live objects for name clashes first.
- **Dashboard** (`apps/dashboard`): `npm ci`, `npx tsc --noEmit -p .`, `npm test`, `npm run build`, then `npm run e2e` and `npm run e2e:portal` (mocked backend; fixtures in `e2e/exceptions.e2e.mjs`). **The e2e run rewrites `e2e/shots/*.png`: run `git checkout -- apps/dashboard/e2e/shots` before committing.** Add a browser check and a unit test for every screen change. The e2e mock does not check permissions.
- **New screen actions** either go through an n8n webhook (`exceptionActionTo('purchasing', ...)`) or call `supabase.rpc` directly on a function that checks the role inside (the catalogue and decorator changes do this). The `useView` hook reads views only. Tables remember their tab, filters and search per `storageKey`.
- **n8n:** build with the SDK (validate, then create); create workflows unpublished; archive any temporary workflow after use (e.g. the read-only Drive listings used to inspect Drive). Never print or ask for secrets or passwords; nothing secret goes in the repo.
- **Supabase SQL via the tool** runs as the owner, so `ui_*` views that call `flow.is_member()` return nothing. To see what a signed-in user sees, set the JWT inside the same statement (`set_config('request.jwt.claims', ...)` in a lateral subquery, as done to check order 636910).
- **PRs:** GitHub MCP only; open as **draft**, mirror what changed, end the body with the Claude Code line and the session link. Use the commit attribution lines the harness gives.
- **Style the owner likes:** plain words, no jargon; say plainly what was and was not tested live; offer a next step.
