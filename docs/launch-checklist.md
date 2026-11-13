# Launch checklist: third-party decorator work only

Status as of 10 Nov 2026. [handoff.md](handoff.md) has the full picture (rules, pitfalls, live state); this page is the short list of what is done, what needs you, and what is not built.

## Done

**Scope and set-up**
- In-house production switched **off** (audited, reason recorded). The old in-house plan was cleared (116 steps to 0). Reversible from the Control page. See [scope-control.md](scope-control.md).
- DecoNetwork **Priority Order** (`is_priority`) is read into ATAM_FLOW hourly and treated as third-party; a manual scope on an order still wins. The Orders, Exceptions and Home pages default to third-party only, with a visible "N hidden" bar and a Show everything button.
- Machines (Happy 6 head, Toyota 1 head, Black / Adkin's / Silver presses), operators and skills, placeholder machines off. All stay in the system for when in-house is switched back on. See [crew.md](crew.md).
- The holding pen is live and works in the background (it stops a bad order being planned, dispatched or completed; DecoNetwork "On hold" orders are kept out on purpose). There is now a read-only **Holding pen** screen (sidebar); assigning an owner, adding a note and waiving a problem are not available from it yet.

**Third-party flow, built and tested**
- Consignments and movements, producer risk, courier events and claims, QC and rework on returned goods, warehouse and labels, supplier resilience, exceptions, order change review, hold / release / priority. See [third-party-production.md](third-party-production.md), [producer-risk.md](producer-risk.md), [courier.md](courier.md), [quality-rework.md](quality-rework.md), [exceptions.md](exceptions.md).
- **Decorator portal** (`portal.html`): sign-in, jobs, goods-in checks, stages, messages, spoilage reports, job packs and artwork downloads, label scanning. Hardened 10 Nov: sign-out after inactivity enforced by the database, a sign-in log with new-device notes, company email addresses only (an admin can allow one personal address with a reason). See [producer-portal.md](producer-portal.md).
- **Dispatch queue and courier labels**: packing into numbered parcels, label, tracking, scan-to-hand-over. See [dispatch.md](dispatch.md).
- **Artwork storage and customer proofs**: upload, preview, download, versioning, proofs and answers. An approval only counts for the artwork it showed. See [artwork.md](artwork.md).
- **Stock-takes**: blind counts, recount by a different person, manager limits, shortfalls suggested as waste. See [stocktakes.md](stocktakes.md). **Waste** ledger: [waste.md](waste.md).
- **Exception digest and due-soon warnings**: attention list with reasons, digest by role. See [exceptions.md](exceptions.md).
- **Purchasing controls** (approval rules, invoice matching, draft-only scheduled chasing) have screens now: approve a PO with the rules shown, record and settle supplier invoices, and a read-only rules panel on Settings (chasing shown off and disabled). The Purchasing actions n8n workflow is unpublished, so the buttons write nothing until it is published. See [purchasing.md](purchasing.md).

**Safety**
- Independent security audit and fixes (10 Nov): decorator logins are confined to the portal by an API guard (migration 61, on), crew history views locked down. See [security-audit-2026-11.md](security-audit-2026-11.md).
- Migrations 1-61 are applied and match the repo. Copies of the live n8n workflows are in `n8n/workflows/`.

## Needs you before real use

1. **Do the two real sign-in checks** from the security audit (a real decorator sign-in to the portal, and staff sign-ins to this app and to ATAM GO). **Do not invite real decorators until a person has done them.** The audit explains what to look for.
2. **Enter the producers.** There are **0 active producers** and 0 rates. Add each decorator (name, contact, email, what they can do, turnaround, rates) on the Producers page.
3. **Roles.** All 10 accounts in `flow.user_roles` are **admin**, so every role check passes for everyone. Give each person the narrowest role that lets them do their job (manager, production, warehouse, viewer).
4. **Supplier emails.** None of the 9 suppliers has an email yet, so PO chasers cannot be drafted. (No emails are sent in any case until you say so.)
5. **Publish the n8n workflows you want live.** Live now: Operations, Quality, Movement, Warehouse, Producer risk, Exception and Artwork actions, Purchasing actions, Goods in, the Communications sender (every email needs a person to approve it), the exception detector, Sync priority flags, Verify caller and the data syncs. Still unpublished on purpose: Supplier actions, Daily housekeeping, the scheduler, Machine and Production actions (in-house), selection, artwork download job. Editing a live workflow creates a draft: it is not live until you publish again.
6. **Confirm the real values** only you can give: QC checklist items (13 placeholder items today, nobody has confirmed standards), press speeds, per-machine shift hours, risk weights, the DecoNetwork artwork credential (so artwork can be fetched), and shelf locations for stock (none entered, so counts by shelf have nothing to match). "Own Product Supplied - T-Shirt" shows 999 units, which looks like a placeholder.
7. **Upload artwork or connect DecoNetwork's artwork fetch.** There are no artwork files in the system, so every decorated order is blocked on artwork until files exist.
8. **Test one third-party order end to end with a real login**: pick, label, consignment, producer receives, returns, QC, dispatch.
9. **Give the go-ahead for migrations 63 to 65** (decorator upload limit, audit trail for direct set-up changes, QC photos from a device). They are written and tested but not applied: see [handoff.md](handoff.md) for what each does and how to check it after.
10. **Try real hardware**: print a real label and a courier label on your actual printer and scan each with your real scanner and phone. Nothing has been tried on real hardware yet.

## Not built

- Changing the purchasing rules from a screen, and switching scheduled chasing on (shown off and disabled). Assigning, noting and waiving on the holding pen screen.
- Portal: two-factor sign-in and unusual-location alerts.
- Loading the rest of a list that is cut off at 5,000 rows (a red warning shows, but the rows beyond are not loaded).
- Automatic courier tracking, and escalation emails or digests (in-app only; no emails yet).
- Operator shifts, press speeds, per-machine shift hours, real QC checklists and risk weights are placeholders until you provide the real values.
