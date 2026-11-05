# Order changes and manual overrides

## Order changes (R8)
DecoNetwork can change an order after we have started work on it. Database triggers on `flow.orders` and `flow.order_lines` log each material change in `flow.order_changes`: dispatch date (calendar-day change only), total units, DecoNetwork status moving to cancelled / refunded / on hold, the order closing, shipping method, and lines added, removed, re-quantified or re-SKU'd. Lines added within 15 minutes of an order's creation are ignored (that is the first sync).

**Severity.** `high` when real work is tied to the order (stock allocated, ready for production onwards, an active allocation, an open consignment or a bin), `warning` otherwise, `info` for shipping method.

**Effects.** A printed label whose data changed is flagged `reprint_needed`. `ui_oc_impact(order)` lists what the change touches (reserved units, consignments, bins, printed labels, running job steps, stale job packs, rework) with plain-English actions. High-severity changes raise the `order_changed` exception, which blocks completion and dispatch until reviewed. Review needs a note of at least 5 characters for high-severity changes; warnings can be dismissed without one. Reviews are audited.

**Not done.** Nothing is changed automatically: stock is not released, POs are not amended and consignments are not cancelled. The impact panel tells a person what to do. Customer messages are not drafted.

## Manual overrides (R10, safe subset)
- **Hold** (`flow.ov_hold_order`): any user who can act; reason required; refused if a job step is running or the order has shipped. The previous status is stored in `status_before_hold`. The planner skips held orders (`scheduler_input` reports `hold_reason`).
- **Release**: restores the previous status; note required.
- **Priority** (manager/admin): 0 to 3, reason required, previous value kept in the audit record.
- After a hold or priority change, re-plan production to apply it.

**Deliberately not built:** editing stock quantities or due dates in ATAM_FLOW. DecoNetwork is the source and overwrites both on the next sync, so an edit here would silently disappear. Correct them in DecoNetwork.

## Using it
Orders list has a **Changed** filter. The order drawer has a **Changes & control** tab. Actions go through the unpublished **Operations actions** n8n workflow, so buttons will not act until it is published. Reads work now.
