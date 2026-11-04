# Artwork, job packs and the dispatch gate

Built 4 Nov 2026 (migrations 18-19, tested by `supabase/tests/artwork_test.sql`). The DecoNetwork *fetch* step is not built yet (see the bottom).

## Model

- `flow.artwork_files`: one row per decorated area per product line (`order_id`, `deco_line_id`, `area`). Process, production / editable / source / proof / thumbnail URLs,
  format, stitch count, size, crop, placement, transfer details, approval status, `version`, `is_current`, storage status and path, readable flag.
  A change to anything that matters (`artwork_signature`) creates version n+1 and supersedes the old row, so history is never lost. An unchanged sync does nothing.
- Files are stored in the **private** `artwork` bucket. Staff read with their login; producers will only ever be given short-lived signed links from the portal.
- `flow.job_packs`: what a producer receives for one order: lines by colour with sizes and quantities, artwork per area (stored file path, stitch count, size, crop,
  placement, transfer details, version), producer special instructions, due date. **No costs, margins, customer prices or source URLs.**

## Rules (all in `artwork.options`, each can be relaxed)

A pack is **blocked** unless every decoration method on every product line has artwork (embroidery needs one per area, from `emb_areas`), every area is approved,
has a production file, has been downloaded to secure storage, is readable, and embroidery has a stitch count. A blocked pack lists the exact issues.
A pack is **stale** the moment any current artwork changes (new version, approval or storage change): a stale pack cannot be marked sent and must be rebuilt.
With `enforce_before_dispatch` on, a consignment to a producer cannot be dispatched until every order in it has a ready, up-to-date pack for that producer.

## Manual control

`artwork_manual_replace` (needs a note) uploads a new version by hand. It becomes the current version, and the DecoNetwork sync will **not** overwrite it.
`artwork_set_approval` (needs a note) overrides the approval status. Both are audited.

## n8n (unpublished)

| Workflow | ID | Trigger |
|---|---|---|
| ATAM_FLOW · Artwork download and store | `kvgqKRD7dVWOJkoa` | every 15 min: downloads files, rejects empty files and login pages, stores them, records the result |
| ATAM_FLOW · Artwork actions | `nkOanz4G48WKPv1k` | POST `/webhook/atam-flow/artwork` (admin, manager, production): `import, validate, manual_replace, set_approval, build_pack, mark_pack_sent` |

A file that fails to download stays flagged and blocks the pack; the fix is a manual replacement (there is no automatic retry yet).

## Not built yet

The DecoNetwork artwork fetch. The existing `public.decoration_records` table gives area names and process codes per order but no file links. To pull links, stitch counts, sizes and
approval from DecoNetwork we need the API credential and one real sample response for an order with artwork; then a small workflow maps it into `flow_artwork_upsert`
(or posts to the `import` action). Until then artwork can be loaded with `import` or `manual_replace`.
Currently all 102 live orders with decoration show as blocked (no artwork rows), which is expected.
