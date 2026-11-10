# Independent security and permissions audit (10 Nov 2026)

Scope: the live database as each real role (signed-out, a staff login, a decorator login, the service role), the decorator portal, the seven published n8n action workflows, storage, and a sweep of every staff view. Read-only, except the fixes listed.

## 1. CRITICAL: a decorator login could reach the other app's data (guard switched on 10 Nov 2026 with the owner's go-ahead)
This Supabase project is shared with another app (ATAM GO). That app trusts **any** logged-in user: its tables use "any signed-in user may read", and its write functions only check "is someone signed in". That was safe while every login was a team member. The decorator portal created a new kind of login in the same project.

Confirmed on the live database, as the test decorator login, counts only: 8,107 Xero sales documents, 1,340 quotes, 474 supplier invoices and 370 sales invoices awaiting review, 5,348 sales order lines, 3,064 SKU costs, 53 customer accounts, and all 526 files in the `invoice-pdfs` bucket were readable. The other app's write functions (approve an invoice, queue a customer email, set sales targets and about 60 more) would also have accepted the call. A decorator who has been switched off keeps this access, because switching off only closes the portal functions.

What limits it today: sign-ups are switched off project-wide (checked), so only people ATAM invites get a login, and the only decorator login that exists is the owner's own test account. The staff side of ATAM_FLOW itself held: a decorator login got zero rows from every `flow` table and staff view.

**Do not invite real decorators until the two sign-in checks below have been done by a person.**

Fix (migration 61, applied live). Checked on the live database: as the test decorator login the guard allows a portal function and refuses the other app's table, and the 526 invoice PDFs are no longer visible; as a staff login nothing changed; signed-out API calls behave as before. **Not yet proven:** that the API service has picked the guard up for real requests, because that needs a real decorator sign-in. Details:
- `public.portal_api_guard()` runs before every API request. A decorator login may only call `public.portal_*` functions; everyone else passes straight through. It fails open if its own lookup errors, so it cannot take the other app down.
- A restrictive storage rule confines a decorator login to the two buckets the portal uses.
- Inviting an address that already has a login is refused, so a team member can never be turned into a decorator.
- Switching it on: `alter role authenticator set pgrst.db_pre_request = 'public.portal_api_guard'`. Undo: `alter role authenticator reset pgrst.db_pre_request; notify pgrst, 'reload config';`.
- After switching on: sign in to the portal with the test decorator (jobs must load), and sign in to ATAM GO and ATAM_FLOW as staff (must be unchanged).

Longer term the cleaner design is one of: decorators in their own Supabase project, or the other app's rules changed from "any signed-in user" to "team member". The guard is containment, and it is one line of defence, not two.

## 2. Fixed and live (migration 60, flow only)
- Three crew history views (`flow.v_operator_history`, `v_operator_customer_history`, `v_operator_quality`) ran with owner rights and were readable by any login (167 rows of customer history per operator). Direct access removed; staff still get them through the existing team-only functions.
- `flow.order_blocking_exceptions` answered for any login. It now answers only for the team and the service role.
- Neither was reachable through the API (the `flow` schema is not exposed), so this is tidying, not a breach.
- A regression test now fails the build if any owner-rights view becomes readable from the browser.

## 3. Checked and sound
- **Staff views:** all 95 `ui_*` views load for a real staff login, none slow, none over 5,000 rows.
- **Signed-out visitors:** cannot read any `flow` table or staff view, cannot run any privileged function.
- **Every security definer function** (424) pins its search path. Row level security is on for every `flow` table.
- **Portal functions:** each one resolves the decorator from the login and checks the job belongs to them; file paths are checked against the decorator's own folder; messages are length-limited.
- **n8n (7 published workflows):** every webhook goes through Verify caller (the token is checked with Supabase server-side, then the role is looked up), then an allow-list. Senior-only actions are enforced in the workflow. A decorator login has no role, so it is refused.
- **Realtime:** no tables are published, so nothing leaks that way.

## 4. Lower-priority observations (not fixed)
- **Everyone is an admin.** All 10 staff logins have the admin role, so every role check passes for everyone and "someone else must approve" rules are the only real separation. Needs the owner's list of who gets which role.
- **n8n workflows are not in the repo** (`n8n/workflows` is empty). If one is damaged there is only n8n's own version history to recover from.
- **Webhooks are open to the internet** and each call, even a refused one, uses an n8n execution and a Supabase check. Someone could burn the n8n quota by hammering them. No rate limit exists.
- **Admins and managers can still write some set-up tables directly** (machines, bins, settings, producers, suppliers, roles) through database rules that pre-date the "all writes go through n8n" pattern. Those writes skip the audit trail.
- **Decorators can upload unlimited files** (10 MB each) into their own folder. *Fix written, not live:* migration 62 limits a job's folder to 40 files and 250 MB (placeholders); see [producer-portal.md](producer-portal.md).
- **Other app, not ours to change:** supplier stock tables are readable signed-out (looks deliberate); several of its tables grant write rights that only row level security holds back.
