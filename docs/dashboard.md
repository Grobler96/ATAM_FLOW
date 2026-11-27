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

**Long lists load page by page (26 Nov 2026).** The Supabase API returns at most 1,000 rows per request, and several lists are longer (order lines 1,611, stock 1,700, PO lines 2,634, catalogue 1,244, artwork files, Drive files, known item codes), so the newest rows were missing: order #636967 showed "No lines". `data/store.ts` now, when the first response is a suspicious size and a count says rows are missing, refetches the list ordered by a column that is unique on every row (`id`, `sku` or `drive_file_id`) and page by page (`fetchAllPages` in `data/cutoff.ts`). A list with no such column (for example `ui_exception_history`) stays flagged as cut off. Setting the API's Max rows higher in Supabase also helps, but is not needed.

**Open sessions update themselves (26 Nov 2026).** Every build gets an id (date, time and commit) that the page carries as `__BUILD_ID__` and that the build publishes as `version.json`. `components/UpdateWatcher.tsx` (staff app and decorator portal) fetches `version.json` (never cached) every 2 minutes while the tab is visible and when the person returns to it. If the published id differs it refreshes the page, but only when the person moves to another page in Flow or returns to the tab, and never while a box (`role=dialog`) is open or a field is focused; then a "new version ready" bar with Refresh now waits instead. A tab refreshes itself at most once for the same newer id (kept in sessionStorage), so a slow cache cannot cause a loop. Logic and tests are in `lib/updateCheck.ts`. A local dev server has no build id, so it does nothing there. A tab only picks this up after its next refresh; tabs open from before this change still need one manual refresh. It fixes an old copy of the dashboard code, not stale data on the screen.
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
