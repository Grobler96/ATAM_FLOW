# Decorator portal

A separate, phone-friendly web page where each third-party decorator signs in securely and works their jobs: `portal.html` next to the main app (for the live site, `https://grobler96.github.io/ATAM_FLOW/portal.html`). It is a separate bundle: no internal screen or code is shipped to decorators.

## What a decorator can do
1. **Sign in** with their own email: a secure one-time link is emailed each time. No passwords. They see only the jobs (consignments) sent to their company, with the order numbers, customer names, quantities, due date and your instructions for their work. No prices, no other decorators, no internal pages.
2. **Accept the job**, or **decline** with a reason (raises a critical exception).
3. **Check the goods in**: count each line, report damaged units and the problem type, add photos. A clean count is one tap. A count or condition problem raises a "Decorator reported a problem" exception and needs words.
4. **Update the stage**: start production, production complete, or report a **delay** with a new date and reason (raises an exception).
5. **Ship back**: courier, tracking reference and units sent (fewer than expected needs an explanation and raises an exception). For direct-to-customer jobs, record the courier and tracking to the customer.
6. **Message us** on the job and add photos. Unanswered messages raise an exception after 24 hours.

Everything feeds the existing consignment lifecycle, events, audit trail and exceptions, with the actor shown as `producer:<name>`.

## Our side
- **Producers page, drawer, "Portal sign-in":** invite a person by email (manager/admin), switch them off or on with a reason (locks them out at once).
- **Consignment drawer, "From the decorator":** counts and conditions, photos, message thread with a reply box, and "Mark the problem as dealt with".
- Writes go through the unpublished Operations actions workflow (`portal_add_user`, `portal_set_user`, `portal_reply`, `portal_resolve`).

## Security model
- Portal users are **not** in `flow.user_roles`, so every internal view and function stays closed to them. They can run only the `public.portal_*` functions, each of which resolves identity from the login and touches only that decorator's own consignments. Anonymous visitors can call nothing.
- A login only gets access if its **verified email** matches an invited, active `flow.producer_users` row. An unconfirmed email, an unknown email or an ATAM team email is refused. Invitations are claimed on first sign-in.
- Photos go to a private storage bucket (`producer-evidence`, 10 MB, images and PDF) in a folder per decorator; a decorator can only write to and read from its own folder; ATAM team members can read all.
- The portal keeps its session separately from the main app.
- Tests: `supabase/tests/portal_test.sql` (isolation, refusal cases, every action, exceptions, switch-off) and `e2e/portal.e2e.mjs`.

## One-off setup in Supabase (needs your project settings, not done by me)
1. **Authentication, URL configuration:** add the portal address to the allowed redirect URLs, or the emailed link will not bring people back to it.
2. **Authentication, email:** the default sender is rate limited and branded Supabase. Before real use, set up your own email sender (for example Resend) and a clear subject and wording.
3. Anyone can ask for a sign-in link for any email, but only invited, confirmed emails get in. If you would rather stop strangers triggering emails at all, say so and I will switch the portal to invite-only sign-in links.

## Known limits
- **Stock ledger:** checking in moves the full quantity sent to "at producer" (the system of record). A short or damaged count raises an exception for a person to reconcile; it does not change stock by itself.
- No email notifications to decorators or to us yet (the exceptions and the unread flag are the alerts). Job pack files are not downloadable from the portal yet (the job sheet reference and instructions are shown).
- No per-line photo attachments in the check-in form (photos attach to the job), and no editing a check-in after it is sent (they message us).
