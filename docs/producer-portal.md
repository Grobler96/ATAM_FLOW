# Decorator portal

A separate, phone-friendly web page where each third-party decorator signs in securely and works their jobs: `portal.html` next to the main app (for the live site, `https://grobler96.github.io/ATAM_FLOW/portal.html`). It is a separate bundle: no internal screen or code is shipped to decorators.

## What a decorator can do
1. **Sign in** with their own email: a secure one-time link is emailed each time. No passwords. They see only the jobs (consignments) sent to their company, with the order numbers, customer names, quantities, due date and your instructions for their work. No prices, no other decorators, no internal pages.
2. **Accept the job**, or **decline** with a reason (raises a critical exception).
3. **Check the goods in**: count each line, report damaged units and the problem type, add photos. A clean count is one tap. A count or condition problem raises a "Decorator reported a problem" exception and needs words.
4. **Update the stage**: start production, production complete, or report a **delay** with a new date and reason (raises an exception).
5. **Ship back**: courier, tracking reference and units sent (fewer than expected needs an explanation and raises an exception). For direct-to-customer jobs, record the courier and tracking to the customer.
6. **Message us** on the job and add photos. Unanswered messages raise an exception after 24 hours.
7. **Job pack and artwork downloads:** on each job, the current job pack (version, due date, instructions, what to make and where, sizes) with a **Download** button for each artwork file and its specs (format, stitch count, size). They only ever get the latest version of the packs for their own jobs, never an older or blocked pack, and nothing else in the artwork store. If a file has not been stored yet the screen says so. No costs or margins are returned (the portal function returns a fixed list of fields).
8. **Scan a parcel label** on the job list (camera, a hardware scanner or typing the TP number) to open that job. A parcel that is not theirs is refused with a plain message.
9. **Photos per item at check-in:** each line has its own photo box, as well as photos of the whole delivery; each photo is saved against its line.
10. **Report spoiled units** once the goods are checked in and until they are sent back: choose the line, how many, what happened (stained, misprint, machine fault, damaged, wrong item, other), a few words, and an optional photo. It becomes a *suggested* waste record that a person confirms or dismisses on the Waste page (so it counts for nothing until then), is logged on the job and is posted in the message thread. A decorator cannot report more units on a line than were sent (dismissed reports free their units again) and sees only their own reports and where each stands, never costs or internal notes. Damage found on arrival still goes in the check-in. Functions: `portal_report_spoilage`, `portal_spoilage`; tests in `portal_spoilage_test.sql`.

Everything feeds the existing consignment lifecycle, events, audit trail and exceptions, with the actor shown as `producer:<name>`.

## Our side
- **Producers page, drawer, "Portal sign-in":** invite a person by email (manager/admin), switch them off or on with a reason (locks them out at once).
- **Consignment drawer, "From the decorator":** counts and conditions, photos, message thread with a reply box, and "Mark the problem as dealt with".
- Writes go through the unpublished Operations actions workflow (`portal_add_user`, `portal_set_user`, `portal_reply`, `portal_resolve`).

## Security model
- Portal users are **not** in `flow.user_roles`, so every internal view and function stays closed to them. They can run only the `public.portal_*` functions, each of which resolves identity from the login and touches only that decorator's own consignments. Anonymous visitors can call nothing.
- A login only gets access if its **verified email** matches an invited, active `flow.producer_users` row, and the sign-in page itself is invite-only (see setup note 3). An unconfirmed email, an unknown email or an ATAM team email is refused. Invitations are claimed on first sign-in.
- Photos go to a private storage bucket (`producer-evidence`, 10 MB, images and PDF) in a folder per decorator; a decorator can only write to and read from its own folder; ATAM team members can read all.
- The portal keeps its session separately from the main app.
- Tests: `supabase/tests/portal_test.sql` (isolation, refusal cases, every action, exceptions, switch-off) and `e2e/portal.e2e.mjs`.

## One-off setup in Supabase (needs your project settings, not done by me)
1. **Authentication, URL configuration:** add the portal address to the allowed redirect URLs, or the emailed link will not bring people back to it.
2. **Authentication, email:** the default sender is rate limited and branded Supabase. Before real use, set up your own email sender (for example Resend) and a clear subject and wording.
3. **Invite-only** (done in the code): the portal never creates accounts. Inviting someone (Producers page) creates their sign-in account through the Operations actions workflow, so the emailed link is sent only to people you have invited, and an uninvited address sees the same message as an invited one. For belt and braces, also switch off **Allow new users to sign up** under Authentication in Supabase (it does not affect your team's logins).

## Known limits
- **Stock ledger:** checking in moves the full quantity sent to "at producer" (the system of record). A short or damaged count raises an exception for a person to reconcile; it does not change stock by itself.
- No email notifications to decorators or to us yet (the exceptions and the unread flag are the alerts). - No editing a check-in after it is sent (they message us). Artwork downloads work through the storage rule `artwork_decorator_read`, which is tested through the database function it calls (`portal_packs_test.sql`), not against real storage in the automated tests.
