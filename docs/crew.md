# Crew: workers, who does what, and the floor screen

Everything here is for **in-house** production. With in-house production switched off (Control page) there are no planned jobs to assign, and the screens say so.

## Workers (Crew page, Workers tab)
- **Who:** Gill Pick, Sam Trew, Beth Harman (the only people loaded, as asked). A manager or admin can add or switch off workers.
- **What they can run:** a level per process and per machine: Not allowed, Learning, Competent, Expert, or Not set. "Not set" means they are not offered that work once any skill is recorded for them. First levels were worked out from their DecoNetwork production records (200+ records expert, 20+ competent, otherwise learning) and are marked "please check". Beth Harman has no skills yet: her history is matched by the exact name in the production records, and none of them says "Beth Harman".
- **Hours and time away:** personal hours per weekday (otherwise the standard working hours apply) and days away. A worker who is away or off shift is never offered the job.
- **History:** past work per process from the production records (`processed_by`), shown beside each skill. Removing a skill, shift or absence is a soft removal, so nothing is lost.

## Suggestions (who should do this job)
Every suggestion is a transparent score with reasons in plain English, never a black box. It looks at:
- Skill level for the process and the machine, and anyone not allowed or not set up is ruled out.
- Past work: how many similar jobs, how recently, and for this customer.
- Real speed: once a worker has 3+ finished jobs with timings, whether they beat the estimate.
- Quality: once there are 3+ checked jobs (20+ units), their failure rate against the team's on that process. QC checks on in-house work are matched to whoever ran the job, so this only starts to exist as jobs are assigned and checked. Nothing exists for past work.
- Availability: minutes already booked that day against their shift, away days, and being already on another step of the same order.
- Your own recent choices for similar jobs.
- Urgency: a late or due-within-3-days job leans harder on skill and speed.

You always decide: accept the suggestion (no reason needed) or choose someone else (a reason is required). Both are logged (`assignment_log`) and your choices feed later suggestions. **Suggest for all** fills the day plan while spreading the load so one person is not given everything. Machines are listed with their status and load; choosing a machine still goes through the existing machine choice (with a reason).

## Optional rewording
Each suggestion has standard plain wording. **Say it another way** asks the unpublished workflow "ATAM_FLOW · Crew wording" (`sMFDy4zMagFuwugd`) to put it in a more natural voice. The customer name is masked before it leaves n8n, any sentence that mentions how it was produced is stripped, and if anything fails the standard wording stays. The wording never mentions any tool.

## Floor screen (Floor, built for a tablet)
Pick your name, see your jobs, tap **Start**, then **Finished** (units counted; fewer than planned needs a reason) or **Stop for now** (time so far is kept and the job returns to the plan). Rules: one running job per worker, one running job per machine, no start on a held or blocked job or by someone not allowed. Real minutes and units feed the suggestions.

## Under the hood
Migration 48. Reads through `ui_*` views and RPCs; writes through the Operations actions workflow (`assign_job`, `worker_*`, `floor_start`, `floor_stop`), which is unpublished. `supabase/tests/crew_test.sql` and the browser tests cover it.

## Not built
Planner awareness of worker hours (the planner still plans machine time; workers are assigned onto it), per-person pay or targets, shift swaps, and a personal login per worker (the floor screen is a shared tablet where you pick your name).
