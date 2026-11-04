# Data model (`flow` schema)

Statuses (enum `flow.order_status`): awaiting_stock · stock_allocated · ready_for_production · in_production ·
quality_check · ready_for_dispatch · dispatched · blocked · on_hold.

| Group | Tables | Idempotency key |
|---|---|---|
| Orders | `orders`, `order_lines` (one row per DecoNetwork workflow item = per size) | `deco_order_id`, `deco_workflow_item_id` |
| Stock | `stock_items`, `stock_movements` (append-only), view `v_stock_position` | `sku` |
| Inbound | `purchase_orders`, `po_lines` (`qty_outstanding` generated) | `deco_po_id`, `(po_id, line_no)` |
| Allocation | `allocations`, `allocation_decisions`, view `v_order_line_alloc` | one active row per `(line, stock, source, po_line)` |
| Warehouse | `bin_zones`, `bins`, `bin_assignments`, `bin_contents`, view `v_bins_live` | `bin_code`; one active assignment per `(bin, order)` |
| Production | `production_methods`, `machines`, `machine_shifts`, `changeover_rules`, `batches`, `batch_orders`, `job_steps` | `code`, `batch_code`, `(order, method)` |
| Labels | `labels`, `label_prints` (reprint history) | one label per `(type, order, bin)` |
| Control | `flow_settings` (weights/thresholds), `flow_runs`, `sync_snapshots`, `audit_log`, `user_roles` | |
| Mapping | `deco_status_map`, `process_code_map`, `garment_type_rules` | editable in Settings |

## Field notes

- `orders.due_date` doubles as the promised dispatch date (assumption); `shipped_at` is the actual dispatch.
- Overdue / due-today / % allocated are **computed in `v_orders_live`**, never stored, so they cannot go stale.
- Order value is DecoNetwork `billable_amount`.
- Line decoration data comes from `public.job_lines` (processes, embroidery areas, stitches per piece).
  Thread/vinyl/DTF/artwork/proof/approval fields exist (`decoration_spec`, `artwork_ref`, `proof_status`,
  `artwork_status`) but are **not populated yet**: they need an enrichment workflow reading the full DecoNetwork order JSON.
- `est_minutes`: embroidery = qty × (stitches ÷ stitches_per_minute + minutes_per_item) using the existing
  `public.job_settings`; other methods = qty × `production_methods.minutes_per_unit` (placeholder defaults).

## Sync functions (service role only)

`flow.sync_orders()`, `flow.sync_stock()`, `flow.sync_purchase_orders()` each return JSON
(`ok`, `run_id`, counts, `unmapped_process_codes`), log to `flow_runs`, take an advisory lock so overlapping runs
skip, and never rewrite unchanged rows. Failures return `{ok:false,error}` and are logged rather than lost.

Bulk-create bins: `select flow.generate_bins('STG','B12',24);` → `B12-01 … B12-24` (idempotent).
