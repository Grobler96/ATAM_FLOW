# Producer movement flows (built 5 Nov 2026)

The dashboard side of third-party production: set up producers and rates, send goods, follow them through the producer, book them back and check them, with every step recorded. The underlying lifecycle functions are described in [third-party-production.md](third-party-production.md).

## What a person can do (Producers page)
| Action | Who | Notes |
|---|---|---|
| Add / edit a producer, add / change rates | manager, admin | Needs only a name to start. Methods, turnaround, capacity, direct-dispatch ability, special instructions (printed on job sheets). Rates feed the producer selection engine. Audited. |
| New movement (from Producers, Quick actions, an order bulk action, or a producer) | warehouse, manager, admin, production | Lists only lines with secured stock that are not already with a producer, filtered to what the producer can decorate. Quantity per line is capped at what can still be sent. Reserves the garments and picks a staging bin (zone OUT). |
| Pick → Pack → Dispatch | warehouse, manager, admin | Steps are strictly in order. Dispatch needs a tracking reference and starts the return clock (dispatch + 1 day + turnaround). The artwork dispatch gate still applies. |
| Producer received / started / complete / ready for return / shipped back | warehouse, manager, admin, production | Normally the producer confirms these (portal not built). Staff can record them and the log says it was entered on the producer's behalf. |
| Book return in | warehouse, manager, admin | Good / damaged / wrong per line, any number of partial deliveries. A short return is flagged before saving and opens a discrepancy automatically. |
| Check returned goods | warehouse, manager, admin | Pass releases units to ready-for-dispatch; fails become rejected discrepancies. |
| Producer shipped to customer (direct dispatch) | warehouse, manager, admin | Tracking mandatory; stock never returns to the warehouse. |
| Resolve a discrepancy | manager, admin | Outcome + note required. Nothing completes while discrepancies are open. |
| Cancel a consignment | warehouse, manager, admin | Only before it leaves (draft, picked, packed); reason required; units go back to their orders. |
| Generate labels | any editing role | Outbound, consignment, job-sheet and return content, printed from the Labels page. |

## n8n
**ATAM_FLOW · Movement actions** (`pT0lTbUUD3KMJf3D`, webhook `/webhook/atam-flow/movements`) is built and **unpublished**. Role checks happen in the workflow; the database functions enforce the same rules on state, quantities and reasons.

## Database
Migration 28: `flow.mv_upsert_producer`, `mv_set_rate`, `mv_cancel_movement` (service-role wrappers `public.flow_mv_*`), views `ui_tp_sendable_lines`, `ui_tp_items`, `ui_tp_events`, `ui_producer_rates`, `ui_producers_all`, `ui_tp_pick_list`. Tested in `supabase/tests/movement_test.sql` plus the existing `third_party_test.sql`.

## Honest gaps
- No producer portal: producers cannot confirm receipt or progress themselves yet.
- The job sheet is generated as label content but is **not emailed** to the producer.
- Photo evidence is not uploaded from the device.
- No live data: there are no producers, so nothing has been exercised against real consignments. The paths are covered by SQL tests and a mocked-backend browser test.
- The routing engine that recommends internal vs producer is not built; a person chooses.
