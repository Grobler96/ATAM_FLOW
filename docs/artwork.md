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

## Artwork on screen: storage, preview, download, versions (9 Nov 2026)
Open **Artwork & Job Packs**, click an order: a drawer shows its artwork **by area** with the process, format, stitch count, size, approval and whether the file is stored.
- **Upload / add an area / upload a new version** (managers, admins, production planners): choose the file (embroidery files such as DST, PES, EXP, JEF, EMB; AI, EPS, PDF, SVG, images, PSD, CDR or a ZIP; up to 100 MB), say what it is and where it came from (a few words are required), and optionally the stitch count and size. The file goes into the private `artwork` bucket under `orders/<order>/<area>/v<n>-...` with a safe name, then the existing `manual_replace` action makes it the next version. Anything that is not an accepted type is refused before upload. Staff can add files to the bucket but never delete them (so history cannot be lost); if the save step fails after the upload, the file stays in the bucket unused and the screen says the save failed.
- **A new version waits for the customer** unless the box "The customer has already approved this exact version" is ticked. (The older `manual_replace` default was to approve; the screen now chooses explicitly.)
- **Preview** (images on screen; PDFs open in a new tab; production files such as DST say they cannot be previewed here), **Download** (a short-lived signed link, 5 minutes), and **earlier versions** with who, when and why. The DecoNetwork proof link is shown when DecoNetwork has one.
- **Change approval…** is the existing audited `set_approval` override (reason required); normally the customer's answer to a proof sets approval.
- Everyone on the team can look and download. Warehouse and viewer roles cannot change anything.
- **Job packs** (13 Nov 2026): the same drawer has a **Job packs** section. **Build job pack** asks which decorator, then builds the pack from the order as it stands (remaining quantities by colour and size, current artwork). A blocked pack lists the exact problems in the dialog. **Mark as sent** appears on a ready, up to date pack and records that it is released; nothing is emailed. Before this, the build and send actions existed only in the Artwork actions workflow with no button. A pack built without a consignment is still shown to the decorator in the portal for any consignment carrying that order.

## Customer proofs (migration 53)
A **proof** is a picture or PDF the customer approves, tied to the exact artwork versions it shows. Made outside DecoNetwork (for example emailed); **nothing is sent from ATAM_FLOW**.
1. **New proof:** upload the file, choose the areas. A new proof replaces any unanswered one for the same areas.
2. **Mark as sent:** who it went to and how (email, phone, in person, customer portal, other). The clock starts.
3. **Record the answer:** approved, wants changes, or rejected, who at the customer said so, what they said (required unless approved), and optionally evidence such as a screenshot of their email. **Approved** marks those areas approved; **wants changes** puts them back to waiting; **rejected** marks them rejected.
4. **The rule that matters:** an approval is only accepted while the areas on the proof are still the current versions. If the artwork was replaced after the proof was made, the approval is refused ("make a new proof") and the new version stays unapproved.
- **Withdraw** (reason required) a draft or sent proof. Answered proofs are kept as history.
- **Exceptions:** *Proof not answered* (sent, no answer after `artwork.proofs.reminder_days`, default 3) and *Approved proof no longer matches the artwork* (the customer approved, then the artwork changed). Both run with every exception check.
- **Customer proofs** tab: every proof; opens on what needs attention (waiting 3+ days, artwork changed since, or changes requested).
- Actions run through the (unpublished) Operations actions workflow (`proof_create`, `proof_send`, `proof_respond`, `proof_withdraw`: manager, admin or production planner). Files use the Artwork actions workflow (`manual_replace`, `set_approval`). Tests: `supabase/tests/proofs_test.sql`, `lib/artworkFiles.test.ts`, the artwork section of the dashboard e2e.

## Not built yet
- Sending proofs to the customer (email) and customer approval links: recorded by hand for now.
- Proofs for decorators' portal; a mock-up generator; automatic text/line-count checks of embroidery files.
- A checksum of uploaded files, and automatic virus scanning (files are limited by type and size, not scanned).

**Artwork sync from DecoNetwork (13 Nov 2026, migration 66, workflow `SAiGtlWqyeTLRxzd` "ATAM_FLOW · Sync artwork from DecoNetwork", hourly at :40, read-only on DecoNetwork).**
For every Priority Order it records each decorated area per product line (area name, process from DecoNetwork's process code, stitch count and DecoNetwork's public preview picture) through `flow_artwork_upsert`. The preview picture shows on the area card in the artwork drawer (`ui_artwork_files.thumbnail_url`, added by migration 66).
What it does **not** do: it does not download the real files. DecoNetwork returns links for the production, editable and source files and for the area proofs, but they carry an account key and DecoNetwork answers every request for them from this system with 401 (tried with and without the stored DecoNetwork login). The links are therefore not stored at all (the staff view would have shown them), so a synced area has no stored file (status "No file") and approval "unknown". A person uploads the real file by hand (Upload a new version) and approves it; a hand upload is never overwritten by the sync. A job pack stays blocked until that is done. Getting automatic file download needs DecoNetwork access that serves those links to a server (not yet found out how).
The sync does not look at orders that are not Priority Orders. Several lines on one order can each have an area with the same name; they are kept separately by line.

The earlier plan, kept for the record: The DecoNetwork artwork fetch. The existing `public.decoration_records` table gives area names and process codes per order but no file links. To pull links, stitch counts, sizes and
approval from DecoNetwork we need the API credential and one real sample response for an order with artwork; then a small workflow maps it into `flow_artwork_upsert`
(or posts to the `import` action). Until then artwork can be loaded with `import` or `manual_replace`.
Currently all 102 live orders with decoration show as blocked (no artwork rows), which is expected.
