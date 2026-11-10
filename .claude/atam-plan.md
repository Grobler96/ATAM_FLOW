# ATAM Flow improvement plan

Written 10 Nov 2026 from a read of the repo (docs, migrations 1-61, dashboard, CI). Nothing was changed.

## Summary

ATAM Flow is in good shape underneath: 61 migrations, 33 database test suites, a recent security audit, and a working dashboard and decorator portal. The weak spots are around the edges:

1. **Safety nets are missing.** The n8n workflows that do every write are not backed up in the repo, and the browser tests do not run automatically on pull requests.
2. **The front-page docs are out of date.** The README still says "Phase 2 in progress" and the launch checklist lists the decorator portal as "not built".
3. **Some built features have no screen.** Purchasing controls (approvals, invoice matching, chasing switch) and the holding pen exist in the database only.
4. **A few loose ends from the security audit** are still open: unlimited decorator uploads, set-up tables that can be changed without an audit record, and lists that silently stop at 5,000 rows.

The tasks below fix these in that order: safety nets first, then docs, then missing screens, then hardening.

## Ground rules for the builder

- Follow `docs/handoff.md` (standing rules, patterns, pitfalls). No emails are sent. No changes to shared Supabase Auth settings or to non-`flow` tables.
- New migrations start at 62. Write the migration and its test in the repo; **do not apply any migration to the live database, and do not edit or publish any live n8n workflow, without asking the owner first.**
- Run the relevant tests after each task (`scripts/test-db.sh`, `npm test`, `npm run build`, e2e).
- Anything not yet usable must be visibly disabled with a reason, never faked.

## Tasks

- [ ] Export the published n8n workflows (the seven action workflows, Verify caller, Exception detector, Sync priority flags) into `n8n/workflows/` as JSON with secrets stripped, read-only on n8n, passing `scripts/check-n8n-exports.mjs`
- [ ] Add a short "how to restore a workflow from the repo" section to `docs/n8n-workflows.md`
- [ ] Add the two browser test runs (`npm run e2e`, `npm run e2e:portal`) to `.github/workflows/ci.yml` so every pull request runs them
- [ ] Rewrite the README status line and layout table to match today (live, third-party launch, portal, 61 migrations) and link `docs/handoff.md` and `docs/launch-checklist.md`
- [ ] Bring `docs/launch-checklist.md` up to date: move the decorator portal and other finished items out of "Not built", re-date it, and keep one clear "Needs you before real use" list
- [ ] Tidy `docs/assumptions-and-open-questions.md`: remove the finished deployment steps and the reference to `supabase/pending/`, which no longer exists
- [ ] Purchasing screen: add "Approve" with a required reason to the PO drawer, showing why a PO needs approval and who may approve it (uses the existing migration 58 functions)
- [ ] Purchasing screen: add invoice entry and matching to the PO drawer, showing matched, over and under amounts against the tolerance
- [ ] Settings page: show the purchasing rules (approval limit, tolerances) and the scheduled-chasing switch, with chasing visibly disabled and the reason "no emails yet"
- [ ] Add e2e coverage and screenshots for the new purchasing approval and invoice screens
- [ ] Update `docs/purchasing.md` and `docs/handoff.md` to say the purchasing screens now exist
- [ ] Holding pen screen: a read-only list of orders in the pen with the reason each is held, linked from the sidebar and from the order drawer
- [ ] Add e2e coverage for the holding pen screen and note it in `docs/scope-control.md`
- [ ] Show a visible warning on any table that reaches the 5,000-row load limit, so a cut-off list is never mistaken for a complete one
- [ ] Migration 62 with a test: cap how many files and how much total size a decorator can upload per job (repo only, not applied live)
- [ ] Migration 63 with a test: add audit-trail triggers to the set-up tables that can still be written directly (machines, bins, settings, producers, suppliers, roles) (repo only, not applied live)
- [ ] Quality page: allow a photo to be uploaded from the device for a QC check instead of a link only, stored in the existing evidence bucket with a test
- [ ] Final pass: run every test suite, update `docs/handoff.md` with what changed and what is waiting to go live, and list the migrations that need the owner's go-ahead

## Not in this plan: needs the owner, not the builder

These block real use but cannot be done by writing code:

- Enter the real decorators (producers) and their rates. There are none yet.
- Give each of the 10 staff logins the right role. Everyone is an admin today.
- Add supplier email addresses.
- Do the two real sign-in checks from the security audit before inviting any real decorator.
- Confirm the real QC checklist items, press speeds and shift hours.
- Decide whether n8n webhooks should get a rate limit (it means editing live workflows).
- Longer term: move decorators to their own Supabase project, or tighten ATAM GO's "any signed-in user" rules.
