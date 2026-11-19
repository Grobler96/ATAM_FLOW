# Artwork from Google Drive (design, not built yet)

Resumed 19 Nov 2026. Since this was written, `main` gained the DecoNetwork artwork sync (see [artwork.md](artwork.md)): it already creates a row per order, line and area with the preview picture and stitch count, but no real file (status "No file"). **Drive files therefore attach to those existing rows** (matched by order number and area name); a file that matches no row goes on an Unmatched list. A hand upload is never overwritten by a sync, and a Drive file becomes a new version (unapproved) like any other.

Idea (14 Nov 2026): artwork and job packs from DecoNetwork are put in a Google Drive account; Flow pulls them from there and attaches them to the matching jobs. This replaces the blocked "DecoNetwork artwork fetch" step in [artwork.md](artwork.md).

## Decisions so far
- **Matching an order:** layout in Drive not decided yet. The sync must therefore find the order number in either a folder name (`636220/`) or a file name (`636220_front.dst`), and optionally unpack a zip named by order. Anything it cannot match goes to an **Unmatched** list for staff, never guessed.
- **Matching an area:** from the file name (for example `front`, `back`, `left-chest`) mapped to the area on the order. An unrecognised area is left unassigned for staff to pick.
- **Approval:** files arrive **unapproved**. Approval stays with the existing proof / `set_approval` flow.
- **Source:** to be confirmed (does DecoNetwork export to Drive by itself, or does someone drop files in?). Flow only reads Drive, so this does not change the design.

## How it would work
1. A new n8n workflow (left unpublished until tested) runs every 15 minutes with a Google Drive credential limited to **read-only on one folder**.
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
