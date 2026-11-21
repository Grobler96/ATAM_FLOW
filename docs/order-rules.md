# Order tags and routing rules (shadow mode)

Added 21 Nov 2026 as migration 69 (`supabase/pending/20261121000069_flow_order_rules.sql`, **written and tested locally, not applied to the live project**).

## The idea
After an order reaches Flow it passes two steps, then lands in **IH Orders** or **3PD Orders** as it does today.
1. **Order criteria (tags).** Tag rules look at the order and tag it. First tag: **Requires person packing**, which carries the number of distinct names. Tags are meant to drive folding sections and extra charges on third-party purchase orders later.
2. **Routing rules.** Checked from the lowest position up; the first match says where the order should be made. First rule: **more than 20 decorations -> third party, producer DPS**.

Both are rows in tables, so a new tag or rule is data, not code. They are added through `flow.rr_save_tag_rule` and `flow.rr_save_routing_rule` (reason required, audited in `flow.audit_log`, every order re-checked straight after). A Settings screen and an n8n action for them are not built yet.

## Shadow mode: what it does and does not do
It **only records** what would happen, in `flow.routing_decisions` (`public.ui_routing_decisions`). It does not change an order's scope, producer, status or any purchase order. `flow.order_scope()` is untouched. The mode setting only allows `shadow`; there is no live mode yet.

Per order the outcome is one of: `no_rule_matched`, `would_change`, `already_matches` (e.g. already third party by the Priority flag), `manual_wins` (a manual scope always wins), or `protected` (work has started, using the existing `flow.oc_is_protected`; it would be left alone and flagged).
Precedence recorded: manual scope, then a matching rule, then DecoNetwork's Priority flag as the fallback. An order with no facts yet gets no tags and no decision.

## What counts
- **Decorations** = every process on every placement on every garment line, added up over the whole order (7 shirts with 3 decorations each = 21). "More than 20" means 21 or more; exactly 20 does not match.
- **Names** = the filled-in values of a custom field, counted as **distinct people** per order (case and spacing ignored, blanks ignored). The seeded rule uses the DecoNetwork field **"Uniform For"** (checked on order 636890: all 28 lines filled). The "Name" field (on 59 recent orders) is deliberately not used. The field name is a setting on the rule, not fixed in code.
- On the 657 orders in the 60-days-back to 30-days-ahead window (checked 21 Nov 2026, read-only): 21 had more than 20 decorations by the reader's count (25 if placements with no process set are also counted; **open question for the owner: which is right?**); "Uniform For" exists on 598 orders but is filled on only 958 of 2,112 lines, so the tag must fire on a filled value, not on the field existing.

## Where the facts come from
The n8n workflow **ATAM_FLOW · Order facts from DecoNetwork** (`IbZJlAMiEMSRL3ry`, **created but not published**; hourly at :55 plus a Run by hand trigger). It is read-only on DecoNetwork (same `manage_orders/find` call, with workflow data, as the Priority flag sync, same 60-days-back to 30-days-ahead window, 12 pages of 100). For each order it totals the decorations and collects the filled-in custom fields, then calls `public.flow_order_facts_ingest` (service role only). It stops with an error if it read fewer orders than DecoNetwork reports, or if Flow answers "not ok". It does not edit the existing capture workflow. **It will fail until migration 69 is applied, because the function does not exist yet**, and it should not be published before that.

A decoration is counted as one **process on one placement on one garment line**, added up over the whole order. Placements with no process set yet count as zero.

**Tested 21 Nov 2026 by running only the reading half (no save, nothing written):** 657 orders, payload about 61 KB. Order 636890: 42 decorations, 14 distinct names across its 28 lines. 21 orders had more than 20 decorations (an earlier count of placements, including ones with no process, gave 25); 90 orders had 0; the biggest had 105. 207 orders had at least one filled "Uniform For" value (largest: 27 distinct names on one order).

## Not built yet
- Publishing the reader and applying migration 69 (until both are done no order has facts, so nothing is tagged or decided).
- Screens: tags on the order drawer, a Routing rules / Tags settings page, a "what would move" review list.
- Live mode (rules actually setting scope and producer), mixed orders (some lines each way), extra charges on third-party POs, timing in-house packing, folding sections.

## Tests
`supabase/tests/order_rules_test.sql` (run by `scripts/test-db.sh`): seeds, boundary at 20, manual scope wins, protected orders, no facts means no decision, distinct-name counting, idempotent re-reads, adding tags and rules (with reason and bad settings refused), first match by position, rule switched off, no order column changed, closed-to-browser permissions. `permissions_test.sql` also passes with the new tables and functions.
