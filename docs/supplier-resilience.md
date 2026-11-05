# Supplier resilience (resilience step R5, built 5 Nov 2026)

Chosen as the next build because, on live data, 76 of the 107 non-artwork open issues were stock shortages (61) and late POs (15). This turns "short of stock" into a recommended action with reasons.

## What a person can do
| Action | Where | Who |
|---|---|---|
| See what to do about a shortage: **wait**, **substitute**, **reorder**, **split**, or **tell the customer**, with the reasons | Stock → SKU drawer (shown only when the SKU is short) | everyone signed in |
| Approve / withdraw an alternative SKU (optionally "customer must agree") | Stock → SKU drawer | manager, admin (withdrawing needs a reason) |
| Record who can supply a SKU, at what cost, lead time, minimum and stock | Stock → SKU drawer → Add a supplier | manager, admin |
| Chase a late or unacknowledged PO: drafts an email into the review queue | PO drawer → Chase supplier | warehouse, manager, admin |
| Draft chases for every PO at least 2 days late, or sent and unacknowledged for a day | Purchasing → Draft chases for late POs | warehouse, manager, admin |
| Recalculate supplier reliability | Purchasing → Suppliers → Refresh reliability | warehouse, manager, admin |

**Nothing is sent automatically.** Chases join the existing Emails queue, are never created twice while one is waiting, and a PO chased in the last 24 hours cannot be chased again. A supplier with no email address gets a draft that says so.

## How the advice decides
1. **Wait** if enough units are already on order, due before the earliest order is due, and from a supplier that is on time at least 70% of the time (unknown history counts as fine).
2. **Substitute** if approved alternatives have enough free stock (stock minus what is already reserved). Says when the customer must agree first.
3. **Reorder** from the best supplier offer that lands before the earliest due date (most reliable first, then fastest).
4. **Split** if incoming stock and alternatives cover some but not all.
5. **Tell the customer** otherwise, with the earliest date anything could arrive.

## Reliability
A PO counts once delivered (actual date known) or already past its expected date. A supplier needs at least 3 counted POs before a percentage is shown. The result is also written to `suppliers.on_time_rate`, which the selection engine already reads. Matching of DecoNetwork POs to suppliers is by supplier name.

## n8n and database
Workflow **ATAM_FLOW · Supplier actions** (`yQV2Kio908Ec0ryU`, webhook `/webhook/atam-flow/suppliers`) is built and **unpublished**. Migrations 30 and 31. Tested in `supabase/tests/supplier_test.sql` and the dashboard e2e suite.

## Honest gaps
- **No live data to advise from yet:** no supplier offers exist and no supplier has an email, so on today's data the advice mostly says "tell the customer" until you enter offers; chase drafts will be drafts with no recipient.
- Reliability needs actual delivery dates on POs; how many DecoNetwork POs carry one is unknown until it is refreshed.
- A substitution is advice and a recorded decision only: swapping the SKU on the order in DecoNetwork is still manual.
- No automatic scheduled chasing, no price-change or invoice-mismatch handling, no offer removal (set stock to 0 for "out of stock").
