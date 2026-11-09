# Quality control and rework (resilience step R7, built 5 Nov 2026)

A new **Quality** page (sidebar, `g` then `q`). Failed work can no longer slip through: a failed check opens a rework job, and the order cannot complete or dispatch until that work is fixed and re-checked, or the units are scrapped and replaced.

## What a person can do
| Action | Who | Notes |
|---|---|---|
| Record a check at a stage: before production, during production (10 / 50 / 90%), final, returned from producer, re-check | warehouse, production, manager, admin | Units checked and failed, a pass / fail checklist for the order's method, optional photo links and notes. From the Quality page, the **Record quality check** bulk action on Orders, or the *To check* list. |
| A failed check | same | Needs what is wrong (stitching, placement, colour, print quality, garment damage, wrong garment or size, contamination, artwork, other) and a likely cause (operator, machine, garment, artwork, producer, supplier, not sure). It **opens a rework job automatically**; a garment or supplier fault asks for replacement garments. |
| Open a rework job by hand | same | For example a complaint found after the fact. |
| Start / assign / finish / cancel a rework job | same | Finish: fixed + scrapped must equal the units. Fixed units create a **pending re-check** (due within 24 h). Cancelling needs a reason. |
| Track replacement garments: needed → ordered → received | same | "Not needed", and "no replacement for scrapped units", need a reason and a **manager or admin**. |
| Edit the quality checklist per method | manager, admin | Ships with **placeholder** items; replace them with your real standards. |

## What the system does by itself
- **Exceptions that block completion:** *Failed quality check awaiting rework* (blocks completion and dispatch; critical if due within 2 days), *Replacement garments needed* (blocks completion), *Quality check overdue* (an overdue pending check, or an order left in quality check for over 24 hours with no passing check). They clear themselves when the work is done.
- **Producer quality:** the producer page shows a pass rate and open rework from checks recorded against that producer's movements.
- Every check, rework step and replacement decision is in the audit log.

## n8n and database
Workflow **ATAM_FLOW · Quality actions** (`5gw5MwH9CIgDFtdw`, webhook `/webhook/atam-flow/quality`) is built and **unpublished**. Migration 32. Tested in `supabase/tests/qc_test.sql` and the dashboard e2e suite.

## Real checklists (migration 55)
The mechanism for your own standards is built; **the items themselves are yours to supply** (the 13 starter items are marked "starter" and are not required, so they never block a check).
- Each item has: method (or every method), the stages it applies to, **must be answered**, **critical**, **photo needed if it fails**, order, in use. Editing bumps its version and clears the "starter" flag; items are switched off, never removed.
- Recording a check now follows the checklist that applies (the order's methods, or the chosen line's, plus the stage): every required item must be answered, a failed item needs a reason (item note or check notes), a failed photo item needs a photo link. The database enforces this, not just the screen.
- Each stored answer keeps a snapshot of the item (name, critical, required, version), so later edits never rewrite history.
- **Sign-off:** a manager or admin presses "Confirm these are our standards" once no starter items are in use. Editing any item afterwards un-confirms it. While unconfirmed, checks still work but an issue "Quality checks are being done against an unconfirmed checklist" is raised if any were recorded in the last 14 days.
- n8n Quality actions: `set_criterion` (now saves all the fields above) and `confirm_checklist` (managers/admins only). Tests: `supabase/tests/qc_checklist_test.sql`, `src/lib/quality.test.ts`, e2e.
- Also fixed in migration 55: the stock-take detector used root-cause values the exceptions table rejects, so a stale stock-take would have errored instead of raising an issue.

## Honest gaps
- Defect types and the 24-hour threshold are placeholders until you set them (`qc.options` in Settings). The checklist items are still the starter ones until you replace and confirm them on the Quality page.
- Order status is not advanced automatically after a pass; the system blocks and raises issues but does not move orders on.
- Replacement garments are tracked, not bought automatically: raise a PO yourself and mark it ordered. Scrapped units do not adjust stock or the order quantity.
- No photo upload from the device (links only), and no claim tracking against producers or suppliers for faulty goods yet.
- Existing producer return checks on the Producers page still work as before; recording a QC check there is separate.
