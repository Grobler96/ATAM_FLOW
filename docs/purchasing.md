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

## Streamlined purchasing (14 Nov 2026, migration `supabase/pending/20261114000066`, not yet applied to the live project)

- **Product catalogue** (Purchasing → Product catalogue): supplier, item code (the DecoNetwork SKU) and cost, with one **preferred** supplier per item. It reuses `flow.supplier_offers` (new column `is_preferred`). Managers and admins load it from a spreadsheet saved as CSV (`Supplier, Item code, Cost, Preferred`), or change the preferred supplier on screen. A file with any bad row imports nothing and lists the problems. Reloading updates costs and never deletes. An item with no preferred supplier gets its cheapest.
- **Raise purchase orders** (the Create PO screen): lists the orders that still need stock (`ui_order_buy_lines`: after reservations and stock already on a PO), groups every line by its catalogue supplier and delivery place, shows each PO's lines (item, product, colour, size, qty, cost, orders), and raises one PO per group. An order that needs stock from Ralawise and Portwest becomes two POs. Items not in the catalogue are offered a supplier choice, or left out.
- **Delivery is pre-set**: third-party orders go straight to their decorator, everything else to our warehouse; each PO's "Deliver to" can still be changed.
- **POs go live straight away**: the dialog sends `options.live = true`, so the PO is approved on creation (no draft, no approval rules, no limit) and the supplier email is queued. The email still waits for one click under Purchasing → Emails (and cannot send until a supplier has an address). POs created without `live` are still drafts, and the old Approve… dialog and rules still exist for them.
- After raising, a single PO opens on screen; several go to the Purchasing list.
- **Order lists**: *IH Orders* and *3PD Orders* in the sidebar show orders that have come in and still need stock bought, with a **Raise POs for these** button. *All Orders* is the old Orders page.
- **Decorator per order**: every third-party order goes to the decorator in setting `third_party.default_producer` (DPS, set by the migration if a producer with code or name DPS exists) unless changed on the order (Overview → Decorator → Change…, managers, admins and production planners). This sets who a PO delivers to; it does not yet pre-fill the Send to producer dialog.
- The new screens call the database directly (signed in, with the role check inside each function) rather than through n8n, so no n8n workflow change is needed. `create_po_for_orders` is unchanged for n8n callers apart from the new `live` option, which the existing Purchasing actions workflow passes through in `options`.
- Tests: `supabase/tests/streamline_test.sql`, `lib/poPlan.test.ts`, `lib/catalogue.test.ts`, the browser test section "order lists and catalogue".

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

Purchasing actions: `requirements, create_po_for_orders, create_po, approve_po, send_po, acknowledge_po, cancel_po, resolve_discrepancy, invoice_record, invoice_resolve, chase_scheduled, comm_edit, comm_approve, comm_cancel, comm_resend`. `approve_po` runs the approval rules below (`flow_po_approve_checked`).
Goods-in, cancelling a PO and resolving a discrepancy re-run stock allocation; approving or resending an email and sending a PO run the sender immediately.

## Approval, invoice matching and chasing (database 10 Nov 2026, screens added since)

Rules live in `flow_settings` key `purchasing.rules` and are **placeholders** until the business sets real ones: approval limit £500, an admin is needed over it, nobody approves a PO they created (an admin may, with a reason), invoices may differ by 2% or £5 (whichever is larger), scheduled chasing off (2 days late, repeat every 3 days). Migration 58, tests in `purchasing_controls_test.sql`.

On screen (open a PO on the Purchasing page):
- **Approve…** (manager or admin, draft POs) opens a dialog that shows the PO total, why approval is needed and who can approve it. A manager is stopped on a PO over the limit and told an admin is needed. Whether *you* created the PO is only known to the database, so the dialog asks it: if the creator is refused, the database's own words are shown; an admin is then asked for a reason (at least 3 characters, recorded in the audit trail) and can approve their own PO.
- **Supplier invoices** (ATAM_FLOW POs only, once approved and not cancelled): **Record invoice** takes the number, date, total before VAT, VAT and a note. The invoice is checked against the units actually received at this PO's unit costs, plus any delivery charge. The result is shown in plain words: *Matches*, *Billed too much*, *Billed too little* or *Waiting for goods*. A mismatch raises a "Supplier invoice does not match" exception (the detector runs it) until someone decides: **Accept difference** (manager or admin, reason required) or **Dispute with supplier** (reason required). A decided invoice can be reopened with a reason.
- **Settings** has a **Purchasing rules** panel that shows the values above in words. It is read-only. The scheduled-chasing switch is shown **off and disabled** with the reason: no emails are being sent yet, and chasing only ever saves drafts for review.

Pure logic for these screens (rules, the approval check, invoice wording) is in `apps/dashboard/src/lib/purchasing.ts` with unit tests; the screens are `apps/dashboard/src/components/PurchasingControls.tsx` and are covered by the browser test (`e2e/exceptions.e2e.mjs`, section "purchasing controls").

The actions go through the **Purchasing actions** n8n workflow, which is **unpublished** (publishing waits on the Communications sender and the owner's go-ahead for email). Until it is published, the buttons answer that the action is not switched on yet; the rules and invoices still read normally.

## Not built yet

- Changing the purchasing rules from a screen (no action exists; they are edited in the database), and switching scheduled chasing on.
- Price-change handling and applying a substitution in DecoNetwork (see [supplier-resilience.md](supplier-resilience.md)).
