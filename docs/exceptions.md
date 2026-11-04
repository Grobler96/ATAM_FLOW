# Exceptions engine

Built 4 Nov 2026 (migration 21, `supabase/tests/exceptions_test.sql`). Step R1 of [resilience-roadmap.md](resilience-roadmap.md).

## The rule

Every physical item, order, job, file, movement and commitment has a known status, owner, location and next action. When the system cannot tell, or something is
wrong, late, missing or unexpected, it raises an **exception** instead of carrying on. Automation recommends; people work the exception; everything is recorded.

## The entity (`flow.exceptions`)

Reference (`EXC-2026-00001`), type, severity (low / medium / high / critical), status (open, investigating, awaiting supplier / producer / customer, resolved, cancelled, written off),
what it blocks (completion, dispatch, production, assignment), root cause, description, detected by (automation, warehouse user, producer portal, customer, supplier, manual review) and when,
owner (a named person) and responsible role, response deadline, escalation level, customer impact, financial impact with breakdown, recommended action, resolution method and note,
and links to orders, order lines, SKUs, POs, movements, producers, suppliers, artwork and communications (`exception_links`).
The **audit trail** (`exception_actions`) is append-only and holds detection, assignment, status changes, notes, actions taken, escalations, linked emails and resolution.
Types, defaults, blocking behaviour and recommended actions are rows in `exception_types` (editable by admin / manager).

## How exceptions appear and disappear

Detectors read the records we already keep and return what is wrong **right now**; the engine raises new exceptions, refreshes existing ones and closes ones whose condition has cleared.
Each problem has a stable key, so the same problem is never raised twice. Detectors today:

| Detector | Raises |
|---|---|
| supplier | shortage / damage / incorrect / over-delivery on a PO (critical if an affected order is due within a day) |
| producer discrepancies | shortage, damage, rejected, lost (critical), late, over-delivery from producers |
| artwork | orders needing artwork that is missing, unapproved, not stored, unreadable, or lacking stitch counts (orders due within the horizon or in production) |
| purchasing | late POs, ATAM_FLOW POs not acknowledged |
| stock shortage | SKUs short with no cover and orders due within the horizon |
| orders at risk | overdue orders, stock projected after the due date, production scheduled after the due date (revenue at risk shown) |
| sync | any integration failing, or not succeeding within its allowed window (critical at 3x) |
| logistics | producer has not confirmed receipt of dispatched goods; dispatched with no tracking |
| system | failed emails, DecoNetwork statuses missing from the status map |
| integrity | units with an unknown holder, negative stock, POs with no expected date, orders with no due date (grouped), orders on hold with no reason (grouped) |
| completed with open issue | an order DecoNetwork shows as shipped while a blocking exception is open (critical) |

If a person marks an exception resolved but the problem is still there, the next run **reopens** it (within 7 days). A **cancelled** or **written-off** exception is not raised again for 30 days.

## Ownership and escalation

Every exception has a responsible role from its type; `needs_owner` flags those with no named person. Assigning someone moves it to *investigating*.
If the response deadline passes, `exceptions_escalate` moves it up the ladder: a new deadline from the ladder, then manager, then admin, with a notification each time.
Deadlines and ladders are **placeholders** in `flow_settings` `exceptions.config` until the business supplies real ones.

## Blocking completion

`order_completion_check` now also fails when any unresolved exception linked to the order blocks completion, and `can_dispatch_*` respects exceptions that block dispatch.
DecoNetwork can still mark an order shipped, so a *completed with open issue* exception is raised if that happens.

## Working an exception (all audited)

assign, change status, add note / action taken, link an email, resolve (method and note required), cancel (reason), write off (reason and amount), reopen (reason), raise manually.
Cancel, write-off and reopen are manager / admin only in the n8n workflow.

## Read models

`v_exceptions_open` (critical first, overdue, ageing buckets, linked order / SKU / PO / movement / producer, blocking, needs owner), `v_exception_summary`, `v_exception_history`,
`v_order_accountability` (every active order with status, owner, location and next action; a missing one is visible, e.g. on-hold orders with no reason).

## n8n (unpublished)

| Workflow | ID | Trigger |
|---|---|---|
| ATAM_FLOW · Exception detector and escalation | `ZPEjWqfNDOqpDPCo` | every 30 min (:05, :35) = about 1,440 runs a month, and POST `/webhook/atam-flow/run-exceptions` (admin, manager, warehouse, production) |
| ATAM_FLOW · Exception actions | `K7aWo67bi7nqEqiQ` | POST `/webhook/atam-flow/exceptions` `{action, params}`: assign, status, note, resolve, link_comm, raise (all roles); write_off, cancel, reopen (manager/admin) |

A failed detector fails the run so Daniel and Oliver are emailed.

## First live run (4 Nov 2026)

148 open exceptions, 22 critical: 53 artwork, 61 stock shortages, 15 purchasing (late POs), 16 orders at risk (6 critical, already past due), 3 data-integrity (72 orders with no due date, 76 on hold with no reason, one negative-stock SKU).
A second run changed nothing.

## Not yet covered (later roadmap steps)

Machine downtime and recovery planning, producer risk scoring and suspension, supplier auto-chase and approved alternatives, QC gates and rework, order-change impact, courier tracking and claims,
manual override set, and the dashboard page. Pushing notifications to email / Slack is also still to do (notifications are recorded but not sent anywhere).
