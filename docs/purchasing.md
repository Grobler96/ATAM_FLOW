# Purchasing, goods-in and supplier discrepancies

Built 4 Nov 2026 (migrations 16-17, tested by `supabase/tests/purchasing_test.sql`).

## What it does

1. **Needs**: `flow.po_requirements(order_ids)` lists what each waiting order line still has to buy, after on-hand reservations and units already on a PO.
2. **Create a PO** from one or many orders (`create_po_for_orders`). Identical SKUs merge into one PO line; every source order line is kept in `po_line_sources`
   so each unit is traceable. Pass `options.skus` to buy only some SKUs here and the rest from another supplier (split). Refs are `AF-PO-1001`, `1002`...
   Costs come from the request, then `supplier_offers`, then `public.sku_costs` if it exists. A PO cannot be approved while any line has no cost.
3. **Approve -> send -> acknowledge** (`approve_purchase_order`, `send_purchase_order`, `acknowledge_purchase_order`). Sending only *queues* the email; the PO becomes
   `sent` when the message really goes out. `cancel_purchase_order` needs a reason and is refused once goods are booked in.
4. **Goods-in** (`book_in_goods`): per line good / damaged / incorrect quantities, condition, batch, notes and photo links. Stock rises by the units actually received
   (`stock_items.qty_pending_receipt`, which falls away once DecoNetwork catches up, so nothing is double counted). `final:false` records a partial delivery with no complaint.
   A final delivery that is short marks the line short-shipped and opens a `supplier_discrepancies` row with the affected orders and a required-by date
   (earliest affected due date minus `dispatch_buffer_days`, between tomorrow and 7 days).
5. **Supplier email** (`compose_supplier_discrepancy_comms`): one message per PO and discrepancy type, subject `Stock Shortage - ATAM_FLOW PO AF-PO-1042`,
   SKU / product / colour / size / ordered / received / shortage, affected orders and due date, replacement-or-credit request, reply-by date, signed
   `ATAM FLOW Production Control`. Damaged, incorrect and over-delivery use the same structure.
6. **Resolution** (`resolve_supplier_discrepancy`): replacement promised (raises `qty_replacement_due`, so the next delivery clears it with no new complaint),
   replacement received, credit issued, cancelled, accepted or manual. A note is mandatory. The PO closes when nothing is outstanding and nothing is open.
7. **Escalation** (`supplier_discrepancy_check`): once a discrepancy is past its required-by date, one escalation email is queued and the team is notified. Idempotent.

**Deliver straight to a decorator (11 Nov 2026):** the Create PO dialog now asks where the stock goes: our warehouse (default) or straight to a chosen decorator. Stock delivered to a decorator is booked in against the decorator and never enters warehouse stock. The supplier should be marked as able to deliver to a producer (the dialog warns if not).

## Communication log

Every outbound message is a row in `flow.communications` (draft / pending_review / approved / sending / sent / failed / cancelled).
**Default is review-first**: nothing leaves until someone approves it (`comm_approve`), and it can be edited (`comm_edit`), cancelled or resent first.
To send a kind automatically, set `comms.settings.review_required.<kind>` to `false` (kinds: po_send, shortage, damage, incorrect, overage, escalation, producer_job).
A message with no recipient stays a `draft` and raises a notification. Suppliers need email addresses (all nine seeded suppliers currently have none).
The sender claims messages (`comms_claim_to_send`), so two runs can never send the same one; a claim abandoned for 15 minutes is retried.

## Stock rules

`guard_allocation`, `allocation_input`, `v_stock_position`, `v_shortages` and `v_overdue_pos` use the effective figures
(on hand = DecoNetwork + pending receipt, PO outstanding = `qty_outstanding_eff`, which excludes short, damaged and incorrect units and adds promised replacements).
Goods delivered straight to a producer (`deliver_to = producer`) never enter warehouse stock.

## n8n workflows (all unpublished)

| Workflow | ID | Trigger | Roles |
|---|---|---|---|
| ATAM_FLOW · Goods-in processor | `Sei0y85f1MOiIzXf` | POST `/webhook/atam-flow/goods-in` `{po_id, receipt}` | admin, manager, warehouse |
| ATAM_FLOW · Purchasing actions | `0r4taz0NlJ3KOlO4` | POST `/webhook/atam-flow/purchasing` `{action, params}` | admin, manager |
| ATAM_FLOW · Communications sender | `jtKw9WQmjPY8G3Vw` | every 2 h at :25, or called by the others | n/a |
| ATAM_FLOW · Supplier discrepancy escalation | `A8r66X2xwPBfpRGF` | weekdays 08:10 | n/a |

Purchasing actions: `requirements, create_po_for_orders, create_po, approve_po, send_po, acknowledge_po, cancel_po, resolve_discrepancy, comm_edit, comm_approve, comm_cancel, comm_resend`.
Goods-in, cancelling a PO and resolving a discrepancy re-run stock allocation; approving or resending an email and sending a PO run the sender immediately.

## Still to build for this brief

Artwork sync and job packs (needs a DecoNetwork API sample), supplier and producer selection engine, producer portal, dashboard pages.
