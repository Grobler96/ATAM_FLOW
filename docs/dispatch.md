# Dispatch queue and courier labels

The worklist and paperwork for sending finished orders to customers. **ATAM_FLOW does not book couriers and does not mark orders shipped**: there is no courier connection and DecoNetwork stays the place an order is shipped. This page is for knowing what is ready, packing it, labelling it and proving it left.

## The queue (Dispatch page, `#/dispatch`)
One row per order that has something ready to go out, or has been packed. Opens on **Ready to pack**. Stages:
| Stage | Meaning |
|---|---|
| Ready to pack | Checked units are in the warehouse and nothing blocks it (a "partly" tag means only some units are back from the decorator) |
| Blocked | The reason is shown in plain words: no checked units yet, open discrepancy with a decorator, an open issue that blocks dispatch (including the holding pen), or the order is not at "ready for dispatch" |
| Packed | Parcels and labels made; still here |
| With courier | Every parcel has been handed over |
| Shipped | DecoNetwork shows it shipped (kept visible for 3 days) |
Readiness comes from the same completion check the rest of the system uses (`flow.dispatch_state`), so the queue and the rules cannot disagree. Orders not sent to a decorator are ready when their status is "ready for dispatch" and no issue blocks dispatch. The third-party focus bar applies here too.

## Packing and the courier label
- **Pack and make labels:** number of parcels (1 to 20), optional weights, courier (defaults to the order's DecoNetwork shipping method), service, a note. Each parcel gets a label code like `DSP-636220-1of3`.
- **Not ready?** Packing is refused with the reasons. A **manager or admin** can send it anyway with a written reason (5+ characters); that is audited (`dispatch_pack_override`) and shown on the parcel. Everyone else is told who can.
- **The label** (thermal 100 × 150 mm or A4): the delivery address exactly as DecoNetwork has it, order number, customer PO, shipping method, weight, note, "Parcel 1 of 3", a Code 128 barcode and a QR code of the label code. A **collection** gets a big COLLECTION label with the customer's name and no address. Reprints say REPRINT.
- **Printing:** after the print window, confirm "Yes, they printed". Printing again needs a reason. (Same rule as the warehouse labels.)
- **Cancel packing** (reason required) before anything has left: the old labels become void, and a scan of one is refused ("This label was cancelled").

## Tracking
Book the courier in the courier's own system, then type the tracking number against the order (every parcel, or one parcel). Stored per parcel; shown in the queue.

## Handing over by scanning
**Hand over (scan)** opens a window that stays open: scan each parcel label (camera, hardware scanner or typing) and each scan records the hand-over (who, when). It says how many parcels are left, and warns on the last one if tracking has not been entered. Scanning twice is harmless. **Each hand-over re-checks the order**: if a new blocking issue appeared since packing, the parcel is held; a manager can hand it over anyway with a written reason. Scanning a parcel label *anywhere else* only opens the order (no hand-over).
After the last parcel: mark the order shipped in DecoNetwork with the tracking number. ATAM_FLOW notices on the next sync and moves the stock records on (existing reconcile step).

## Who can do what
Packing, printing, tracking, hand-over and cancelling: admin, manager, production, warehouse (checked in the Operations actions workflow and again in the database). Viewers can look. Sending something that is not ready: manager or admin only, with a reason. All actions are audited.

## Where it lives
Migration 52: `flow.dispatch_parcels`, `flow.dispatch_state`, `flow.dispatch_address`, actions `flow.dispatch_pack / printed / set_tracking / handover / cancel` (service role only, via `public.flow_dispatch_*`), views `ui_dispatch_queue`, `ui_dispatch_parcels`. n8n: actions `dispatch_pack`, `dispatch_printed`, `dispatch_tracking`, `dispatch_handover`, `dispatch_cancel` in the (unpublished) Operations actions workflow. Tests: `supabase/tests/dispatch_test.sql`, the dispatch section of the dashboard e2e, `lib/dispatch.test.ts`.

## Not built / honest limits
- No courier booking, no courier label from the courier (the label here is a delivery label with the address, not one that carries the courier's own barcode, so couriers that insist on their own label still need it from their system), no automatic tracking, no writing tracking back to DecoNetwork.
- DecoNetwork gives one free-text address block and no phone or email, so the label has no phone number.
- Layout checked on screen only, not on a physical printer. Please print one on the real thermal printer and scan it with the real scanner.
- Weights are optional and informational. No parcel size, no insurance value, no customs data for export orders.
- Partial shipments of one order are possible (the units that are ready), but the system does not yet track "parcel 1 shipped now, the rest later" across two packing rounds.
