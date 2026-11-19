# Artwork from Google Drive (built, tested and published 19 Nov 2026: live)

Resumed 19 Nov 2026. Since this was written, `main` gained the DecoNetwork artwork sync (see [artwork.md](artwork.md)): it already creates a row per order, line and area with the preview picture and stitch count, but no real file (status "No file"). **Drive files therefore attach to those existing rows** (matched by order number and area name); a file that matches no row goes on an Unmatched list. A hand upload is never overwritten by a sync, and a Drive file becomes a new version (unapproved) like any other.

Idea (14 Nov 2026): artwork and job packs from DecoNetwork are put in a Google Drive account; Flow pulls them from there and attaches them to the matching jobs. This replaces the blocked "DecoNetwork artwork fetch" step in [artwork.md](artwork.md).

## Decisions so far
- **Matching an order:** layout in Drive not decided yet. The sync must therefore find the order number in either a folder name (`636220/`) or a file name (`636220_front.dst`), and optionally unpack a zip named by order. Anything it cannot match goes to an **Unmatched** list for staff, never guessed.
- **Matching an area:** from the file name (for example `front`, `back`, `left-chest`) mapped to the area on the order. An unrecognised area is left unassigned for staff to pick.
- **Approval:** files arrive **unapproved**. Approval stays with the existing proof / `set_approval` flow.
- **Source:** to be confirmed (does DecoNetwork export to Drive by itself, or does someone drop files in?). Flow only reads Drive, so this does not change the design.

## How it would work
1. A new n8n workflow runs every 15 minutes with a Google Drive credential limited to **read-only on one folder**.
2. It lists new or changed files since the last run (Drive file id + modified time + size recorded, so nothing is imported twice).
3. For each file it works out order number and area, downloads it, rejects empty files and login pages (same checks as the existing artwork download job), uploads it to the private `artwork` bucket, and calls the existing `manual_replace`-style import so it becomes the next version with source "Google Drive".
4. Changed file in Drive = new version; the old one is kept. Existing rules apply: any change makes job packs stale and approvals must be redone.
5. Problems (no order match, unknown area, bad file) appear as an exception, not silently dropped.

## Google login (owner will do this in n8n)
n8n has a Google Sheets login but none for Drive. Add a **Google Drive OAuth2 API** credential in n8n, signing in with the Google account that owns the artwork folder, and give it the **read-only** Drive scope (`drive.readonly`). Share the artwork folder with that account if it is a different one. Nothing secret goes in this repo; the workflow only names the credential.

## Open items for the owner
- **Still unknown:** how files are saved in Drive (folder per order, names, or zips) and one real example. Check what DecoNetwork produces for one order.
- **Still unknown:** whether DecoNetwork exports to Drive itself or someone drops the files in.
- The Google Drive login in n8n (steps above).
- The list of area words used in file names.

## Build steps once those are known
1. Migration: table for Drive file ids and the unmatched list, plus an import function.
2. n8n workflow `ATAM_FLOW · Artwork from Drive` (export copy in `n8n/workflows/`).
3. Unmatched list on the Artwork screen.
4. Tests: SQL suite for the import function, parsing tests for the file-name rules.


## What was built (19 Nov 2026)

**What DecoNetwork puts in Drive** (seen on real orders): `DecoNetwork Files / order-<order number> / worksheet-<order>.pdf` and `.../<item number>/order-<order>-<item>-<location>-<area>-<PROCESS>.dst`, for example `order-636894-3730138646-Front-Left_Chest-EMB.dst`. The item number is the order line's `deco_line_id` in Flow; the area (underscores read as spaces) matches Flow's area names ("Left Chest", "Right Sleeve (Long)"); `EMB` is embroidery. Only the production file is sent (the alternate-format and source-file options in DecoNetwork are off).

**Database** (migration 68 `20261119000068_flow_drive_artwork`, applied 19 Nov 2026; tests `supabase/tests/drive_artwork_test.sql`):
- `flow.drive_files` remembers every Drive file seen: status *ready*, *waiting*, *imported*, *ignored* or *failed*.
- `flow.drive_plan` reads the file names and says which files to fetch. A file whose order or order line is not in Flow yet is *waiting* and costs nothing (looked at again every run). Each file is tried at most 5 times, then shows as *failed*. Worksheets and unrecognised names are *ignored*.
- `flow.drive_import` attaches a fetched file: a new **version** of the matching order + line + area (or a new area if DecoNetwork's sync had none), **unapproved** (`pending`), keeping the stitch count, size, placement and preview picture already recorded. The same content again makes no new version; a changed file makes the next version. If an approved area changes, a notification is raised and the job pack goes stale as usual.
- The artwork `source` can now be `google_drive`. **Neither the DecoNetwork sync nor a later Drive run overwrites a hand upload**, and the DecoNetwork sync no longer replaces a Drive version.
- Only the service role can run the sync functions; staff can read `ui_drive_files`.

**n8n**: workflow `ATAM_FLOW · Artwork from Google Drive` (`9NPEGMStynVloDac`, **published and active since 19 Nov 2026**), every 15 minutes or **Run now**. It lists files created in the last 7 days, asks `flow_drive_plan` what to fetch (25 at a time), downloads each from Drive, stores it in the private `artwork` bucket at `drive/<order>/<line>/<drive id>-<name>`, then calls `flow_drive_import`. It uses the n8n credentials `Google Drive account` and `Supabase account 2`.

**Screen**: Artwork & Job Packs → **Google Drive** tab lists files that are waiting, failed or not applied, with the reason and a link to the file in Drive.

**Not built / known limits**
- Worksheet PDFs are recorded but not attached to the order.
- There is no button to retry a *failed* file or to place a file by hand: fix the cause, or upload by hand from the order.
- An area name that DecoNetwork spells differently from its file name will not match an existing row; the file then makes a new area row instead of filling the old one. Check the first live orders.
- Order numbers and item numbers in file names must be digits.
- Drive files older than 7 days are not looked at.

**First live test (19 Nov 2026, run by hand):** order 636894's two embroidery files were fetched from Drive, stored in the `artwork` bucket (sizes match) and attached as v1 of "Left Chest" and "Right Sleeve (Long)", source Google Drive, waiting for approval. They became new areas, not new versions, because 636894 is not a Priority Order and so had no DecoNetwork area rows; matching onto an existing DecoNetwork row has only been tested locally so far. Order 636900's files were *waiting* because that order had not reached Flow yet.

**Published 19 Nov 2026** with the owner's go-ahead: the workflow now runs every 15 minutes by itself. To switch it off, deactivate it in n8n. Things to watch at first: files marked *waiting* should clear once their order reaches Flow; the first Priority Order should show a Drive file filling an existing DecoNetwork area row (only tested locally so far); anything *failed* shows on the Artwork screen's Google Drive tab with the reason.
