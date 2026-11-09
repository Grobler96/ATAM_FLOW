# Stock-takes

Count what is physically on the shelves and compare it with the system. **A stock-take never changes stock.** DecoNetwork owns on-hand quantities and overwrites them on every sync, so the result is a record of what was counted and what the gap is, plus a reminder to put DecoNetwork right.

## How it works (Stock-takes page, `#/stocktake`)
1. **Start** (warehouse, production, manager, admin): name it and choose what to count: a **shelf or area** (starts with), the **most valuable items** (top N by stock value, skipping anything already being counted), **particular SKUs**, or **everything with stock**. The expected quantity of each item is snapshotted when it starts. An item can only be in one open stock-take at a time (others are left out and the screen says how many).
2. **Count** (blind): scan the shelf label (camera, hardware scanner) or type the SKU, then the quantity. **The counter is never shown the expected quantity**; the screen and the database view both hide it (and the difference) until counting is finished. Stock found that was not on the list can be added. Counting an item again replaces the count; every count is kept in an unchangeable log.
3. **Finish counting** (any counter): the expected quantities are revealed. Each line is sorted: **matches**; **needs a recount** (5+ units or £50+ out, `stocktake.rules`); or a **small difference** waiting for a decision.
4. **Recount**: must be done by a **different person** from the one who counted. A recount that matches clears the difference.
5. **Decide**: every accepted difference needs a **reason**. A difference worth more than £250 needs a **manager or admin**; a manager can also accept one that was sent for a recount without one. "Accept the small differences" does the rest with one shared reason.
6. **Close** (manager or admin) once nothing is undecided. Items that were not counted are left alone and listed. **Accepted shortfalls become suggested waste records** (cause "Stock count shortfall"), which a person still confirms on the Waste page. Surpluses make no record.
7. **Correct DecoNetwork** by hand using the accepted-differences list (downloadable as CSV), then **mark it as corrected**. Until then the stock-take shows "Not corrected yet".

Thresholds are in the setting `stocktake.rules`: `recount_units` 5, `recount_value` 50, `approve_value` 250, `adjust_chase_days` 3, `stale_days` 7.

## Exceptions
- *Stock-take result not put right in DecoNetwork*: closed with accepted differences, not marked corrected after 3 days.
- *Stock-take left open*: counting or in review for more than 7 days.
Both run with every exception check.

## Controls, in plain words
Blind counting stops people just confirming the number. A different person does the recount. Every difference has a reason and a name against it. Big money needs a manager. Nothing in stock moves without someone making the change in DecoNetwork. Everything is audited.

## Honest limits
- The "blind" is a control against anchoring, not against fraud: anyone on the team can still look at stock levels elsewhere in the system.
- Stock moves while you count (sales, picks). Count when the warehouse is quiet, or accept small differences with that as the reason.
- **No shelf locations are recorded yet** (none of the 1,323 SKUs has one), so "count a shelf" has nothing to match until locations are entered on the Stock page. Use the most-valuable or SKU-list scopes meanwhile.
- Customer-supplied or dummy lines show as stock: the live list's most valuable "item" is *Own Product Supplied - T-Shirt* with 999 units. Leave such items out by counting a SKU list.
- Counts are whole units per SKU. No bin/pallet-level counting, no photos on a count, no variance by lot.

## Where it lives
Migration 54 (`flow.stock_takes`, `stock_take_lines`, `stock_take_counts`; functions `flow.stocktake_*`; views `ui_stock_takes`, `ui_stock_take_lines`). n8n: actions `stocktake_start / count / review / recount / accept / accept_small / close / cancel / adjusted` in the (unpublished) Operations actions workflow. Tests: `supabase/tests/stocktake_test.sql`, `lib/stocktake.test.ts`, the stock-takes section of the dashboard e2e.
