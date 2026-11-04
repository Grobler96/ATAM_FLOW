# Architecture

```
DecoNetwork ──(existing n8n syncs)──► public.* tables ──(source adapters)──► flow.* ◄── Dashboard (GitHub Pages)
                                                                              ▲   reads via Supabase JS + RLS
              n8n engines: sync, allocation, scheduler, bins, labels ─────────┘
              dashboard actions ──► n8n webhooks (JWT-verified) ──► flow.* RPC / writes (service role)
```

## Decisions

- **Supabase (Postgres) is the system of record**, in the existing `N8N_Daniel_Spooner` project, in its own `flow`
  schema. Nothing in `public` is modified. Allocation needs transactions, row locks and constraints that Airtable cannot give.
- **Reuse the existing DecoNetwork syncs.** `public.upcoming_orders`, `sales_order_lines`, `job_lines`,
  `sku_inventory`, `purchase_orders` already refresh every 30 min to 3 h. ATAM_FLOW maps them through
  `20261104000003_flow_source_adapters.sql`. That is the only file coupled to those tables.
- **Ownership split.** Sync overwrites *source* fields only. Anything decided inside ATAM_FLOW (status after insert,
  priority, VIP, notes, allocations, bins, labels) is never touched by a re-sync.
- **Stock is reserved internally.** DecoNetwork inventory is read-only for v1 (decision: keep allocation inside
  ATAM_FLOW). `qty_on_hand` is DecoNetwork's figure; reservations live in `flow.allocations`.
  `available = on_hand − active reservations`; **incoming PO stock is tracked separately and never counted as available.**
- **Double-allocation is impossible at the database level**: a trigger locks the stock row and rejects any active
  allocation that would exceed on-hand (or a PO line's outstanding quantity). A partial unique index makes engine
  re-runs upsert rather than duplicate.
- **Auditability.** Every engine run is a `flow_runs` row; every automated decision is an `allocation_decisions` row
  with reason + score breakdown; stock changes are an append-only `stock_movements` ledger.
- **Access.** Browser reads under RLS (`flow.user_roles`: admin/manager/production/warehouse/viewer). Browser
  cannot call sync/engine functions; those are service-role only (n8n). Existing ATAM GO superusers are seeded as admins.
- **Dashboard** (Phase 4): Vite + React + TypeScript, built to static files and deployed to GitHub Pages (hash routing,
  base path set for the repo). Mobile/tablet first.
