# Dashboard

> The dashboard has grown into the full internal command centre: see [ui.md](ui.md). This file keeps the publishing steps and the original Exceptions-page notes.

`apps/dashboard`: Vite + React + TypeScript, static build, hash routing, mobile first. First page: **Exceptions & issues**.

## What the Exceptions page does

- **Opens on what needs attention**: critical and overdue first. On a phone the controls are compact so the first issue is on the first screen.
- Summary tiles (open, critical, high, overdue, blocking, no owner, £ at stake); the tiles for overdue, blocking and no-owner are also filters.
- Groups: Critical, **Orders at risk**, **Stock shortages**, **Producer delays**, **Machine downtime** (shows 0: not tracked yet), **Missing artwork**, **Quality failures** (0: not tracked yet), **Courier issues**,
  **Unresolved discrepancies**, Data & systems. An **age** filter (under 1 day, 1-3, 3-7, over 7 days), search (order, SKU, PO, person), sort (critical first, deadline, oldest, biggest £), "Mine", and CSV export of the current list.
- Each card shows severity, type, plain-English description, linked orders / SKUs / POs / movements / producers, owner (or who is responsible if nobody is named), deadline (overdue in red), status, age, money at stake, and what it blocks.
- Opening an issue shows the recommendation, customer impact, financial breakdown, escalation level, full history, and the actions: take it / assign, set status, add note or action taken, resolve (method + note required),
  and for managers and admins: not a real issue, write off (amount + reason). **Raise an issue** creates a manual one, optionally linked to an order number.
- **Check now** runs the detectors immediately. The page refreshes itself every minute and when the tab regains focus.
- Honest states: loading, empty ("nothing is wrong right now"), error with retry, **offline** banner showing the last data, and a warning if the automatic check has not run for 90 minutes. View-only users see no action buttons.

## How it is secured

Sign-in uses the existing Supabase accounts (the same people as ATAM GO). The page reads only the `public.ui_*` read-only views, which apply the signed-in person's own access (row-level security): anyone without an ATAM_FLOW role sees nothing, and anonymous users are refused.
Actions go through the n8n webhook `/atam-flow/exceptions`, which re-checks the Supabase login and role on every call (write-off, cancel and reopen: manager or admin only). The Supabase publishable key in the code is public by design.

## Run it

```bash
cd apps/dashboard
npm install
npm run dev          # local
npm test             # unit tests (filters, formatting, CSV)
npm run build        # type-check + production build into dist/
npm run e2e          # browser test with a mocked backend; writes screenshots to e2e/shots (needs the Playwright browser)
```

## Publish it (one-time steps for you)

1. Merge the pull request into `main`.
2. In the GitHub repo: **Settings -> Pages -> Build and deployment -> Source: GitHub Actions**.
3. The workflow `Deploy dashboard to GitHub Pages` builds and publishes it; the address will be `https://grobler96.github.io/ATAM_FLOW/` (the workflow run shows the exact URL).
4. Publish the n8n workflows the page uses (see below). Until then the page loads and reads data, but buttons that act explain that they are "not switched on yet".

Users need a row in `flow.user_roles` (admin, manager, production, warehouse or viewer). Currently only the existing superusers have one.

## n8n workflows the page uses (all currently unpublished)

| Button | Workflow |
|---|---|
| Check now | ATAM_FLOW · Exception detector and escalation (`/atam-flow/run-exceptions`) |
| Every action in the drawer, Raise an issue | ATAM_FLOW · Exception actions (`/atam-flow/exceptions`) |

The detector workflow also runs on a 30-minute schedule once published; without it the "last checked" time goes stale and the page says so.

## Next pages

Home (morning / during the day / end of day), Purchasing, Communications, Artwork and job packs, Supplier selection, Third-Party Production, Machines, Metrics.
