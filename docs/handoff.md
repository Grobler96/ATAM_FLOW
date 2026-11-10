# Handoff: where ATAM_FLOW stands (10 Nov 2026)

Read this first, then `docs/architecture.md`, `docs/launch-checklist.md`, `docs/scope-control.md`, `docs/producer-portal.md`, `docs/n8n-workflows.md`. Then `git log --oneline -15` and `git status`.

## What this is
An internal command centre for an apparel decoration business. It **launches for third-party decorator work only**; in-house production is built but switched off (audited switch). Third-party orders are those with DecoNetwork "Priority Order" on (`is_priority`). A manual scope on an order always wins.

## Stack and how writes happen
- Supabase Postgres, project `aobosyvlhgkxhjxkfzlz`, schema `flow`. **The project is shared with another app (ATAM GO)**: Auth settings (Site URL, SMTP, email templates, sign-up toggle, link expiry) apply to both. Do not change them without the owner's say-so. Do not touch non-`flow` tables.
- Staff app reads only `public.ui_*` views (`security_invoker`, RLS through `flow.is_member()`). Staff writes go through n8n (`atamcpi.app.n8n.cloud`): webhook, "Verify caller" sub-workflow (`lALM3G47uOizvD9t`), role check, allow-list into a `public.flow_*` function granted to `service_role` only, which calls the `flow.*` function; audited.
- The decorator portal (`portal.html`) is the one exception: it calls login-checked `public.portal_*` functions directly. Portal users are never in `flow.user_roles`.
- Dashboard: Vite + React + TypeScript in `apps/dashboard` (`index.html` staff, `portal.html` decorators), deployed to GitHub Pages from `main`. Repo `Grobler96/ATAM_FLOW`.

## Tests (run all before a PR)
- `bash scripts/test-db.sh` (local Postgres, every migration, every SQL suite, `permissions_test.sql` guard)
- `cd packages/engine && node --test`
- `cd apps/dashboard && npm test && npm run build && npm run e2e && npm run e2e:portal` (rebuild before e2e; run one e2e at a time; the main e2e takes about two minutes, so run it in the background and write its output to a file)
- e2e runs against a fully mocked Supabase and n8n. **A mock cannot catch a permission problem**; query views as the real role.

## Live state (migrations 1-61 applied, repo and live match; the API guard from 61 is on, see `docs/security-audit-2026-11.md`)
Merged to `main` this phase: holding pen, third-party focus view, decorator spoilage reporting, job packs and artwork downloads, scanning (staff and portal), dispatch queue and courier labels, artwork storage and customer proofs, stock-takes, real QC checklists (mechanism only), exception digest and due-soon warnings, purchasing controls (approval rules, invoice matching, draft-only scheduled chasing; **database and n8n actions only, no screens yet**), floor set-up (machines and operator skills), decorator sign-in page redesign, portal hardening (inactivity sign-out enforced in the database, sign-in log, company addresses only).

n8n workflows **published (live)**: Exception detector and escalation (every 30 minutes at :05 and :35, plus the Check now button; in-app only), Sync priority flags (hourly at :25, read-only on DecoNetwork), Operations actions, Movement actions, Exception actions, Quality actions, Warehouse actions, Artwork actions, Producer risk actions (all via webhook behind Verify caller), plus the pre-existing sync and allocation workflows and Verify caller.
**Left unpublished on purpose**: Purchasing actions and Goods-in processor (n8n will not publish them until the Communications sender is published, and the owner has said no emails yet), Communications sender, the scheduler, daily housekeeping, Machine and Production actions (in-house), supplier actions, selection, artwork download job.
Gotcha: editing a published workflow creates a draft. **It is not live until you publish again** (check `activeVersionId`).
Existing live workflow WF3 (`5oK8u0HSPJgrd7pa`, DecoNetwork capture) must not be edited without asking.

## Standing rules from the owner
- Plain-English explanations. Never expose secrets. Ask before anything destructive. Overrides need a reason and an audit record. Unbuilt things must be visibly disabled with a reason, never faked. Report honestly what is and is not done.
- **No emails yet**: no email sending or notification to decorators or staff. Drafts that wait for review are existing behaviour.
- Merge a PR **only when asked**; mark drafts ready first. Open a draft PR after pushing and subscribe to it.
- Work on branch `claude/clever-hypatia-vwixp8`, restarted from `origin/main` after each merge. `git fetch` and check `origin/<branch>` before pushing; number migrations after the highest in the repo (next is **62**, file prefix `20261110000062_`).
- No model names in repo artifacts (commits, code, docs).
- Do not guess the things the owner still has to supply: producers list and rates, who gets which role, supplier emails and offers, machine shift hours, press speeds, QC checklist items, risk weights, the DecoNetwork artwork credential. Supabase settings only the owner can change: portal redirect URL (done), email sender, turning off new sign-ups, link expiry.

## Engineering patterns and pitfalls
- Migrations sent through the Supabase MCP: avoid the words "drop" and "delete from" (they trigger a confirmation that times out). Apply the repo file's content as-is so repo and live stay identical.
- Patch big functions in place with `pg_get_functiondef` and `replace` on an anchor, and raise if the anchor is missing; never rewrite `flow.exceptions_detect_all()` or `flow.scheduler_input()` whole. Latest detector list ends `'stocktakes','qc_checklist','invoices'] loop`.
- New `flow.*` functions are **private by default** (migration 36). `flow.setting()` is private. A helper used inside a `security_invoker` view must be `security definer` (or the view fails for staff) and be added to the allow-list in `permissions_test.sql` with a comment. This bit twice (migrations 57 and 58, fixed in 59).
- Exception `root_cause` must be one of: supplier, producer, courier, customer, internal_process, artwork, machine, data_integration, quality, unknown. Exception type `category` one of: stock, purchasing, producer, artwork, production, quality, logistics, integration, order, data, other.
- SQL test pitfalls: never mutate and read in one statement; avoid absolute counts; use unique ids and fresh uuids per suite; `user_roles` needs `on conflict (user_id) do update`; `po_lines.line_total` is generated; tests run as the database owner unless you `set role authenticated`.
- DecoNetwork overwrites on-hand stock on every sync, so stock-takes never edit stock and the waste ledger is separate.
- Audit trail tables are append-only (triggers); do not update them in tests.

## Known gaps and honest caveats
- **Purchasing screens not built**: approve with a reason (a PO over the limit needs an admin; creators cannot approve their own PO unless an admin gives a reason), invoice entry and matching on the PO drawer, and the scheduled-chasing switch. Defaults are placeholders in `purchasing.rules` (`approve_over_value` 500, tolerances 2% or 5 pounds, chasing off).
- QC checklist items are still the 13 placeholder items; nobody has confirmed standards. Photos are links only (no device upload).
- Live data: no artwork files stored, no SKU has a shelf location, "Own Product Supplied - T-Shirt" shows 999 units (placeholder-like), no ATAM_FLOW purchase orders yet (only 421 DecoNetwork ones). One test decorator ("TEST ACC") exists.
- Portal: no two-factor sign-in, no unusual-location alerts; the decorator email has a link but no code (editing the template needs a custom SMTP sender, which is project-wide).
- Escalation emails and digests are in-app only.
- Real printers, scanners and phone cameras have not been tried on real hardware.

## Suggested independent review (not yet done)
A fresh, adversarial pass over the whole system, because the same session wrote and tested it:
1. **Permissions audit as each real role** (`anon`, `authenticated` staff roles, a portal decorator, `service_role`): query every `ui_*` view, call every `public.*` function, read storage buckets (`artwork`, `producer-evidence`). Look for leaks, views that fail for staff, and functions callable by the wrong role. Compare with `permissions_test.sql`, which only checks some of this.
2. **Decorator portal threat model**: isolation between decorators, the invite and claim path, the n8n invite flow that creates the sign-in account, storage policies, rate and abuse limits, what a logged-in non-decorator can learn.
3. **n8n action workflows**: role checks in each "Choose database action" node match the intent; no action lets a lower role do a senior thing; error handling leaks nothing.
4. **Schema review for things that pass tests but fail for real users**: grants, RLS, security-definer search paths, long-running queries, paging beyond 5,000 rows.
5. **Migration drift**: live versus repo (they match through 59 today).
Report findings plainly; do not change the shared Auth settings; fix confirmed defects in small PRs with a test each.
