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

## Step 2: supplier price files (**migration 82 applied 23 Nov 2026; no real price file loaded yet**)
Supplier price files were received on 23 Nov 2026 and read.
- **Item codes match ours.** Ralawise's "Product" column is our item code exactly (28 of 30 sampled Flow codes were in the file). ORN prices are **per style**; the style is the part of our code before the first dot (1150.NV.L is style 1150; 21 of the 23 ORN styles in Flow are in the file).
- **Catalogue page: "Load a supplier's price file"** (managers and admins). Pick the layout (Ralawise or ORN), the supplier, and the Excel file as the supplier sent it. Flow keeps only items it already knows (from stock records and order lines, 2,000 or so, out of 100,000 lines in the Ralawise file), reads the supplier's title and price, and says how many known items have no price in the file. Saving updates prices already there; nothing is deleted. It goes through the existing `catalogue_import`.
  - **Ralawise:** columns Product (item code), Description (title) and the **Future Prices carton price** (the second CTN column, column K; prices in force from 1 Oct 2026).
  - **ORN:** Code, Product and the price column (BA26). The style price is applied to every ORN item code Flow knows in that style.
- **Gap:** an item Flow has never seen has no price until the file is loaded again after it first appears on a stock record or an order. Load each new supplier price file when it arrives.
- **Migration 82** adds `title` to `flow.supplier_offers`, makes `catalogue_import` store it (an empty title never clears one), shows it in `ui_catalogue`, and adds `public.ui_known_skus` (staff only). 
- **New dependency:** `read-excel-file` 9.3.15 (reads .xlsx in the browser; loaded only when a spreadsheet is picked).

## How each supplier takes orders (from the supplier emails, 23 Nov 2026)
- **Ralawise** (about 75% of what we buy): **API**. Documentation and a Postman collection were sent. Log in to get an access token (valid 20 minutes), then place orders. It is a **live system**: a test order uses the order reference `APITEST`. Login details go into n8n credentials, never into Flow or the repository.
- **ORN**: **no API**. They run an **SFTP server as an EDI route**: stock, ETA, product image and style files are read from `/ftp/stockfile/`, and orders are uploaded as a CSV to `/ftp/incoming/` (their system checks every 5 minutes and emails a confirmation). Order CSV columns: Company Reference (our account number, CPIC2197), Customer Order Reference (our PO number), Product Code (their SKU, with dots, must match exactly), Quantity, then delivery company, address lines, country, postcode, first and last name and phone; all columns must be present and filled; the file is named with the account number and a unique number. SFTP details go into n8n credentials. ORN want to be told when we are ready to place orders so they can check the first ones.
- **Other suppliers:** a Google Sheet "Supplier Log and Details" was shared; not read yet.

## Decisions and open points (22 Nov 2026)
- **DecoNetwork purchasing:** the agreed approach is to **stop pulling new DecoNetwork purchase orders and finish the open ones in Flow** (71 open, about 1,400 units still to arrive: book their goods in through Flow's goods-in). **Not switched off yet.** Before the sync is switched off we need to know **how DecoNetwork's stock levels will be topped up**, because they normally rise when goods are received against a DecoNetwork PO, and they decide "stock secured".
- **Supplier codes:** answered 23 Nov 2026: they match (see Step 2).
- **API / EDI details** for Ralawise (API) and ORN (SFTP) have arrived (see above). Next step is raising POs from the catalogue prices, then sending them. The logins must be set up as n8n credentials, never pasted into Flow or a chat.
- **Profit per order** also needs a selling price per order line, which Flow does not hold yet (only the order total).
