# Embroidery before production

Started 21 Nov 2026. **Step 1 of 3** (this change): the design register, swatch statuses and the two tabs. Step 2 is the proof sheet and the swatch email; step 3 is the "files to update on DecoNetwork" list and the stale-file warning.

## Why
We turn an enquiry into stitches, upload it to the order in DecoNetwork for a visual and pick thread colours. Once the order is placed a **physical swatch** is run to check it matches the visual, and a picture goes to the customer to sign off. **A logo we have already embroidered does not need a swatch.** The process is the same for in-house (IH) and third-party (3PD) orders, so the screen has a tab for each.

## What was built (migration 77, **applied and the n8n workflow published on 21 Nov 2026; nothing used by a real person yet**)
- **A register of designs, per customer** (`flow.emb_designs`, keyed by the DecoNetwork customer number). Statuses: **known** (done before), **swatch required**, **swatch in progress**, **swatch sent**, **swatch approved**, **changes needed**. A rejected swatch starts a **new round** when work starts again. Every change is in `flow.emb_events` and the audit log.
- **Links** (`flow.emb_links`): which order area uses which design. Links are switched off, never removed.
- **`public.ui_emb_areas`**: every embroidery area on every active order with its status, or a **suggestion** when the same customer has the same artwork or the same stitch count and size (within 2 mm). A suggestion is never applied by itself: a person confirms.
- **The Embroidery light** on Pre-production is green when a person has checked the order, when every area's design is known or swatch approved, or (as before) every area is approved and stored; amber while a swatch is under way or some areas are done; red otherwise.
- **Screen:** **Embroidery** in the sidebar (Operate; `g` then `8`). Tabs **In house** and **Third party** (and **Not decided** only when something is in it). Open an area to: confirm a suggestion, pick another of the customer's logos, make it a **new logo** (swatch required), or say **we have done this before**; for a linked area, move the status along (a note is needed for changes needed and for reopening) or unlink it. Planners only (admin, manager, production); anyone else can look.
- **n8n:** the former "DTF actions" workflow (`4sk2X0uSf6szUB8H`) is now **ATAM_FLOW · Pre-production actions** with new actions `emb_new`, `emb_link`, `emb_unlink`, `emb_status`.

## Step 2a: the proof sheet (built 21 Nov 2026; **migration 78 applied 21 Nov 2026; no proof sheet printed from a real order yet**)
- **Print proof sheet** in the embroidery dialog (one area) and **Print proof sheets** as a bulk action on the Embroidery table (one page per ticked area). Anyone signed in can print; it is made in the browser and nothing is sent. If the browser blocks the new window the screen says to allow pop-ups.
- Each page shows the order, due date, customer, where it is made, placement, logo and status (and round), stitch count and size, file type and version, and the logo picture. It leaves **boxes to write in**: eight needles with thread colour or code and whether each matches the logo, the machine, who ran it and when, whether the swatch matches the visual, the customer's sign-off, and notes. **Thread colours are filled in by hand**, because they are not in the data we pull from DecoNetwork (no thread information is held on any embroidery file).
- **Download stitch file** in the dialog when Flow holds the file (stored or uploaded by hand); otherwise it says so and links to the Artwork screen. Only 56 of 599 embroidery files are stored today.
- Migration 78 adds one column (`storage_path`) to `public.ui_emb_areas`. Nothing else changes in the database.
- Still to come in step 2: the swatch email and its template (waiting on the template text), and whether to attach the proof sheet or send a picture of the swatch.

## What the live data showed (21 Nov 2026, read-only)
- Flow's history starts 2 Sept 2026 and embroidery files only started being recorded on 13 Nov, so **logos embroidered before then look new** until someone marks them as done before.
- 14 of 95 distinct embroidery artworks appear on more than one order (one on 25); only 3 are shared across customers. 546 of 599 have a stitch count and size; only 56 have a stored file, so matching on file content is not possible yet.
- DecoNetwork's proof, production and editable links are empty for every embroidery file, so Flow will have to make its own proof sheet (step 2).

## Open questions (assumptions used until answered)
- The swatch **email template** has not come through (nothing was attached): please paste it.
- Where do the **thread colours** live? They are not in what we pull from DecoNetwork.
- Third party: does the decorator run the swatch (a portal screen like the DTF one) or does ATAM? Assumed ATAM tracks it for now.
- Customer sign-off by reply email (staff mark it approved) is assumed; a one-click approve link would be more work.
- A swatch is assumed to be for a brand-new logo only (not for a new garment type or colour).
- Updating files in DecoNetwork is assumed to be manual.
