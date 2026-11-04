# Stock allocation engine (v1)

Code: `packages/engine/allocator.js` (pure function, 13 unit tests). Postgres assembles the input (`flow.allocation_input()`), n8n runs the
engine (**ATAM_FLOW · Stock allocation**, `Suo7pqWysaZSXqyX`), Postgres stores the plan (`flow.apply_allocation()`). Weights and thresholds are in
`flow.flow_settings` (`allocation.weights`, `allocation.thresholds`).

## What it decides

**Demand:** lines of orders whose DecoNetwork status maps to *awaiting stock* (9 awaiting stock, 8 awaiting purchase order) and that DecoNetwork has
not already secured. **Supply:** free on-hand stock (DecoNetwork's level, already net of orders it has secured) plus outstanding purchase-order
units. **Exact SKU matching only** (no substitutes).

The engine repeatedly picks the order with the best *current* score, reserves what it can, and updates the pools:

| Score term | Default | Meaning |
|---|---|---|
| due date | 0-30 | rises as the due date nears (14-day horizon) |
| overdue | 25 + 2/day (max +25) | already past due |
| VIP / manual priority | 15 / 8, 20, 40 | VIP flag; high, rush, critical |
| order value, order age | up to 10, 5 | £2,000 cap; 30-day cap |
| completes the order from stock | +20 | stock on hand covers every line |
| share of order covered | up to 10 | |
| fully covered incl. incoming POs | +12 | order can be completed once POs land |
| stock scarcity | up to -8 | nudges orders that would swallow a big share of scarce stock |
| production feasibility, complexity | up to +10, -5 | machines exist for its methods; very high stitch counts |

## Outcomes (each with a plain-English reason)

- **Allocate:** stock on hand covers the whole order. "Allocated first: overdue by 3 days, 100% of stock on hand, completes the full order."
- **Partial:** at least 50% on hand (or the order is due within 2 days): reserve what exists.
- **Hold:** below the threshold, or only incoming POs: nothing is reserved on hand; incoming PO units are reserved so competing orders cannot take them.
  "Held: 100% of the order can be covered; due Fri 06 Nov. 76 units reserved from PO 876829. Projected ready Sat 07 Nov, AFTER the due date."
- **Blocked:** no stock and no PO. The missing items go on the purchasing list (`flow.v_shortages`).

Each order also gets a **projected ready date** (its slowest line) and a **late-risk** flag. POs already past their expected date are assumed to
arrive in 3 days (`overdue_po_assume_days`) and the order is flagged "some of those POs are overdue".

## Rules that keep it safe

- A database trigger refuses any reservation that exceeds on-hand stock or a PO line's outstanding units; double-allocation is impossible.
- Re-running with the same inputs changes nothing (tested on live data: second run created 0, released 0, recorded 0).
- When DecoNetwork moves an order on (e.g. to Ready for production) its reservations here are released and a *release* decision is recorded.
- Manual allocations (`flow.manual_allocate`, reason required) are never touched by the engine, which plans around them; every manual action is audited.
- The engine only reserves **inside ATAM_FLOW**. It never changes DecoNetwork; when an order is fully allocated the action is "release it in DecoNetwork".

## Read models

`flow.v_allocation_board` (every waiting order, decision, reasons, projected ready date), `flow.v_shortages` (purchasing list),
`flow.v_overdue_pos` (POs to chase, with the orders waiting on them), plus `flow.allocation_decisions` (full audit trail).

## First live run (4 Nov 2026)

77 orders considered: 45 held waiting on POs (24 fully covered once POs arrive, 18 of those on time), 30 blocked (376 units with no stock and no PO),
2 partial, 0 fully allocatable from stock on hand. 1,077 units reserved from POs; 708 units across 174 SKUs still uncovered; 16 POs overdue.

## Known limits

Exact SKU only; PO lines are matched by SKU, not by the order they were raised for (the stored PO data has no order link); on-hand stock may include
units DecoNetwork earmarked for an order that is still awaiting other lines (open question); supplier stock feeds are not used as supply.
