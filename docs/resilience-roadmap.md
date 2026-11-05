# Resilience, exceptions and failure handling: gap analysis and plan

Added 4 Nov 2026. Governing rule: **every physical item, order, job, file, movement and commitment always has a known status, owner, location and next action.
If the system cannot tell, it raises an exception instead of carrying on.** Automation recommends; people can override; every override is recorded.

## Coverage today

| Requirement | Have | Gap |
|---|---|---|
| Central Exceptions entity | Separate partial records: `tp_discrepancies`, `supplier_discrepancies`, `notifications`, computed artwork issues, `selection_stale` warnings | **No single entity**: no type/severity/owner/deadline/escalation/financial & customer impact/actions/linked comms. Artwork issues are computed, never stored |
| Order cannot complete with a blocking exception | `order_completion_check` blocks on third-party discrepancies only | Must cover every exception type |
| Machines | `machines`: code, name, method, units_per_hour, is_active (6 placeholders) | Type, location, status (operational/limited/maintenance/breakdown/offline/retired), maintenance, downtime records, operators, backups, queue |
| Machine-down recovery | Scheduler re-plans if a machine is deactivated | No impact analysis, reroute / split / outsource / resequence / expedite options, cost and margin impact, customer message, downtime history |
| Producer failure | Producer capability, turnaround, capacity, stats (on-time, discrepancy rate, units and value held, orders blocked); overdue-return check | Reliability and quality scores, max concurrent jobs, backups, emergency contact, SLA, last contact, risk rating; checkpoints (no receipt confirmation, no status update); suspend / block new jobs; exposure calculation and recovery recommendation |
| Supplier failure | PO status incl. acknowledged, late-PO view, goods-in shortage / damage / incorrect, supplier email, escalation once past required-by | Auto-chase of unacknowledged POs; price-change and invoice-mismatch handling; substitute-supplied stock; **Approved Alternatives**; supplier reliability stats (`on_time_rate` is empty); wait / reorder / substitute / split / tell customer recommendation |
| Artwork failures | Missing artwork, unapproved, not stored, unreadable, no stitch count; stale job pack; manual replace; dispatch gate | Wrong file type, low resolution, missing source or placement or dimensions, unusually high stitch count, producer reports "cannot open", artwork exceptions raised, re-approval on change, producer always gets latest version |
| QC and rework | Goods-in condition; producer return check (`tp_check_return`) | Pre-production gate, in-production checkpoints (10 / 50 / 90 %), QC criteria per gate, quality exception, rework job, claim tracking, producer quality score |
| Order changes after production starts | Order sync updates; allocation re-plans; artwork versions | Change detection record, impact assessment (allocations, POs, producer jobs, bins, labels, movements), recommended actions, confirmation for destructive steps, change history |
| Courier and delivery | Carrier, tracking, dates, proof of delivery fields on movements | Tracking monitoring, failed / lost / damaged / partial / wrong address, claims, recommended actions |
| Integration failures | Sync run history (`flow_runs`), snapshots, manual re-run, retries on key nodes, shared error workflow (emails Daniel and Oliver) | Failed runs and missed windows do not raise exceptions; no "sync has not run" watchdog; no raw-response log beyond snapshots |
| Human overrides | Audit log; manual pins, manual allocation, forced selection, reasons on resolutions | Manual stock adjustment, quantity correction, due-date change, hold, cancel, release-despite-warning (all with reason, previous and new value) |
| Daily rhythm, home page, metrics | A few views | Nothing: needs the dashboard plus metric views |
| Warehouse / phone use | n/a | Dashboard not started |

## Design decisions

1. **One `flow.exceptions` table** with the fields in the brief (type, severity, status, links to orders / lines / SKUs / POs / movements / machines, root cause, detected-by, owner, deadline, escalation level, customer and financial impact, recommended action, actions taken, resolution, audit, linked communications).
2. **Raise, never duplicate.** Each detector uses a dedupe key, so re-running it updates the same exception instead of creating another. Detectors are idempotent SQL functions run from n8n schedules and called inline by the actions that find a problem (goods-in, return check, artwork validation).
3. **Existing records feed it.** Supplier and producer discrepancies and artwork issues stay as the detailed records and each gets a linked exception, so the Exceptions page is one list.
4. **Blocking by severity and flag.** A blocking exception stops order completion and (for artwork / producer / stock types) dispatch or assignment. Overrides need a reason and are audited.
5. **Integrity check.** `integrity_check()` finds ambiguous states (stock with no location or holder, orders with no next action, movements with no owner, commitments past deadline) and raises exceptions for them.
6. **Recovery planners are pure engines like the others** (machine-down, producer-failure, order-change, substitution), so the dashboard can show the options and recalculate instantly. They recommend; a person confirms destructive steps.
7. **Money is explicit**: financial impact = stock cost + decoration cost + expedite cost + margin / revenue at risk, taken from the same cost model as the selection engine.

## Revised build order

| Step | Content | Why here |
|---|---|---|
| R1 (**done 4 Nov 2026**, see [exceptions.md](exceptions.md)) | **Exceptions engine**: entity, detectors for everything we already track, ownership and next-action rule, escalation, completion blocking, integrity check, linked comms | Foundation; everything else raises into it |
| R2 (**already covered by R1**, found on re-check 5 Nov 2026) | Integration health: the `sync` detector raises *Integration run failed* and *Integration has not run* from `flow_runs`; it runs with every exception detection | Only remaining work is publishing the detector workflow so it runs on a schedule; no raw-response log beyond snapshots |
| R3 (**done 5 Nov 2026**, see [machine-downtime.md](machine-downtime.md)) | Machines and downtime: richer machine model, downtime records, impact analysis, recovery options | Reduced-capacity planning, operators, maintenance schedules, cost/customer-message impact still to do |
| R4 (**done 5 Nov 2026**, see [producer-risk.md](producer-risk.md)) | Producer risk: scores, checkpoints, suspend / unresponsive handling, exposure and recovery | Producer portal (R12) still to do |
| R5 (**done 5 Nov 2026**, see [supplier-resilience.md](supplier-resilience.md)) | Supplier resilience: chase drafts, Approved Alternatives, shortage advice, reliability stats, supplier offers | Scheduled auto-chase, price/invoice handling, applying a substitution in DecoNetwork still to do |
| R6 | Artwork rule additions and exception raising | |
| R7 (**done 5 Nov 2026**, see [quality-rework.md](quality-rework.md)) | QC gates and rework jobs | Real checklists, auto-advancing order status, claims against producers/suppliers still to do |
| R8 (**done 5 Nov 2026**, see [order-changes.md](order-changes.md)) | Order-change detection and impact assessment | Changes to artwork or decoration details are not tracked; customer notification is manual |
| R9 | Courier monitoring and claims | |
| R10 (**safe subset done 5 Nov 2026**, see [order-changes.md](order-changes.md)) | Manual overrides: hold, release, priority (reason + audit) | Stock and due-date edits are deliberately not built: DecoNetwork overwrites them on sync |
| R11 (Exceptions page **done 4 Nov 2026**, see [dashboard.md](dashboard.md)) | **Dashboard**: Exceptions page first, then the home page (morning / day / evening), purchasing, artwork, selection, third-party, metrics; phone-friendly | Built alongside from R1 so each step can be used and tested with real logins |
| R12 | **Producer portal** (receipt confirmation, stages, queries, evidence) raising into exceptions | Needs R1 and R4 |
| R13 (**done 5 Nov 2026**, see [producer-risk.md](producer-risk.md)) | Metrics views | Margin and cost-of-exceptions metrics still to do |

Acceptance questions 1-13 are tracked against these steps in the README when the work lands.

## Needed from the business (so the rules use real numbers)

Response deadlines and escalation ladders per severity; "X hours / days" thresholds (receipt confirmation, status updates, tracking silence); QC criteria per garment and method; agreed in-line checkpoint percentages; who owns each exception type; which substitutions are pre-approved; overtime / extra-shift cost; machine maintenance calendars; carrier list and claim windows.
