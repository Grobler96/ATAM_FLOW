# Pre-production: DTF prints and the traffic lights

Started 21 Nov 2026. Before an order can go into production three things happen **at the same time**, and none waits for another: the **DTF prints** are made or ordered, the **embroidery** is checked, and the **stock** is bought. Whether the order is made in house or by a third party, these are the same three things.

## Phase A (this change): show where every order stands. Read-only.
Nothing here sends an email, creates a purchase order, or changes an order.

- **Migration 73** (`supabase/pending/20261121000073_flow_preproduction_dtf.sql`, **written and tested locally, NOT applied**). It contains a plain `drop constraint` (to allow a new tag condition), so the Supabase tool will ask for confirmation when it is applied: that is the safeguard working, not something to get round.
  - New tag and routing condition **"the order uses a process"** (`method_includes`, for example `dtf`). Starts one tag, **Needs DTF prints**, carrying the number of garments that use DTF.
  - `flow.dtf_items`: one row per DTF placement on an order line (the DecoNetwork line number, the placement such as Back or Left Chest, and the **number of garments on the line that carry that print**, no spares added). Status is `required` (red), `in_progress` (amber) or `done` (green); **in this phase every row is `required`** because nothing changes the status yet. A placement that disappears from DecoNetwork is marked not current, never deleted. A placement repeated on the same line gets a number, for example `Back (2)`.
  - `public.ui_dtf_items` (each placement with its artwork thumbnail when Flow holds one) and `public.ui_preproduction` (the three lights per active order).
- **The three lights**
  - **Prints:** none = no DTF on the order; red = DTF needed and nothing started (also when the placements have not been read yet); amber = some started or finished; green = all done.
  - **Embroidery:** none = no embroidery; red = no embroidery artwork recorded, or none approved and stored; amber = some approved or stored; green = every embroidery area approved **and** stored and readable. (Drive files arrive unapproved on purpose, so this stays amber until someone approves them on the Artwork screen.)
  - **Stock:** green = secured; amber = partly allocated; red = not secured.
  - **Ready** = nothing that applies is still red or amber.
- **The order facts reader** (n8n `IbZJlAMiEMSRL3ry`) now also sends the DTF placements. That change is a **draft: the live version is unchanged and does not send them yet.** It takes effect only when the draft is published, which should be done after migration 73 is applied (the live save function ignores a DTF list until then).
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

## Still to build (each its own draft PR, nothing sent without a person's approval)
- **B. In-house DTF order:** tick orders, "Build DTF order", which makes a DTF order to Super Print listing every artwork with its total and a thumbnail; the email goes from support@atam.co.uk through the existing Communications sender and **waits for approval** like every other email. Sending sets the prints to amber (Prints ordered); a **DTF received** button on the order sets green (Prints received), with thumbnails so booking in is easy.
- **C. Third-party flow in the decorator portal:** tick orders, download the files (creates a DTF job, amber), an order sheet with each file's thumbnail and quantity, and the decorator marks each DTF produced (green). Exact wording to be confirmed now the third party orders the DTFs from Super Print.
- **D. Refine** the Embroidery and Stock lights (for example mark embroidery checked by a person).
