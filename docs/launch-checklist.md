# Launch checklist: third-party decorator work only

Status as of 7 Nov 2026.

## Done
- In-house production switched **off** (audited, reason recorded). The old in-house plan was cleared (116 steps to 0). Reversible from the Control page.
- DecoNetwork **Priority Order** (`is_priority`) is read into ATAM_FLOW and treated as third-party. First read: 34 open third-party orders. Manual scope on an order still wins.
- Machines (Happy 6 head, Toyota 1 head, Black / Adkin's / Silver presses), operators, placeholder machines off. All stay in the system for when in-house is switched back on.
- Everything for third-party work is built and tested: consignments and movements, producer risk, courier events and claims, QC and rework on returned goods, holding area, warehouse and labels, purchasing and supplier resilience, exceptions, order change review, hold / release / priority.

## Needs you before real use
1. **Enter the producers.** There are **0 active producers** and 0 rates. Add each decorator (name, contact, email, what they can do, turnaround, rates) on the Producers page.
2. **Roles.** All 10 accounts in `flow.user_roles` are **admin**. Give everyone else the narrowest role that lets them do their job (manager, production, warehouse, viewer).
3. **Supplier emails.** None of the 9 suppliers has an email yet, so PO chasers cannot be drafted.
4. **Publish the n8n workflows** you want live. Until then dashboard buttons that change data explain that the workflow is not published; reads work. Suggested set for third-party launch: Operations actions, Movement actions, Warehouse actions, Producer risk actions, Quality actions, Supplier actions, Sync priority flags, Daily housekeeping. The Production scheduler can stay unpublished while in-house is off.
5. **Test with a real login**, one third-party order end to end: pick, label, consignment, producer receives, returns, QC, dispatch.
6. **Print a real label** on your actual printer.

## Decide
- **Focus view.** 156 of the 197 open exceptions belong to orders that are not flagged third-party. With in-house off they are noise for a third-party launch. Proposed: Orders, Exceptions and the home screen default to third-party only, with a visible "N hidden" control to widen the view, nothing deleted.

## Not built
Producer portal, automatic courier tracking, operator shifts, press speeds, per-machine shift hours, QC checklists and risk weights are placeholders until you provide the real values.
