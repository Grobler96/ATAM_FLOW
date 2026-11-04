# Supplier and producer selection

Built 4 Nov 2026 (migration 20, engine `packages/engine/selector.js`, 42 engine tests, round-trip test `scripts/selection-roundtrip.sh`).

## What it does

For one order it builds every sensible combination of **supplier plan x production route** and compares them:

- **Supplier plans:** each supplier that lists every SKU the order still has to buy, plus a *split* across suppliers when that is genuinely cheaper (blanks + delivery) than any single supplier. If everything is already in stock the plan is "Stock already held".
- **Routes:** in-house, each capable producer, and (where the supplier is marked able to deliver direct) **supplier straight to the producer**, which skips the transport leg and a day but is flagged because we cannot check the goods in.
- **For each option:** landed blank cost (+ delivery, free-delivery thresholds applied), decoration cost, transport to and from the producer, total cost, revenue, profit, margin %, cost and profit per unit, timeline (supplier lead time + goods-in + transit + production -> ready date -> days spare before the dispatch deadline), a 0-100 risk score with named flags, and an overall score.
- **Recommendation:** the best-scoring option that is complete (no missing costs) and on time. If nothing is on time it says so and picks the best late one. It also labels Cheapest, Fastest and Safest, lists what was rejected and why, and writes a plain-English explanation including the runner-up and why the cheapest option lost, if it did.
- **Instant switching and what-if:** the engine is a pure function, so the dashboard can run it in the browser. All options are computed together, so switching supplier or producer is just selecting another key. `overrides` supports `sku_costs` (per-SKU cost), `supplier_cost_adjust_pct`, `qty_multiplier`, `revenue`, `rates` (per producer or `internal`) and `force`. Overrides are never saved.

## Cost model (all configurable)

- Embroidery rate card: `per_1000_stitches` (units x stitches/1000 x price) or `per_piece` (per piece per area), plus `setup_fee` per design and a `min_job_charge`. Other methods use `per_piece`.
- Stock already held is valued at the cheapest known replacement cost (`value_on_hand_at`), so margin is not flattering.
- Revenue is the DecoNetwork order value, treated as ex-VAT unless `revenue_includes_vat` is set.
- Weights (margin 50 / speed 25 / risk 25), margin target 40%, minimum margin 15% (below it an option is flagged and penalised), due buffer, restock days, transit days, and every risk penalty are in `flow_settings` key `selection.config`. In-house settings are in `selection.internal`. Producer rates are in `flow.producer_rates` (admin/manager editable); transport costs on `producers.cost_out / cost_back`.

## Never guessed

If a rate, supplier cost, decoration method or order value is missing, the option is marked **incomplete**, its flags say what is missing, and it cannot be recommended or confirmed. An order with no recorded decoration method would otherwise look free, so it is treated as incomplete too.

## Where supplier prices come from

Per-supplier price lists (`supplier_offers`) are empty today. As a stand-in, a supplier that has **supplied that SKU before** (from PO history) is offered at the **last paid cost** from `sku_costs`, marked `last_paid_cost`. Until real price lists are loaded, suppliers with history tie on cost and are separated only by delivery, lead time and reliability. An explicit `supplier_offers` row always wins.

## Saving and confirming

`save_selection` stores the result as the order's current run; it is idempotent (the same inputs, ignoring today's date, keep the existing run). If inputs change a new run replaces it; if a **confirmed** choice is overtaken by changes a warning notification is raised and the confirmation is kept. `confirm_selection` records the person's choice; choosing something other than the recommendation needs a reason; incomplete options are refused; it is audited. Confirming does **not** raise a PO or move stock: the next step is `create_po_for_orders` and `build_job_pack`.

## n8n (unpublished)

`ATAM_FLOW · Supplier and producer selection` `9omdNalZkjKEYAy1`: POST `/webhook/atam-flow/selection` (admin, manager). `{action:'recommend', params:{order_id, overrides?}}` runs the engine (saved only when there are no overrides); `{action:'confirm', params:{order_id, key, reason?}}`. The engine is embedded with `node scripts/engine-literal.mjs selector`; regenerate whenever `selector.js` changes. The workflow runs only on demand (no schedule), so it adds no background executions.

## Data you need to supply for useful answers

Producer rate cards and transport costs, in-house rates, real supplier price lists and lead times, decoration method per order line (several large live orders have none recorded), and supplier/producer reliability (builds up from deliveries once POs and consignments flow through ATAM_FLOW).
