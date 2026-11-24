# Update log (built 24 Nov 2026; migration 86 applied 24 Nov 2026)

Daniel asked for the same update log that ATAM GO has: one place that lists every change made to the system, and where the team can suggest what to build next.

## What it is
- **Page:** `Control` menu > `Update log` (`#/update-log`, keyboard `g` then `5`). Two tabs: **Timeline** and **Suggestions**.
- **Timeline:** every change newest first (v1 is the foundation, seeded from the real pull request history, v36 is the log itself). Each entry has a status (Live, Partly live, Built waiting to go live), a plain summary, a "Done by Oliver" line (everything is credited to the owner, nothing else is named), what changed, and what to check if it goes wrong. Search, status and area filters, and a "something broke, it started failing around…" date finder that highlights the changes from the 3 days before (work that is only built, or in progress, is never a suspect). A "Coming up" list shows planned work.
- **The timeline lives in the code, not the database:** `apps/dashboard/src/data/updatelog.ts`. It only changes when a pull request is merged. **Every change adds an entry at the top, in the same pull request** (rule in `docs/handoff.md`). Never delete an entry. No times or time limits are recorded on entries. Say plainly what is live and what still waits on a migration or a publish.
- **Suggestions:** anyone on the team (any role) adds an idea and rates every idea 1 (nice to have) to 5 (needed now). One rating per person per idea; pressing your own rating again takes it back. Ranked by points (all ratings added up), then newest. The owner of an open suggestion can take it back. **Managers and admins** set Open, Planned, Built or Declined from the page (audited). "Download list" gives a CSV so the whole list can be handed to future developers. Built and Declined suggestions are tucked into their own panel.
- **Database (migration 86):** `flow.update_suggestions`, `flow.update_suggestion_ratings` (read only for the team, no direct writes), view `public.ui_update_suggestions` (team only), functions `public.update_log_suggest`, `update_log_rate`, `update_log_withdraw`, `update_log_set_status`. Test: `supabase/tests/update_suggestions_test.sql`.

## Not the same as ATAM GO
ATAM GO also has an "automation health" panel on its update log tab. That is not copied here: Flow already shows failed automations on the Exceptions and Control pages.

## Shared database with ATAM GO
ATAM GO runs on the same Supabase project and has its own suggestion tables and functions in the `public` schema (`suggest_update`, `rate_update_suggestion`, `withdraw_update_suggestion`). Flow's are deliberately separate and named `update_log_…` so the two never clash. Never reuse or drop ATAM GO's names. Before adding any new `public.*` function, check the live project for the same name.

## Not tested live
The page against the live project (needs migration 86 applied first; until then the Suggestions tab says it could not load). The timeline needs nothing from the database.
