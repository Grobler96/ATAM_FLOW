# Pre-production: DTF prints and the traffic lights

Started 21 Nov 2026. Before an order can go into production three things happen **at the same time**, and none waits for another: the **DTF prints** are made or ordered, the **embroidery** is checked, and the **stock** is bought. Whether the order is made in house or by a third party, these are the same three things.

## Phase A (this change): show where every order stands. Read-only.
Nothing here sends an email, creates a purchase order, or changes an order.

- **Migration 73** (`supabase/migrations/20261121000073_flow_preproduction_dtf.sql`, **applied to the live project 21 Nov 2026**). It contains a plain `drop constraint` (to allow a new tag condition), so the Supabase tool asks for confirmation: that is the safeguard working, not something to get round.
  - New tag and routing condition **"the order uses a process"** (`method_includes`, for example `dtf`). Starts one tag, **Needs DTF prints**, carrying the number of garments that use DTF.
  - `flow.dtf_items`: one row per DTF placement on an order line (the DecoNetwork line number, the placement such as Back or Left Chest, and the **number of garments on the line that carry that print**, no spares added). Status is `required` (red), `in_progress` (amber) or `done` (green); **in this phase every row is `required`** because nothing changes the status yet. A placement that disappears from DecoNetwork is marked not current, never deleted. A placement repeated on the same line gets a number, for example `Back (2)`.
  - `public.ui_dtf_items` (each placement with its artwork thumbnail when Flow holds one) and `public.ui_preproduction` (the three lights per active order).
- **The three lights**
  - **Prints:** none = no DTF on the order; red = DTF needed and nothing started (also when the placements have not been read yet); amber = some started or finished; green = all done.
  - **Embroidery:** none = no embroidery; red = no embroidery artwork recorded, or none approved and stored; amber = some approved or stored; green = every embroidery area approved **and** stored and readable. (Drive files arrive unapproved on purpose, so this stays amber until someone approves them on the Artwork screen.)
  - **Stock:** green = secured; amber = partly allocated; red = not secured.
  - **Ready** = nothing that applies is still red or amber.
- **The order facts reader** (n8n `IbZJlAMiEMSRL3ry`) now also sends the DTF placements. **Published 21 Nov 2026** (after migration 73 was applied), hourly at :55.
- **Screens:** a **Pre-production** page (sidebar, Operate group; `#/preprod`; keyboard `g` then `v`) with tabs **Orders** (the lights for every active order; opens on Not ready) and **DTF prints** (orders that need prints, then what has to be made **by design**, with thumbnails and totals so the same artwork on several orders is one line). The **order drawer's Overview** has a Pre-production box (the three lights, what is behind each, and each DTF placement with its quantity and file). The **Orders lists** have a Pre-production column with the three lights (each with its words on hover and for screen readers).
- A mark (tick, exclamation, cross, dash) is shown as well as the colour, so the lights read without colour.
- **Data seen on 21 Nov 2026 (read-only):** 167 of 657 recent orders use DTF: 940 placements and 3,747 garments. DecoNetwork spells the process exactly `DTF`. In Flow only some DTF placements have a stored PNG; many have only DecoNetwork's placeholder, so the screens say **file missing** and a print cannot be ordered until the real file is there.

## Decisions from the owner (21 Nov 2026)
- **DTFs are bought from Super Print.**
  - **In-house order:** we order the DTFs from Super Print and apply them here.
  - **Third-party order:** the third party orders the DTFs.
  - Super Print is **not yet a supplier in Flow**. It needs adding (with an email address) before the in-house DTF order can be built.
- The quantity per artwork is the number of garments carrying that print.
- The DTF order email should be whatever is easiest for the recipient to read (plan: a clear table in the email body with each artwork's thumbnail, name and quantity, plus the files attached or linked).

## Phase B: the in-house DTF order to Super Print (built 21 Nov 2026; **migration 74 applied and the n8n workflow published on 21 Nov 2026**)
- **Migration 74** (`supabase/migrations/20261121000074_flow_dtf_orders.sql`, applied 21 Nov 2026):
  - adds **Super Print** as a supplier (code `SUPERPRINT`) with **no email address yet**;
  - `flow.dtf_batches` (a DTF order, `DTF-2026-00001`: draft -> ordered -> received, or cancelled) and a `batch_id` on `flow.dtf_items`;
  - `flow.dtf_plan` (read-only: what would go on a DTF order and what is left out and why), `flow.dtf_build_order` (makes the DTF order and queues its email), `flow.dtf_receive` (marks prints received, in whole or part);
  - the email goes through the **normal approval queue** (kind `other`, review required, so it shows in Purchasing, Emails). **With no address for Super Print it stays a draft that cannot be approved**, exactly like a purchase order to a supplier with no address. The email lists every artwork once with its total number of garments, a picture, the orders it is for and a time-limited **download link** for the file (the live email sender cannot attach files, so links are used; they last 14 days);
  - **sending** the email (`flow.comm_mark_sent`, patched in place) moves the DTF order to ordered and its placements to in progress (amber, Prints ordered); **cancelling** the email (`flow.comm_cancel`, patched in place) cancels the DTF order and frees its placements;
  - `ui_dtf_items` gains `batch_id`, `batch_ref`, `batch_status`; new `ui_dtf_batches`.
  - **Rules:** a placement goes on a DTF order only if its order is **not third party** (the decorator orders their own), it has a **stored file**, it is still "required", and it is not already on a DTF order. Everything else is left out with the reason shown.
- **n8n workflow `ATAM_FLOW · DTF actions`** (`4sk2X0uSf6szUB8H`, path `atam-flow/dtf`, behind Verify caller; **published 21 Nov 2026**; an anonymous call is refused with 401): `build_order` (admin, manager, production) looks up the plan, makes a 14-day signed link for each file, and calls `flow_dtf_build_order`; `receive` (also warehouse) calls `flow_dtf_receive`. It sends nothing itself. Its logic was tested locally with mock inputs. **No DTF order has been built yet on the live system**, so the first real build is the first full run through n8n, the storage links and the database: build a small one and check the email draft.
- **Screens (DTF tab):** tick orders and press **Build DTF order** (a dialog shows what will be ordered, as designs with totals and pictures, and what is left out and why, and says nothing is sent); a **DTF orders to Super Print** list with where each has got to; **DTF received...** on an ordered DTF order (each print with its picture, tick the ones that have arrived, whole or part). Warehouse can book in but not build; view-only can do neither. Order drawer placements show their DTF order and have an **Add the file** link when a file is missing.
- **Getting the DTF files into Flow (21 Nov 2026):** of 239 DTF placements on active orders only 21 have a stored file. DecoNetwork's direct file links (`.../get_design/<n>?user[id]=...&key=...`) return **401 "Not Admin..."** for our integration account, with or without our login, so Flow cannot download them. Google Drive works but DecoNetwork only writes Drive files for **Priority Orders** (and only once production files are ready). All 24 DTF files that do exist matched their placements, so this is not a matching problem. The route that works today for an in-house order is the existing manual upload on the Artwork screen (linked from each missing placement). Two changes inside DecoNetwork would fix it for good: widen its Drive production-file output beyond Priority Orders, or give the integration user permission to download production files.

## Still to build
- Phase C and D (below).
- **B. In-house DTF order:** tick orders, "Build DTF order", which makes a DTF order to Super Print listing every artwork with its total and a thumbnail; the email goes from support@atam.co.uk through the existing Communications sender and **waits for approval** like every other email. Sending sets the prints to amber (Prints ordered); a **DTF received** button on the order sets green (Prints received), with thumbnails so booking in is easy.
- **C. Third-party flow in the decorator portal:** tick orders, download the files (creates a DTF job, amber), an order sheet with each file's thumbnail and quantity, and the decorator marks each DTF produced (green). Exact wording to be confirmed now the third party orders the DTFs from Super Print.
- **D. Refine** the Embroidery and Stock lights (for example mark embroidery checked by a person).
