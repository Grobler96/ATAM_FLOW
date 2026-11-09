# Warehouse flows (built 5 Nov 2026)

What a person can now do without leaving the dashboard, and exactly where the line is between built and not built.

## Bins (Warehouse / Bins page)
| Action | Where | Rule | Audited |
|---|---|---|---|
| Create bins (zone + prefix + count + optional capacity) | Create bins | Prefix 1–8 letters/digits, up to 200 at a time; numbering continues after the last bin with that prefix; repeat runs never duplicate | yes |
| Put an order away | Put order away / Put away | Suggests a bin and says why (keeps an order together, prefers the staging zone, tightest fit). One order per bin and capacity are rules: breaking one needs a **manager/admin override with a reason** (5+ characters) | yes |
| Release an order / empty a bin | Bin drawer | A reason is required. History is kept (`released_at`), nothing is deleted | yes |
| Move an order between bins | Bin drawer → Move | Same rules as put-away; refused (not overridden) from this screen | yes |
| Flag “needs emptying”, mark available, retire | Bin drawer | Reason required; an occupied bin cannot be made available or retired; retiring is manager/admin only | yes |
| Set a stock shelf location | Stock locations tab | Free text per SKU | yes |
| Find anything physical | Search box on the page | Bin code, order ref, customer, SKU, stock location, producer movement, label code (`ui_wh_find`) | – |

## Labels (Labels page)
Types: order, pick list, bin, stock, producer movement, dispatch. Each label stores its content (`payload`), a QR payload and a version.
- QR content is `order:<ref>`, `bin:<code>`, `sku:<sku>`, `tp:<movement>`. Once `labels.base_url` in Settings is set to the final dashboard URL, order QR codes become links to the order.
- Generating again is safe: unchanged labels are left alone. If a label that was already printed changes (for example units added to a bin), it gets a new version, goes back to “awaiting print” and its order shows “reprint needed”.
- Print: choose A4 (two labels across) or thermal 100 × 150 mm, copies, preview, then the browser print dialog opens. **Afterwards you confirm it printed**, and only then is it recorded. “It failed” leaves the label in the awaiting-print list.
- Printing a label that was already printed is a reprint and needs a reason. Every print/reprint is in the Print history tab (who, when, paper, copies, reason).

## Goods in (Goods in page)
Pick an ATAM_FLOW purchase order, enter good / damaged / wrong-item quantities per line, batch ref, whether more is still coming, delivery reference and notes. The existing `book_in_goods` function updates stock, raises supplier discrepancies for shortages/damage, queues the supplier email for review, and the workflow re-runs allocation.
Not built: uploading photos from the device (paste links for now; needs a storage bucket), and putting received stock into specific shelf bins (use the stock-location tab).

## n8n
Workflow **ATAM_FLOW · Warehouse actions** (`4Xded7FvZRUeqr06`, webhook `/webhook/atam-flow/warehouse`) is built and **unpublished**. Roles admin/manager/production/warehouse; creating bins admin/manager/warehouse; overrides and retiring bins admin/manager. Until it is published the pages show “not switched on yet” when you try an action; reading data works already.

## Database
Migrations 26–27. Functions `flow.wh_*` (service-role wrappers `public.flow_wh_*`), views `ui_bin_assignments`, `ui_orders_to_bin`, `ui_label_prints`, `ui_stock_locations`, extended `ui_bins` / `ui_labels`, search `ui_wh_find`. Tested in `supabase/tests/warehouse_test.sql` and the dashboard e2e suite (mocked backend).

## Honest gaps
- No real-printer test; label layout verified on screen only, not on a physical thermal printer.
- Scanning is built: see [scanning.md](scanning.md).
- Bin assignment is per order (with optional per-line contents); it is not tied to individual stock units.
- Producer-movement creation is still not built, so producer labels exist only for movements that already exist.
