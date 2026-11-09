# Barcode and QR scanning

One scanner for the whole system, in the staff app and in the decorator portal. A scan only ever **opens** something; it never changes stock, status or anything else.

## Three ways to scan (all give the same result)
1. **Camera** (phone, tablet or laptop): the **Scan** button in the top bar (staff) or **Scan a parcel label** on the job list (portal). It uses the browser's built-in reader where there is one (Chrome and Android); otherwise a decoder is downloaded only when the camera is first opened (iPhone and others).
2. **Hardware scanner** (USB or Bluetooth, the kind that types): in the staff app just scan, anywhere, with nothing selected, and it opens the record. In the Scan window or portal scan box it types into the box.
3. **Typing** the code.

## What it understands
| Scan | Opens |
|---|---|
| Consignment: `TP-2026-00007`, the consignment label code (`PRO-TP-2026-00007-261109`), or the link inside the printed QR (`.../#/tp/TP-2026-00007`) | The consignment (staff); that job (portal) |
| Order: `order:#636220`, order label code (`ORD-636220-261109`), the order QR link, or a bare order number | The order |
| Bin: `bin:A-01-03` or the bin QR; a bare bin code is recognised if the bin exists | The bin |
| Stock item: `sku:POLO-NVY-M`; a bare SKU is recognised if the SKU exists | The stock item |
Anything else says "That code was not recognised". The reading rules are in `src/scan/parse.ts` with unit tests.

## Decorator portal
Only consignment labels make sense there. A parcel that is not one of the decorator's own jobs is refused ("not one of your jobs") and nothing opens; the server independently refuses access to any job that is not theirs.

## Not built yet
Scanning that performs a step (pick, pack, dispatch, receive back) straight from the scan: today a scan opens the consignment and the step is done with the buttons there. Per-garment barcodes and scanning to count units at check-in (garments carry no ATAM barcode). The camera path is covered by a start-up check with a fake camera, not by decoding a real printed code in automated tests: please try it once on the real phones and labels.
