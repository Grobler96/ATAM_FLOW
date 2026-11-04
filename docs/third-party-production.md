# Third-party production and chain of custody

Some orders are decorated by outside producers. ATAM_FLOW buys and books in the blanks, then tracks them to the producer and back
(or on to the customer). **Every unit stays traceable to its order line: where it is, who holds it, and what is owed back.**

## Built (live since 4 Nov 2026, tested by `supabase/tests/third_party_test.sql`)

| Piece | Where |
|---|---|
| Producers (contact, capabilities, capacity, turnaround, rate card ref, direct-dispatch flag) + scorecards | `flow.producers`, `flow.producer_stats` |
| Routes (internal / producer / direct, recommended → confirmed) and the 18-step order status chain | `flow.production_routes`, `flow.route_lines`, `flow.tp_status` |
| Movements: outbound, return, direct dispatch, correction, with items, scans and evidence | `flow.tp_movements`, `tp_movement_items`, `tp_movement_events` |
| Discrepancies: shortage, overage, damaged, rejected, late, lost | `flow.tp_discrepancies` |
| Chain of custody: 13 location states per order line + append-only ledger | `flow.stock_custody`, `flow.custody_events` |
| Dashboard read models | `v_tp_movements_live`, `v_tp_orders`, `v_producer_held_stock`, `v_custody_summary`, `v_tp_open_discrepancies` |

## Lifecycle (each step is one database function; n8n calls the `public.flow_*` wrapper)

1. `create_outbound_movement` – validates stock is secured and not over-sent, creates the TP-YYYY-NNNNN movement, route, pick list and a staging bin
   (zone `OUT`). Units are reserved in custody for the consignment.
2. `tp_scan` events, **in order**: `picked` → `packed` → `dispatched` (expected return = dispatch + 1 day + turnaround) → `received_by_producer`
   (turnaround clock restarts) → `production_started` → `production_complete` → `awaiting_return` → `return_dispatched`. Wrong-order scans are refused.
3. `tp_record_return` – any number of partial deliveries; records good / damaged / rejected by SKU, colour, size; opens or updates a shortage
   discrepancy automatically (and closes it when the rest arrives); flags overages; returns recommended actions (wait / chase / reorder / split).
4. `tp_check_return` – goods-in check releases units to *ready for dispatch*; failures become rejected discrepancies.
5. `tp_direct_dispatch` – the producer ships to the customer: tracking mandatory, proof of delivery stored, stock never returns to our warehouse.
6. `tp_resolve_discrepancy` – needs a note; resolutions: received later, replaced, credited, accepted, written off.
7. `tp_overdue_check` – raises one *late* exception per overdue movement (idempotent) and returns the list for notifications.
8. `order_completion_check` – **nothing completes while anything is unaccounted for**: open discrepancies, units with or travelling to/from a producer,
   unchecked or undispatched units, or routed units neither dispatched nor formally written off.
9. `refresh_producer_stats` – open jobs, units held / in transit, value held, on-time rate, average turnaround, late returns, discrepancy rate, orders blocked.
10. `tp_label_payloads` – outbound carton label, consignment label, per-order bag labels, producer job sheet and return checklist (QR text `tp:<code>`).
11. `tp_reconcile_shipped` – when DecoNetwork shows an order shipped, checked units leave custody as dispatched.

## Stock rules enforced

- Producer-held and in-transit stock exists only in `stock_custody`; it is never part of available warehouse stock.
- An allocation stays reserved while its goods are out with a producer (conservative: available stock can only be understated, never overstated).
- Every move is a ledger row (`custody_events`); the ledger and the scan log cannot be edited.
- Partial returns never close a movement or an order; damaged units free up the requirement so replacements can be sent.

## Assumptions (change in the database/Settings)

- Turnaround is counted in calendar days from the producer confirming receipt; transit is assumed to be 1 day each way.
- Direct dispatch requires `can_direct_dispatch` on the producer.
- The warehouse creates bins for zones `OUT` (outbound staging) and `RET` (returns), e.g. `select flow.generate_bins('OUT','OUT',6);`.

## Still to build

1. **Routing engine** (the allocation engine is built: see allocation.md) (internal vs which producer vs split vs hold, with reasons) – routes are
   currently created when a consignment is created; the engine will create *recommended* routes for a manager to confirm.
2. **n8n workflows**: Third-Party Dispatch / Outbound Movement, Producer Receipt Confirmation, Producer Return Processing, Exception Handler
   (notifications), Producer Performance Sync, plus the overdue-return alert schedule.
3. **Dashboard**: Third-Party Production page, KPIs, quick actions, scanning UI.
4. **Printing**: render the label payloads (A4 and thermal), job sheet email to the producer, photo/document upload to the movement `evidence`.
5. **Scheduler integration**: exclude third-party-routed lines from the internal schedule.
