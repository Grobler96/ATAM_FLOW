# ATAM_FLOW

Production control and warehouse allocation for ATAM's apparel decoration business: incoming stock, stock-to-order
allocation, production sequencing, bin locations and printable labels, with a live dashboard. Backend automation
runs in **n8n**; data lives in **Supabase** (`flow` schema); the dashboard is a static app on **GitHub Pages**.

> Status: **Phase 2 (data foundation) in progress.** Schema + sync functions are written and tested locally.
> See [docs/assumptions-and-open-questions.md](docs/assumptions-and-open-questions.md) for what needs confirming.

## Layout

| Path | Purpose |
|---|---|
| `supabase/migrations/` | `flow` schema: tables, seed config, source adapters + sync functions, views, RLS |
| `supabase/tests/` | Local behavioural tests (idempotency, double-allocation guard, RLS) |
| `scripts/test-db.sh` | Runs migrations + tests against a throwaway local Postgres |
| `n8n/workflows/` | Exported n8n workflows (secrets stripped) |
| `apps/dashboard/` | Main internal UI / command centre (see docs/ui.md) |
| `packages/engine/` | Reference TypeScript for scoring/scheduling with unit tests (Phase 3) |
| `docs/` | Architecture, data model, scoring/sequencing, third-party production, n8n workflow map, assumptions |

## Run the database tests

```bash
scripts/test-db.sh
```

## Secrets

Nothing secret is stored in this repo. Frontend uses the Supabase publishable key only; the service-role key and
DecoNetwork credentials live in n8n credentials. See `.env.example`.

## Where things are

- [docs/third-party-production.md](docs/third-party-production.md): outsourced production and chain of custody
- [docs/scoring-and-sequencing.md](docs/scoring-and-sequencing.md): how the production scheduler decides
- [docs/n8n-workflows.md](docs/n8n-workflows.md): workflow map and webhooks
