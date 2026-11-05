# Machine downtime (resilience step R3, built 5 Nov 2026)

When a machine breaks, is serviced or runs slowly, ATAM_FLOW records it, shows what it puts at risk, and stops planning work onto it. A person decides the recovery; the system shows the options.

## What a person can do (Production → Machines)
| Action | Who | Notes |
|---|---|---|
| Report downtime: breakdown, maintenance, reduced capacity, offline | warehouse, production, manager, admin | Reason required. Optional start (a future start **schedules** it) and expected return. Only one downtime can be in force on a machine at a time. |
| See the impact | everyone signed in | Jobs planned on that machine in the window, units and hours of work, which are already late or due within a day of the return, other machines that can run the method (backups first), producers that can do it (with turnaround and whether they have a rate card), and written recovery options. |
| Change the expected return | same | Reason required; impact refreshed. |
| Back in service / cancel a scheduled window | same | A note of what was done is required. |
| Re-plan production | production, manager, admin | One button after reporting or resolving. It runs the existing scheduler. |
| Add, edit, retire a machine; set location, type, backup machines | manager, admin | Retiring needs a reason and is refused while work is in progress or downtime is open. |
| Downtime history | everyone signed in | Every record with duration, who reported and what fixed it; CSV export. |

## What the system does by itself
- **Scheduler:** a machine that is fully down right now (breakdown, maintenance, offline) is passed to the scheduler as inactive, so the next plan moves its not-yet-started jobs elsewhere. Work already in progress is never touched by the scheduler (existing rule): that needs a person.
- **Exception:** an unplanned downtime, or planned maintenance that has overrun, raises a *Machine down or limited* exception in Exceptions, and it clears itself when the downtime ends. Planned maintenance that is on time does not raise one.
- **Audit:** every change is in the audit log with who and why.

## n8n and database
Workflow **ATAM_FLOW · Machine actions** (`HtmsZRWbeAGjnuC0`, webhook `/webhook/atam-flow/machines`) is built and **unpublished**. Migration 29: table `flow.machine_downtime`, views `ui_machine_status` / `ui_machine_downtime`, functions `flow.mc_*` (service-role wrappers `public.flow_mc_*`), read-only `ui_mc_impact`, detector `exc_detect_machine_downtime`. Tested in `supabase/tests/downtime_test.sql` and the dashboard e2e suite.

## Honest gaps
- **Reduced capacity** is recorded and shown, but the planner still schedules the machine at full speed (the engine does not take a speed factor yet).
- **Planned future maintenance** is recorded and its impact is shown, but the planner only reacts once the window starts and someone re-plans; it does not plan around windows ahead of time.
- No operators, no per-machine shift calendars, no maintenance schedule/reminders.
- Cost and margin impact and drafting customer messages for late orders are **not** calculated.
- The seeded machines are placeholders; the real machines still need adding.
