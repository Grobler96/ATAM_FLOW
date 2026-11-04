# Assumptions and open questions

## Answered (4 Nov 2026)

- **Stock deduction:** DecoNetwork takes stock out when an order is placed *if the item is in stock*. So `qty_on_hand` is already net of
  in-stock orders, orders at status 1/2 are already secured (`stock_secured`), and allocation only concerns orders **awaiting stock (9)
  or a purchase order (8)**. No double counting.
- **Status codes:** 1 ready for production · 2 ready for shipping · 3 shipped · 4 cancelled · 6 removed · 7 on hold · 8 awaiting purchase
  order · 9 awaiting stock · 10 awaiting artwork. Held in `flow.deco_status_map`; none are assumed any more.

## Still open

1. **When goods are received against a PO, does DecoNetwork automatically attach them to the waiting order and move it to status 1?**
   If yes, ATAM_FLOW only needs to *predict and prioritise*; if no, a person must move the order in DecoNetwork after our recommendation.
2. **Why are 77 orders (5,357 units) on hold?** Payment, proof, customer request? It is the largest pile, and a "what-if" load forecast
   for it could be useful.
3. **Are POs raised per order?** Many PO quantities equal the waiting order's need, which suggests DecoNetwork raises POs for specific orders. The stored PO lines carry no order reference, so the engine matches by SKU. If DecoNetwork's PO lines include the order ID we can match exactly.
4. **SKU coverage.** 350 SKUs on open order lines are not in `sku_inventory` (placeholders created). Are these supplier-delivered or
   listed under different SKUs?
5. **Stale POs.** 16 open POs are past their expected date (5 more than a month late). Were they received but not booked in? See `flow.v_overdue_pos`.
6. **Credential hygiene.** DecoNetwork username/password are stored in plain text inside existing n8n HTTP nodes. Recommend rotating.

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
- Apply `supabase/pending/*` (contain delete/drop statements, so Supabase asks for an interactive confirmation).
