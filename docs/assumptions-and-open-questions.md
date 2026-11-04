# Assumptions and open questions

## Needs your answer (affects Phase 3 correctness)

1. **Does DecoNetwork already deduct stock for orders in production?** Your existing "working stock" concept
   (`sku_working_stock`, added to on-hand for stock value) suggests `inv_lvl` excludes garments already pulled
   for in-progress orders. If so, allocating those orders again would double-count. We need to know *at which
   order stage* DecoNetwork deducts stock, so the allocation engine only reserves for orders where it has not.
2. **SKU coverage.** Only 201 of 598 open order lines have a SKU present in `sku_inventory` (308 SKUs in stock).
   The rest are presumably supplier-delivered-to-order or listed under different SKUs. Placeholder stock rows
   (qty 0) are created so these show as shortages; we need to decide how supplier stock (Ralawise/Portwest feeds)
   and drop-ship lines should be treated.
3. **DecoNetwork status codes** (`flow.deco_status_map`, all flagged assumed except 3 = shipped). Please confirm
   what 1, 2, 4, 6, 7, 8, 9 mean and which are "open".
4. **Dismissed orders.** Orders dismissed in ATAM GO are treated as inactive in ATAM_FLOW.
5. **Credential hygiene.** DecoNetwork username/password are stored in plain text inside existing n8n HTTP nodes.
   Recommend rotating them and moving to an n8n credential. ATAM_FLOW workflows will not contain them.

## Assumptions made (all editable)

- Dispatch date = DecoNetwork `date_due`.
- One placeholder machine per method; Mon–Fri 08:00–17:00 shifts; placeholder changeover and per-unit times.
- Bin zones: RECV, STG, WIP, DISP. No bins are pre-created; generate with `flow.generate_bins`.
- Label sizes A4 and 100×150 mm thermal; QR base URL set once the Pages URL is final.
- Process codes WEMB/DTF/UV/DTG → embroidery/dtf/uv/dtg. Unknown codes are reported in each sync summary.
- New orders start as `awaiting_stock` (or `ready_for_dispatch` if DecoNetwork says production is complete).

## Deployment steps that need a human

- ~~Apply migrations to the live project~~ Done 4 Nov 2026 (migrations 1-7; syncs verified idempotent on live data).
- Add `flow` to **Exposed schemas** (Supabase → Settings → API) before the dashboard (Phase 4). Not needed for n8n: it uses `public.flow_*` wrappers.
- Decide roles for the non-superuser ATAM GO users (only superusers are seeded as admins).
