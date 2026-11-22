# Buying stock in Flow

Started 22 Nov 2026. The plan: stock is bought from **Flow** instead of DecoNetwork, with the right buying prices on every purchase order, so profit per order can be worked out later, and ordering moves to **API or EDI** where the supplier offers it (Ralawise and ORN first; the others are being found out).

Steps, in this order: **1 supplier cards** (this change), **2 the catalogue** (supplier item code, title and unit price from each supplier's price file), **3 raising purchase orders** from those prices, then sending them by API/EDI.

## What exists already (before this change)
- `Purchasing` has purchase orders, goods-in, supplier discrepancies, the outgoing email queue, a read-only supplier comparison and a **product catalogue** (supplier, our item code, cost, preferred supplier, loaded from CSV).
- Create PO groups what each order still needs by its catalogue supplier and raises one PO per supplier and delivery place. See `docs/purchasing.md`.
- On 22 Nov 2026 the live data showed **no buying price on any of the 2,467 purchase order lines** (DecoNetwork's PO sync does not bring prices), only 2 catalogue prices (the practice supplier), and no real supplier with an email address or a delivery cost.

## Step 1: supplier cards with delivery options (**migration 81 applied 22 Nov 2026; no card edited by a real person yet**)
- **Suppliers** page (sidebar, Stock & buying; `g` then `9`): a card for each supplier showing how we order from them, contact, usual days to deliver, minimum order, delivery options and how many items are in the catalogue, with a plain-words warning for what is still missing (no email address when we order by email, no delivery option, no catalogue prices). Search, and a tick to show suppliers that are switched off.
- **A card holds:** name, contact, phone, email (orders are sent here when we order by email), our account number, website, address, payment terms, usual days to deliver, minimum order, **how we order** (email, API, EDI, their website, phone, other) with notes, other notes, whether they can deliver straight to a decorator, and whether the supplier is in use. **API or EDI keys and passwords are never kept in Flow**: they go in n8n's credentials; the notes only say where to find them.
- **Delivery options:** any number per supplier (for example Standard, Next day, Pallet), each with a cost, a "free over" amount, days to arrive and an order-by (cut-off) time. One is the default; the first option added is the default automatically; switching the default off promotes the cheapest other one. Options are switched off, never removed. The default option keeps the older single delivery fields on the supplier in step, so nothing that already reads them changes.
- **Who:** managers and admins add and change suppliers and options; everyone else can look. The dashboard calls database functions that check the role themselves (the same way as the catalogue), so **no n8n change is needed**.
- **Database:** migration 81 adds order method, ordering notes, account number and website to `flow.suppliers`, the table `flow.supplier_shipping_options`, private functions `supplier_save`, `supplier_shipping_save`, `supplier_sync_shipping`, the two callable wrappers `public.supplier_save` and `public.supplier_shipping_save`, and the views `ui_supplier_cards` and `ui_supplier_shipping`.

## Decisions and open points (22 Nov 2026)
- **DecoNetwork purchasing:** the agreed approach is to **stop pulling new DecoNetwork purchase orders and finish the open ones in Flow** (71 open, about 1,400 units still to arrive: book their goods in through Flow's goods-in). **Not switched off yet.** Before the sync is switched off we need to know **how DecoNetwork's stock levels will be topped up**, because they normally rise when goods are received against a DecoNetwork PO, and they decide "stock secured".
- **Supplier codes:** not yet known whether suppliers' item codes match our product codes (1150.NV.L = style, colour, size). Needed before the catalogue loader: a sample price file from Ralawise and ORN.
- **API / EDI details** for Ralawise and ORN are needed for step 3 and must be given through n8n's credentials, never pasted into Flow or a chat.
- **Profit per order** also needs a selling price per order line, which Flow does not hold yet (only the order total).
