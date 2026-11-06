# Assigning jobs to operators and machines

Each planned job (an order's step for one method, such as embroidery) can have an **operator** and a **machine** chosen by a person.

- **Operator:** Gill Pick, Sam Trew, Beth Harman (`flow.operators`). Recorded against the job and shown on the order drawer's Production tab. The planner does not schedule people's hours, so an operator is a record for the floor, not a constraint. Re-planning never clears it.
- **Machine:** an instruction to the planner. A chosen machine must do the job's method and be switched on, and choosing one needs a reason (audited with the planner's own pick). The planner keeps the job on that machine and plans everything else around it. If the machine is later switched off or goes fully down, the job shows as **blocked** with that reason rather than moving silently. "Let the planner choose" clears the choice. A running job's machine cannot be changed, though its operator can.
- **Where:** order drawer, Production tab, "Assign operator / machine…". After choosing a machine, re-plan production to see the new times.
- **Who:** manager, admin, production planner (enforced in the unpublished Operations actions workflow; actions `assign_operator`, `assign_machine`).
- **Engine:** `packages/engine/scheduler.js` reads `input.assignments`. The copy in the Production scheduler n8n workflow was updated to match.
- **Not built:** operator shifts and holidays, skills, per-operator capacity, assigning from the Production page, bulk assignment.

## How long embroidery takes (machine speeds)
A rule of thumb from the business: a run of up to about 7,500 stitches takes around 10 minutes, and a multi-head machine sews one piece per head at the same time. So the Happy 6 head does about 6 pieces per 10 minute run (36 an hour) and the Toyota 1 head about 6 an hour. These are averages, not exact.

- `flow.machines.heads` holds the head count (Happy 6 = 6, everything else 1). The planner now works out an embroidery job's duration **on the machine it is placed on**: runs = pieces / heads (rounded up), minutes per run = 10, or longer in proportion above 7,500 stitches (15,000 stitches = 20 min a run). The job's average stitch count comes from its order lines; if unknown it assumes 7,500.
- The numbers live in the `embroidery.run_model` setting (`base_stitches` 7500, `base_minutes` 10) and can be changed without code.
- The planner places a job on the machine that can start it soonest; it does not yet pick the machine that would finish it soonest, so a small job can land on the slow single head. Choose the machine yourself on the job if that matters.
- Other methods (heat press and so on) still use the old per-piece estimate until you give me their speeds.
