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

## Pending

- `supabase/pending/…_flow_caller_role_json.sql` makes the role lookup return an object. Optional hardening;
  the verify workflow already accepts both shapes.
