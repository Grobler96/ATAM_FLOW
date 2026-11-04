# Main internal UI (command centre)

`apps/dashboard`: Vite + React + TypeScript, static build, hash routing, dark glass "mission control" design. It **extends** the Exceptions page built earlier (that page now lives inside this shell as `pages/Exceptions.tsx`); the backend, n8n workflows and contracts are unchanged apart from extra read-only views.

## What it reads and how

- **Reads** only `public.ui_*` views and three functions (`ui_search`, `ui_activity`, `ui_order_history`), all applying the signed-in person's own access (migrations 22-25). Anonymous users and people with no ATAM_FLOW role get nothing.
- **Acts** only through n8n webhooks, which re-check the login and role on every call: sync-orders, sync-stock, sync-purchase-orders, run-allocation, run-scheduler, run-exceptions, exceptions, purchasing, selection, production.
- One shared data cache (`data/store.ts`): each view is fetched once, shared by every screen, refreshed every minute while visible, and a failed refresh keeps the last good data.

## Design system (`src/design`, `src/ui`)

Tokens (`tokens.css`): surfaces, text, brand, status colours, type scale, spacing, radius, elevation, motion. Nothing styles itself with raw values.
Components: Button, Chip, Status chip, Tag, Panel, KPI card, Segmented control, Tabs, Field/inputs, Facts grid, Callout, Timeline, Skeleton, Empty / Error states, Progress, Drawer, Modal, Toasts with a run state, DataTable (sort, per-column filters, search, windowed rows, saved views, bulk select, CSV), charts (sparkline, bars, stacked bar, heatmap, all SVG, no dependency).

## App shell

Persistent sidebar (12 sections, collapsible, off-canvas on a phone), top command bar (global search, time range Today / This week / This month / All, Quick actions, sync status, notifications, account), status bar (online state, DecoNetwork data age, last screen refresh).
**Command palette**: `/` or `Ctrl/Cmd + K`. Live search across orders, SKUs, POs, producers, bins, movements, exceptions and labels, plus pages and actions. Chords: `g` then `h o p s u r w a e l n t`. `?` lists shortcuts.
**Workflow runs**: every n8n trigger shows a progress toast, then a result toast with a summary and a link to what changed, and the data refreshes. A workflow that is not published says so plainly.

## Pages: what is built and what is not

| Page | Built | Not built yet (and what it needs) |
|---|---|---|
| **Command Centre** | 10 KPI tiles that drill into the filtered list; "what needs attention" with severity, owner, deadline, recommended action, Take it / View; production pulse with machine load and the reason for each sequence position; third-party pulse; stock pulse; live activity feed | Per-item actions beyond Take it / View (chase, reallocate, escalate) need their own workflows |
| **Orders** | All requested columns (except last-update detail), 11 default views, 10 filters, search, sort, saved views, bulk select; detail drawer with 9 tabs; "Why the system says this" (allocation reason and score bars, sequence reason, supplier/producer choice); override of a production position with a mandatory reason; supplier/producer comparison with what-if | Garment-type and PO-status filters; bulk send-to-producer, labels, status change, bin assignment (their workflows are not built) |
| **Production** | Board (8 columns), schedule with machine timeline, system position beside any override, reasons and score breakdown, machine cards, re-plan button | Drag-and-drop and manual stage moves; machine status, downtime, maintenance, operators, backups (resilience step R3) |
| **Stock** | List with all requested columns, 8 views, filters; detail with reorder recommendation, movements, incoming POs, orders that need it, producer holdings, discrepancies | Slow / dead stock, stock ageing (need history); alternative SKUs (approved-alternatives step) |
| **Purchasing** | PO list, detail with lines and actions (approve, prepare email, acknowledge, cancel), discrepancies, **email review queue (approve / cancel)**, supplier comparison table; create PO from waiting orders | Goods-in screen; supplier comparison inside the create-PO dialog is the simple table, the full per-SKU engine comparison is per order |
| **Producers** | Producer list with performance, movements list, stock held, discrepancies, detail drawers | Needs real producers loaded; emergency contact, backup producers, quality pass rate are not stored yet |
| **Warehouse / Bins** | Bin list and detail, search by bin or order | No bins exist yet; creating bins, assigning, label reprint, release/empty need workflows |
| **Artwork & Job Packs** | Readiness by order, file versions, job packs | Preview, download, upload / replace, regenerate, send to producer (need the artwork file workflows and DecoNetwork credentials) |
| **Exceptions** | Full list with groups, filters, ageing, detail with actions (assign, status, note, resolve, cancel, write off), raise an issue | None of substance |
| **Labels** | Table and empty state | Generation, preview, QR / barcode, printing, print audit UI (needs the label workflow) |
| **Analytics** | Due-date profile, pipeline, exceptions by area and age, late POs by supplier, shortages by urgency, revenue and cost exposure, all clickable | Trend lines for throughput, on-time rate, utilisation, downtime, rework, supplier / producer performance and margin by producer need history, which builds as work flows through ATAM_FLOW |
| **Settings** | Account and role, every engine setting with its explanation (read-only) | Editing settings from the UI |

## Roles

Admin and manager can do everything; production, warehouse and others can work exceptions and run the workflows for their area; viewers are read-only. The UI hides or disables what a role cannot do and the webhooks enforce it again.

## Run, test, publish

```bash
cd apps/dashboard && npm install
npm run dev       # local
npm test          # unit tests
npm run build     # type-check + production build
npm run e2e       # browser test against a fully mocked backend (synthetic data); screenshots in e2e/shots
```
Publishing is described in [dashboard.md](dashboard.md) (merge to `main`, enable Pages from Actions). Workflows the UI calls that are still unpublished: exceptions (detector and actions), purchasing, selection, production, scheduler, artwork.

## Adding a page

Create `pages/Thing.tsx` using `useView('ui_...')` for data and `DataTable` / `Panel` for layout, add it to `NAV` in `router.ts` and to `AppShell`. Do not add raw styles: use the tokens and components.
