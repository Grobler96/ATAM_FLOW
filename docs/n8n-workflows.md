# n8n workflow map

All ATAM_FLOW workflows are prefixed `ATAM_FLOW ·`, live in the same n8n project as the existing syncs, are
**published 4 Nov 2026** (~1,200 scheduled executions/month: 720 + 240 + 240), report failures to the shared error workflow (`Shared Error Alert`), and call
Supabase through the existing `Supabase account 2` credential. No DecoNetwork credentials are used: they read the
data your existing syncs already land in Supabase.

| Workflow | ID | Schedule | Dashboard webhook (POST) | Roles |
|---|---|---|---|---|
| ATAM_FLOW · Sync orders | `CdfptK05bxoJeGEq` | hourly at :10 (after the hourly order sync) | `/webhook/atam-flow/sync-orders` | admin, manager |
| ATAM_FLOW · Sync stock | `15NSypPzcIXKcfPA` | every 3 h at :40 (after inventory sync at :10) | `/webhook/atam-flow/sync-stock` | admin, manager, warehouse |
| ATAM_FLOW · Sync purchase orders | `9mNTEKLk7lVV3d8h` | every 3 h at :50 (after PO sync at :20) | `/webhook/atam-flow/sync-purchase-orders` | admin, manager, warehouse |
| ATAM_FLOW · Production scheduler | `qpPBi8l8b1Aq2TfH` | hourly at :20 (after the orders sync) | `/webhook/atam-flow/run-scheduler` | admin, manager, production |
| ATAM_FLOW · Stock allocation | `Suo7pqWysaZSXqyX` | hourly at :55 (published) | `/webhook/atam-flow/run-allocation` | admin, manager, warehouse |
| ATAM_FLOW · Goods-in processor | `Sei0y85f1MOiIzXf` | n/a (unpublished) | `/webhook/atam-flow/goods-in` | admin, manager, warehouse |
| ATAM_FLOW · Purchasing actions | `0r4taz0NlJ3KOlO4` | n/a (unpublished) | `/webhook/atam-flow/purchasing` | admin, manager |
| ATAM_FLOW · Communications sender | `jtKw9WQmjPY8G3Vw` | every 2 h at :25 (unpublished) | n/a | n/a |
| ATAM_FLOW · Supplier discrepancy escalation | `A8r66X2xwPBfpRGF` | weekdays 08:10 (unpublished) | n/a | n/a |
| ATAM_FLOW · Artwork download and store | `kvgqKRD7dVWOJkoa` | every 15 min (unpublished) | n/a | n/a |
| ATAM_FLOW · Artwork actions | `nkOanz4G48WKPv1k` | n/a (unpublished) | `/webhook/atam-flow/artwork` | admin, manager, production |
| ATAM_FLOW · Supplier and producer selection | `9omdNalZkjKEYAy1` | n/a (unpublished) | `/webhook/atam-flow/selection` | admin, manager |
| ATAM_FLOW · Exception detector and escalation | `ZPEjWqfNDOqpDPCo` | every 30 min (unpublished) | `/webhook/atam-flow/run-exceptions` | admin, manager, warehouse, production |
| ATAM_FLOW · Exception actions | `K7aWo67bi7nqEqiQ` | n/a (unpublished) | `/webhook/atam-flow/exceptions` | all roles (write-off, cancel, reopen: manager/admin) |
| ATAM_FLOW · Production actions | `JcMSouGUgIpqqiZF` | n/a (unpublished) | `/webhook/atam-flow/production` | admin, manager, production |
| ATAM_FLOW · Verify caller (sub-workflow) | `lALM3G47uOizvD9t` | n/a | n/a | n/a |

## How a dashboard call is secured

1. Dashboard sends `Authorization: Bearer <Supabase login token>`.
2. `Verify caller` asks Supabase Auth who the token belongs to, then looks up their role in `flow.user_roles`.
3. If the role is not allowed for that workflow the webhook answers `401` (not signed in) or `403` (no permission)
   and nothing runs. CORS is limited to `https://grobler96.github.io`.

Each sync returns the JSON summary from its Postgres function (`ok`, `run_id`, counts). A scheduled run that
returns `ok:false` raises an error so Daniel and Oliver are emailed (6-hour cooldown per workflow).

## Test results (4 Nov 2026)

- Scheduled orders sync against live data: success, 0 changes (idempotent).
- Webhook with an invalid token: denied via the 401 path, sync not run.
- Not yet tested: the *allowed* path with a real user token (needs a signed-in dashboard user).

## Production scheduler (built 4 Nov 2026, **unpublished**)

Flow: `flow_scheduler_input` (Postgres) → **Code node running `packages/engine/scheduler.js`** → `flow_apply_schedule` (Postgres).
The Code node holds a copy of the engine; regenerate it with `node scripts/engine-literal.mjs` whenever the engine changes
(a Code node cannot import repo files). Tested live: first run planned 99 orders / 116 steps / 22 batches; the second run
changed nothing. Publishing it would add about 720 executions a month.

Dashboard webhooks for pins (`flow_set_schedule_override` / `flow_clear_schedule_override`) exist as database functions and still
need their own n8n webhook workflows (Phase 4).

## Stock allocation (built and published 4 Nov 2026)

Flow: `flow_allocation_input` -> Code node running `packages/engine/allocator.js` -> `flow_apply_allocation`. Regenerate the embedded engine with
`node scripts/engine-literal.mjs allocator`. Tested live: first run 175 reservations / 77 decisions; second run changed nothing.
Publishing adds about 720 executions a month. See [allocation.md](allocation.md).

## Purchasing (built 4 Nov 2026, unpublished)

See [purchasing.md](purchasing.md). Tested live: communications sender (nothing to send) and escalation (nothing overdue) ran clean. Goods-in and purchasing actions were tested in SQL; their webhooks need a signed-in dashboard user to exercise end to end.

## Artwork (built 4 Nov 2026, unpublished)

See [artwork.md](artwork.md). The download workflow ran clean live with nothing pending; the actual download and bucket upload path has not been exercised with a real file yet.

## Selection (built 4 Nov 2026, unpublished)

See [selection.md](selection.md). The access check was exercised live (invalid token refused); the recommend path needs a signed-in user and has been tested only through the database round-trip.

## Exceptions (built 4 Nov 2026, unpublished)

See [exceptions.md](exceptions.md). The detector workflow ran clean live (a repeat run changed nothing); the actions webhook has been tested through the database functions only.

## Production actions (built 4 Nov 2026, unpublished)

`pin` (position + mandatory reason) and `unpin`, calling the audited `flow_set_schedule_override` / `flow_clear_schedule_override`. Used by the Orders drawer. See [ui.md](ui.md).

## Warehouse actions (built 5 Nov 2026, unpublished)

See [warehouse.md](warehouse.md). One webhook, many actions: suggest_bin, assign_bin, move_order, release_bin, set_bin_status, create_bins, set_stock_location, generate_order_labels, generate_labels, mark_printed, print_failed. Role checks and mandatory reasons are enforced twice: in the workflow and again inside the database functions.

## Movement actions (built 5 Nov 2026, unpublished)

See [producer-movements.md](producer-movements.md). One webhook: upsert_producer, set_rate, create_movement, scan (pick/pack/dispatch and producer-side steps), record_return, check_return, direct_dispatch, resolve_discrepancy, cancel_movement.

## Machine actions (built 5 Nov 2026, unpublished)

See [machine-downtime.md](machine-downtime.md). report_downtime, update_downtime, resolve_downtime, upsert_machine.

## Supplier actions (built 5 Nov 2026, unpublished)

See [supplier-resilience.md](supplier-resilience.md). refresh_stats, add_alternative, remove_alternative, set_offer, chase_po, chase_all_late. Chases are drafts in the review queue; nothing is sent.

## Quality actions (built 5 Nov 2026, unpublished)

See [quality-rework.md](quality-rework.md). record_check, open_rework, rework (start / assign / complete / cancel / replacement), set_criterion.

## Producer risk actions and Daily housekeeping (built 5 Nov 2026, unpublished)

See [producer-risk.md](producer-risk.md). Producer risk actions: suspend, resume, record_contact, set_limits, job_sheet. Daily housekeeping runs at 06:15.

## Operations actions (built 5 Nov 2026, unpublished)

Path `atam-flow/operations`, workflow `UvnfNdHot39VL5FI`. Actions: `hold`, `release`, `priority` (manager/admin), `review_changes`. Same pattern as the others: verify caller, role check, allow-list to a `flow_*` RPC, audited. See [order-changes.md](order-changes.md).

The Operations actions workflow also handles `courier_event`, `claim_open` (manager/admin) and `claim_update` (manager/admin). See [courier.md](courier.md).
