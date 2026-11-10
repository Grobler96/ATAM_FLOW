# ATAM_FLOW

Production control and warehouse allocation for ATAM's apparel decoration business: incoming stock, stock-to-order
allocation, production sequencing, bin locations and printable labels, third-party decorator work, dispatch, quality and
exceptions, with a live dashboard and a separate sign-in portal for decorators. Backend automation runs in **n8n**; data
lives in **Supabase** (`flow` schema); the dashboard is a static app on **GitHub Pages**.

> **Status (10 Nov 2026): built, live, and launching for third-party decorator work only.** Database migrations 1-61 are
> applied and match this repo. In-house production is built but switched off (an audited switch). Several things still need
> the owner's input before real use (decorators and rates, staff roles, supplier emails, QC checklist items).
> **Read [docs/handoff.md](docs/handoff.md) first** for the rules, pitfalls and honest gaps, then
> [docs/launch-checklist.md](docs/launch-checklist.md) for what is left before real use.

## Layout

| Path | Purpose |
|---|---|
| `supabase/migrations/` | `flow` schema: tables, seed config, source adapters, sync and business functions, views, RLS, security hardening (migrations 1-61) |
| `supabase/tests/` | Local behavioural tests, one suite per feature (idempotency, double-allocation guard, RLS, permissions) |
| `scripts/` | `test-db.sh` runs every migration and test against a throwaway local Postgres; `check-n8n-exports.mjs` blocks secrets in n8n exports; round-trip and engine helper scripts |
| `n8n/workflows/` | Copies of the live n8n workflows (Verify caller, the action webhooks, exception detector, priority-flag sync), secrets stripped; how to restore one is in [docs/n8n-workflows.md](docs/n8n-workflows.md) |
| `apps/dashboard/` | The staff command centre (`index.html`) and the decorator portal (`portal.html`), see [docs/ui.md](docs/ui.md) and [docs/producer-portal.md](docs/producer-portal.md) |
| `packages/engine/` | Pure JavaScript (no I/O) for scoring, allocation and scheduling, with unit tests; embedded in n8n Code nodes |
| `docs/` | Architecture, data model, one page per feature, security audit, handoff, launch checklist, assumptions |
| `.github/workflows/` | CI (engine, dashboard, browser tests, database, n8n exports) and the GitHub Pages deploy |

## Run the tests

```bash
bash scripts/test-db.sh                         # database: every migration and SQL suite
cd packages/engine && npm test                  # engines
cd apps/dashboard && npm ci && npm test && npm run build
npm run e2e && npm run e2e:portal               # real browser, mocked backend (needs Playwright; run after a build)
```

The browser tests run against a fully mocked Supabase and n8n, so they cannot catch a permission problem: check views as the real role.

## Secrets

Nothing secret is stored in this repo. The dashboard uses the Supabase publishable key only (public by design; row-level
security decides what anyone can see); the service-role key and DecoNetwork credentials live in n8n credentials. See
`.env.example` and [SECURITY.md](SECURITY.md).

## Where things are

- [docs/handoff.md](docs/handoff.md): where the project stands, standing rules, pitfalls and known gaps
- [docs/launch-checklist.md](docs/launch-checklist.md): what is done and what the owner still has to supply
- [docs/architecture.md](docs/architecture.md): how the pieces fit
- [docs/third-party-production.md](docs/third-party-production.md): outsourced production and chain of custody
- [docs/scoring-and-sequencing.md](docs/scoring-and-sequencing.md): how the production scheduler decides
- [docs/n8n-workflows.md](docs/n8n-workflows.md): workflow map, webhooks and restore steps
- [docs/security-audit-2026-11.md](docs/security-audit-2026-11.md): the independent security audit and its fixes
- [docs/assumptions-and-open-questions.md](docs/assumptions-and-open-questions.md): what still needs confirming
