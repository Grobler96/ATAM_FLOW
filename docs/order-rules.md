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
- **Decorations** = every decorated area on every garment line, added up over the whole order (7 shirts with 3 decorations each = 21). "More than 20" means 21 or more; exactly 20 does not match.
- **Names** = the filled-in values of a custom field, counted as **distinct people** per order (case and spacing ignored, blanks ignored). The seeded rule uses the DecoNetwork field **"Uniform For"** (checked on order 636890: all 28 lines filled). The "Name" field (on 59 recent orders) is deliberately not used. The field name is a setting on the rule, not fixed in code.
- On the 657 orders in the 60-days-back to 30-days-ahead window (checked 21 Nov 2026, read-only): 25 had more than 20 decorations (largest 100); "Uniform For" exists on 598 orders but is filled on only 958 of 2,112 lines, so the tag must fire on a filled value, not on the field existing.

## Where the facts come from
DecoNetwork's `manage_orders/find` call with workflow data returns, per order line, `fields[]` (`field_name`, `string_value`) and `views[].areas[]`. A read-only n8n reader (**not built yet**) will total the areas and collect the filled custom fields, then call `public.flow_order_facts_ingest` (service role only). It must be a new workflow; the existing capture workflow is not edited.

## Not built yet
- The read-only n8n reader that feeds `flow.order_facts` (until then no order has facts, so nothing is tagged or decided).
- Screens: tags on the order drawer, a Routing rules / Tags settings page, a "what would move" review list.
- Live mode (rules actually setting scope and producer), mixed orders (some lines each way), extra charges on third-party POs, timing in-house packing, folding sections.

## Tests
`supabase/tests/order_rules_test.sql` (run by `scripts/test-db.sh`): seeds, boundary at 20, manual scope wins, protected orders, no facts means no decision, distinct-name counting, idempotent re-reads, adding tags and rules (with reason and bad settings refused), first match by position, rule switched off, no order column changed, closed-to-browser permissions. `permissions_test.sql` also passes with the new tables and functions.
