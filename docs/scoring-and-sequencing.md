# How production sequencing works (scheduler v1)

Code: `packages/engine/scheduler.js` (pure function, 14 unit tests). Postgres assembles the input
(`flow.scheduler_input()`), n8n runs the engine, Postgres stores the plan (`flow.apply_schedule()`).
Every weight below is in `flow.flow_settings` (`scheduling.weights`, `scheduling.options`) and can be tuned without a rebuild.

## What is scheduled

One **job** per *order × decoration method* (e.g. order #1234 has a DTF job and an embroidery job). Remaining work =
`qty_required − qty_produced` per line. Run time per job: embroidery = qty × (stitches ÷ stitches-per-minute + minutes-per-item)
from your existing `job_settings`; other methods = qty × the method's minutes per unit. Jobs of one order run in the order set by
`scheduling.method_order` (default: print/transfer processes first, embroidery last), and a later step never starts before
the earlier one ends.

## Urgency score (why a job is early or late in the queue)

| Component | Meaning (default weight) |
|---|---|
| `due_date` | 0–30, rising as the due date nears within the 14-day horizon |
| `overdue` | +30 plus 1 per day overdue (max +10) |
| `critical_ratio` | up to +15 when the order has little slack for the work remaining |
| `priority` | high +8, rush +20, critical +40 (set on the order) |
| `vip` | +8 |
| `long_job` | up to +10 for jobs ≥ 4 h, so big jobs start early |
| `stock_ready` | +15 when the order's stock is fully allocated (activates with the allocation engine) |

When a machine is free it picks, from the jobs that are **ready now**, the best *selection score*:
`urgency + same-customer bonus (8) + same-colour bonus (6) + same-garment-type bonus (5) − 0.3 × changeover minutes`.
That is how compatible work gets grouped without letting low-priority work jump a genuinely urgent job.
Each step stores its score breakdown and a plain-English reason, e.g.
*"#2 on EMB-1: due Fri 13 Nov; RUSH priority; no changeover: same customer, colour and garment type as the previous job."*

## Machines, shifts, changeovers

Each machine works its own shifts (or the default Mon–Fri 08:00–17:00, London time, DST-aware); long jobs pause overnight and
at weekends. A job's setup is the method's setup time if it is first on the machine, otherwise the sum of the matching
`changeover_rules`. **Proxies until we capture richer data:** DecoNetwork does not give thread colours or design IDs, so a
*different customer* is treated as a new design/thread/ink set, and differing garment colour or type adds those changeovers.

## Batches, bottleneck, risk

- **Batch** = consecutive jobs on one machine with ≤ 5 min changeover between them (`batch_max_changeover_min`).
- **Bottleneck** = the method with the highest demand ÷ capacity over the horizon, flagged when ≥ 85% used or when jobs are
  predicted to *become* late. Work that was already overdue before planning does not count as a capacity problem.
- **Risk score** per order (0–100): 90+ predicted late, 70 within a day of the due date, 45 within three days, 25 within a week,
  10 otherwise; overdue 95+; blocked orders are raised to at least 40/70.

## Blocked work (never scheduled, always listed with a reason)

Order on hold / blocked; artwork or proof marked missing/pending/rejected (fields are not populated yet); no active machine
for a method; a blocked earlier step; stock not allocated *(only if `stock_gate` = `require_allocation`; default `ignore`)*.

## Manual override

Pin an order (or one process) with `flow.set_schedule_override`. Pinned jobs go to the front of the queue but the engine runs
twice, so every step keeps both `sequence_position` (actual) and `recommended_position` (what the system would have done),
and the reason says who pinned it and why. Clearing the pin restores the recommendation.

## Known limits (v1)

Machine speed is not modelled beyond the minutes-per-unit estimates; no bank-holiday calendar; no operator availability;
stock readiness and artwork/approval status are ignored until those data exist; packing is not scheduled.
