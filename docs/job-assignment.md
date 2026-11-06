# Assigning jobs to operators and machines

Each planned job (an order's step for one method, such as embroidery) can have an **operator** and a **machine** chosen by a person.

- **Operator:** Gill Pick, Sam Trew, Beth Harman (`flow.operators`). Recorded against the job and shown on the order drawer's Production tab. The planner does not schedule people's hours, so an operator is a record for the floor, not a constraint. Re-planning never clears it.
- **Machine:** an instruction to the planner. A chosen machine must do the job's method and be switched on, and choosing one needs a reason (audited with the planner's own pick). The planner keeps the job on that machine and plans everything else around it. If the machine is later switched off or goes fully down, the job shows as **blocked** with that reason rather than moving silently. "Let the planner choose" clears the choice. A running job's machine cannot be changed, though its operator can.
- **Where:** order drawer, Production tab, "Assign operator / machine…". After choosing a machine, re-plan production to see the new times.
- **Who:** manager, admin, production planner (enforced in the unpublished Operations actions workflow; actions `assign_operator`, `assign_machine`).
- **Engine:** `packages/engine/scheduler.js` reads `input.assignments`. The copy in the Production scheduler n8n workflow was updated to match.
- **Not built:** operator shifts and holidays, skills, per-operator capacity, assigning from the Production page, bulk assignment.
