-- Exceptions engine: raising, de-duplication, auto-resolve, escalation, working an exception, completion blocking, integrity.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.exc(p_key text) returns flow.exceptions language sql as $$ select * from flow.exceptions where dedupe_key = p_key order by created_at desc limit 1 $$;
create or replace function pg_temp.open_count() returns int language sql as $$ select count(*)::int from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') $$;

-- ---- fixtures ----
insert into flow.suppliers (code, name, email) values ('EXS', 'Exc Supplier', 'x@exc.test');
select id as sup from flow.suppliers where code = 'EXS' \gset
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_date, order_status, deco_status, stock_secured, order_value, total_units, decoration_methods) values
  ('E1','#E1','Exc One', now() + interval '1 day', now() - interval '5 days','ready_for_production',1,true,800,20,'{embroidery}'),
  ('E2','#E2','Exc Two', now() + interval '20 days', now() - interval '2 days','ready_for_production',1,true,300,10,'{dtf}'),
  ('E3','#E3','Exc Three', now() - interval '3 days', now() - interval '9 days','ready_for_production',1,true,500,10,'{}');
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods, emb_areas, stitches_per_piece)
select v.wi, v.dl, o.id, v.sku, 'Navy', 'M', 'Polo', v.q, v.m::text[], v.ea, 5000
from (values ('EL1','EDL1','E1','EXC-POLO',20,'{embroidery}',1), ('EL2','EDL2','E2','EXC-TEE',10,'{dtf}',null), ('EL3','EDL3','E3','EXC-HOOD',10,'{}',null)) v(wi, dl, oid, sku, q, m, ea)
join flow.orders o on o.deco_order_id = v.oid;
insert into public.sku_costs (sku, product_name, unit_cost) values ('EXC-POLO', 'Polo', 5) on conflict do nothing;
select id as e1 from flow.orders where deco_order_id = 'E1' \gset
select id as e2 from flow.orders where deco_order_id = 'E2' \gset
select id as e3 from flow.orders where deco_order_id = 'E3' \gset

-- ---- 1. a supplier shortage raises one exception with links, money and a deadline ----
insert into flow.purchase_orders (deco_po_id, po_number, supplier, supplier_ref_id, delivery_status, expected_date, is_active, origin, af_po_ref, po_status)
  values (-9001, 'AF-PO-EXC', 'Exc Supplier', :'sup', 'expected', now() + interval '2 days', true, 'atam_flow', 'AF-PO-EXC', 'sent');
select id as po from flow.purchase_orders where deco_po_id = -9001 \gset
insert into flow.po_lines (po_id, line_no, sku, qty_expected, unit_cost, colour, size) values (:'po', 1, 'EXC-POLO', 20, 5, 'Navy', 'M');
select id as pl from flow.po_lines where po_id = :'po' \gset
insert into flow.supplier_discrepancies (disc_ref, po_id, po_line_id, supplier_id, disc_type, sku, qty_ordered, qty_received, qty, required_by, affected_orders)
  values ('SD-EXC-1', :'po', :'pl', :'sup', 'shortage', 'EXC-POLO', 20, 14, 6, current_date + 1,
          jsonb_build_array(jsonb_build_object('order_id', :'e1', 'order_ref', '#E1', 'due_date', (current_date + 1)::text, 'qty', 6)));
select pg_temp.assert((flow.exceptions_detect_all()->>'ok')::boolean, 'detectors ran: ' || flow.exceptions_detect_all()::text);
select pg_temp.assert((select (x).severity = 'critical' and (x).type_code = 'supplier_shortage' and (x).financial_impact = 30 and (x).status = 'open' and (x).owner_role = 'warehouse' and (x).owner is null and 'completion' = any ((x).blocks)
   from (select pg_temp.exc('supdisc:' || (select id from flow.supplier_discrepancies where disc_ref = 'SD-EXC-1')) x) q), 'shortage exception: critical (order due tomorrow), 6 x 5 = 30 at stake, blocks completion');
select pg_temp.assert((select count(*) from flow.v_exceptions_open where 'SD-EXC-1' is not null and '#E1' = any (order_refs) and 'EXC-POLO' = any (skus) and 'AF-PO-EXC' = any (po_refs) and needs_owner) >= 1, 'links to order, sku and PO visible; flagged as needing an owner');

-- ---- 2. idempotent: running again creates and changes nothing ----
select pg_temp.open_count() as n_before \gset
select count(*) as log_before from flow.exception_actions \gset
select flow.exceptions_detect_all();
select pg_temp.assert(pg_temp.open_count() = :n_before, 'second detection run creates no duplicates');
select pg_temp.assert((select count(*) from flow.exception_actions) = :log_before, 'second run writes nothing to the audit trail');

-- ---- 3. completion is blocked while the exception is open ----
select pg_temp.assert(not (flow.order_completion_check(:'e1')->>'can_complete')::boolean and flow.order_completion_check(:'e1')->>'blockers' like '%blocking exception%', 'order E1 cannot complete: ' || flow.order_completion_check(:'e1')::text);
select pg_temp.assert((flow.order_completion_check(:'e2')->>'can_complete')::boolean is not null, 'orders with no blocking exceptions are unaffected by this rule');

-- ---- 4. artwork exception appears for an order due soon and clears when fixed ----
select pg_temp.assert((select (x).type_code = 'artwork_blocked' and (x).severity = 'critical' from (select pg_temp.exc('artwork:' || :'e1') x) q), 'E1 (due tomorrow, no artwork) -> critical artwork exception');
select flow.artwork_upsert(jsonb_build_array(jsonb_build_object('order_id', :'e1', 'deco_line_id', 'EDL1', 'area', 'Left chest', 'process', 'embroidery', 'production_url', 'https://x.test/a.dst',
   'stitch_count', 5000, 'file_format', 'DST', 'approval_status', 'approved')));
select flow.artwork_mark_stored((select id from flow.artwork_files where order_id = :'e1' and is_current), 'artwork/e1.dst', 'h', true);
select flow.exceptions_detect_all();
select pg_temp.assert((select (x).status = 'resolved' and (x).auto_resolved from (select pg_temp.exc('artwork:' || :'e1') x) q), 'artwork exception auto-resolved once the file is approved and stored');
select pg_temp.assert((select count(*) from flow.v_exception_history h join flow.exceptions e on e.id = h.exception_id where e.dedupe_key = 'artwork:' || :'e1' and h.action in ('detected','auto_resolved')) = 2, 'audit trail shows detected and auto-resolved');

-- ---- 5. the unrelated supplier exception stays; working it: assign, note, status, resolve rules ----
select id as xs from flow.exceptions where dedupe_key = 'supdisc:' || (select id from flow.supplier_discrepancies where disc_ref = 'SD-EXC-1') \gset
select pg_temp.assert(not (flow.assign_exception(:'xs', '', 'tester')->>'ok')::boolean, 'owner required to assign');
select pg_temp.assert((flow.assign_exception(:'xs', 'sam@atam.test', 'tester', 'taking this')->>'ok')::boolean, 'assign accepted');
select pg_temp.assert((select status = 'investigating' and owner = 'sam@atam.test' from flow.exceptions where id = :'xs'), 'assigned: now investigating with a named owner');
select pg_temp.assert((flow.add_exception_note(:'xs', 'sam@atam.test', 'phoned the supplier, replacement promised Friday', true)->>'ok')::boolean, 'action recorded');
select pg_temp.assert((flow.set_exception_status(:'xs', 'awaiting_supplier', 'sam@atam.test', 'waiting on them')->>'ok')::boolean, 'status moved to awaiting supplier');
select pg_temp.assert(not (flow.set_exception_status(:'xs', 'resolved', 'sam@atam.test')->>'ok')::boolean, 'cannot close through the status call');
select pg_temp.assert(not (flow.resolve_exception(:'xs', 'fixed', '', 'sam@atam.test')->>'ok')::boolean and not (flow.resolve_exception(:'xs', 'made_up', 'x', 'sam@atam.test')->>'ok')::boolean, 'resolving needs a note and a known method');
select pg_temp.assert((flow.resolve_exception(:'xs', 'supplier_resolved', 'replacement arrived', 'sam@atam.test')->>'ok')::boolean, 'resolved');

-- ---- 6. resolved by a person but the problem is still there: next detection reopens it ----
select flow.exceptions_detect_all();
select pg_temp.assert((select status = 'open' and escalation_level = 0 from flow.exceptions where id = :'xs'), 'reopened by the detector because the supplier discrepancy is still open');
select pg_temp.assert((select count(*) from flow.exceptions where dedupe_key = 'supdisc:' || (select id from flow.supplier_discrepancies where disc_ref = 'SD-EXC-1')) = 1, 'still a single record, not a duplicate');
select pg_temp.assert((select count(*) from flow.exception_actions where exception_id = :'xs' and action = 'reopened') = 1, 'reopen is audited');

-- ---- 7. cancelled (false alarm) is not raised again; write-off needs reason and amount ----
select pg_temp.assert(not (flow.write_off_exception(:'xs', 'accept loss', null, 'boss')->>'ok')::boolean, 'write-off needs the amount');
select pg_temp.assert((flow.cancel_exception(:'xs', 'supplier confirmed it was a counting error', 'boss')->>'ok')::boolean, 'cancelled');
select flow.exceptions_detect_all();
select pg_temp.assert((select status from flow.exceptions where id = :'xs') = 'cancelled' and (select count(*) from flow.exceptions where dedupe_key = (select dedupe_key from flow.exceptions where id = :'xs')) = 1, 'a cancelled exception is not re-raised');
select pg_temp.assert((flow.reopen_exception(:'xs', 'boss', 'it was real after all')->>'ok')::boolean, 'reopen accepted');
select pg_temp.assert((select status from flow.exceptions where id = :'xs') = 'open', 'a person can reopen it');
select pg_temp.assert((flow.write_off_exception(:'xs', 'accepted as a loss', 30, 'boss')->>'ok')::boolean, 'write-off accepted');
select pg_temp.assert((select status = 'written_off' and financial_impact = 30 from flow.exceptions where id = :'xs'), 'written off with amount');

-- ---- 8. escalation ladder ----
select flow.exc_raise('manual_review', 'manual:esc-test', null, 'test escalation', '[]'::jsonb, '{"severity":"high"}'::jsonb);
select id as xe from flow.exceptions where dedupe_key = 'manual:esc-test' \gset
update flow.exceptions set response_deadline = now() - interval '1 hour' where id = :'xe';
select pg_temp.assert((flow.exceptions_escalate()->>'escalated')::int >= 1, 'overdue exception escalated');
select pg_temp.assert((select escalation_level = 1 and owner_role = 'manager' and response_deadline > now() + interval '11 hours' from flow.exceptions where id = :'xe'), 'level 1: manager, new deadline from the ladder (12 h for high)');
select flow.exceptions_escalate();
select pg_temp.assert((select escalation_level = 1 from flow.exceptions where id = :'xe'), 'running escalation again immediately does nothing for it');
update flow.exceptions set response_deadline = now() - interval '1 hour' where id = :'xe';
select flow.exceptions_escalate();
select pg_temp.assert((select escalation_level = 2 and owner_role = 'admin' from flow.exceptions where id = :'xe'), 'level 2: admin');
update flow.exceptions set response_deadline = now() - interval '1 hour' where id = :'xe';
select flow.exceptions_escalate();
select pg_temp.assert((select escalation_level = 2 from flow.exceptions where id = :'xe'), 'stops at the top of the ladder');

-- ---- 9. integration health ----
update flow.flow_runs set started_at = now() - interval '10 hours', finished_at = now() - interval '10 hours' where workflow = 'sync_orders';
select flow.exceptions_detect_all();
select pg_temp.assert((select (x).type_code = 'sync_stale' and (x).severity = 'critical' from (select pg_temp.exc('sync:sync_orders') x) q), 'no successful sync for 10 h (allowed 150 min) -> critical stale exception');
insert into flow.flow_runs (workflow, status, started_at, finished_at) values ('sync_orders', 'success', now(), now());
select flow.exceptions_detect_all();
select pg_temp.assert((select (x).status = 'resolved' from (select pg_temp.exc('sync:sync_orders') x) q), 'clears when a run succeeds');
insert into flow.flow_runs (workflow, status, started_at, finished_at, error) values ('sync_stock', 'failed', now(), now(), 'DecoNetwork returned 500');
select flow.exceptions_detect_all();
select pg_temp.assert((select (x).type_code = 'sync_failed' and (x).description like '%500%' from (select pg_temp.exc('sync:sync_stock') x) q), 'failed run raises an exception with the error');

-- ---- 10. producer silence ----
insert into flow.producers (code, name, address, turnaround_days, capable_methods) values ('EXP', 'Exc Producer', '1 Lane', 3, '{embroidery}');
select id as prod from flow.producers where code = 'EXP' \gset
select id as l1 from flow.order_lines where deco_workflow_item_id = 'EL1' \gset
insert into flow.tp_movements (movement_code, producer_id, status, dispatch_date, carrier) values ('TP-EXC-1', :'prod', 'dispatched', current_date - 4, 'courier');
select id as mv from flow.tp_movements where movement_code = 'TP-EXC-1' \gset
insert into flow.tp_movement_items (movement_id, order_id, order_line_id, sku, colour, size, qty_sent) values (:'mv', :'e1', :'l1', 'EXC-POLO', 'Navy', 'M', 20);
select flow.exceptions_detect_all();
select pg_temp.assert((select (x).type_code = 'producer_no_receipt' and (x).severity = 'critical' and (x).status = 'awaiting_producer' and (x).financial_impact = 100 from (select pg_temp.exc('noreceipt:' || :'mv') x) q), 'no receipt 4 days after dispatch: critical, £100 stock exposed');
select pg_temp.assert((select count(*) from flow.exceptions where dedupe_key = 'notrack:' || :'mv') = 1, 'dispatched with no tracking is also flagged');
update flow.tp_movements set received_by_producer_at = now(), status = 'received_by_producer' where id = :'mv';
select flow.exceptions_detect_all();
select pg_temp.assert((select status = 'resolved' from flow.exceptions where dedupe_key = 'noreceipt:' || :'mv'), 'clears when the producer confirms');

-- ---- 11. orders at risk, and completed-with-open-issue ----
select pg_temp.assert((select (x).type_code = 'order_at_risk' and (x).severity = 'critical' and (x).financial_impact = 500 from (select pg_temp.exc('risk:' || :'e3') x) q), 'overdue order E3 -> critical, £500 revenue at risk');
select pg_temp.assert((select count(*) from flow.exceptions where dedupe_key = 'int_order:' || :'e3') = 0, 'order with a due date raises no integrity exception');
select flow.exc_raise('artwork_blocked', 'artwork:forced', null, 'forced blocking exception for test', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'e2')), '{}'::jsonb);
update flow.orders set order_status = 'dispatched' where id = :'e2';
select flow.exceptions_detect_all();
select pg_temp.assert((select (x).type_code = 'completed_with_open_exception' and (x).severity = 'critical' from (select pg_temp.exc('completed_open:' || :'e2') x) q), 'order shipped while a blocking exception is open -> critical exception');

-- ---- 12. integrity: unknown holder, negative stock, hold with no reason ----
insert into flow.stock_custody (order_line_id, location_state, qty) values (:'l1', 'at_producer', 7);
insert into flow.stock_items (sku, qty_on_hand) values ('EXC-NEG', -3);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, order_value) values ('E4', '#E4', 'Held', now() + interval '10 days', 'on_hold', 7, 100);
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'integrity_custody' and status = 'open') >= 1, 'units recorded at a producer with no movement or producer -> exception');
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'integrity_stock' and description like '%EXC-NEG%') = 1, 'negative stock flagged');
select pg_temp.assert((select count(*) from flow.exceptions where dedupe_key = 'hold_unexplained' and status = 'open') = 1, 'orders on hold with no reason are one aggregated exception');
select pg_temp.assert((select count(*) from flow.v_order_accountability where order_ref = '#E4' and next_action is null) = 1, 'accountability view shows the held order has no known next action');
select pg_temp.assert((select count(*) from flow.v_order_accountability where order_ref = '#E1' and owner is not null and location is not null and next_action is not null) = 1, 'a normal order has owner, location and next action');

-- ---- 13. manual exception, summary, permissions, audit immutability ----
select pg_temp.assert((flow.raise_manual_exception('quality', 'high', 'Customer reports faded print on #E1', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'e1')), 'sam@atam.test', now() + interval '8 hours', 'sam@atam.test', '{completion}')->>'ok')::boolean, 'manual exception raised');
select pg_temp.assert((select count(*) from flow.v_exceptions_open where detected_by = 'manual_review' and owner = 'sam@atam.test' and is_blocking) = 1, 'manual exception has owner and blocks');
select pg_temp.assert((select count(*) from flow.v_exception_summary) > 0 and (select sum(n) from flow.v_exception_summary) = pg_temp.open_count(), 'summary counts match');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_resolve_exception(uuid,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_exceptions_detect_all()', 'execute'), 'browser roles cannot act directly');
do $$ begin begin update flow.exception_actions set note = 'tampered' where id = (select min(id) from flow.exception_actions); raise exception 'audit trail was editable';
  exception when others then if sqlerrm not like '%append-only%' then raise; end if; end; end $$;
-- keep later suites isolated
update flow.orders set is_active = false where deco_order_id in ('E1','E2','E3','E4');
\echo exceptions tests passed

-- ---- 14. browser access: signed-in members read the dashboard views; strangers and anonymous users get nothing ----
insert into flow.user_roles values ('00000000-0000-0000-0000-0000000000e1', 'manager') on conflict do nothing;
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.flow_runs where workflow = 'exceptions') >= 1, 'each detection run is recorded');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
select pg_temp.assert((select public.ui_my_role()) = 'manager', 'the page can learn the signed-in role');
select pg_temp.assert((select count(*) from public.ui_exceptions) > 0 and (select count(*) from public.ui_exception_types) > 10 and (select last_detection_at is not null from public.ui_status), 'a member can read exceptions, types and last-checked time');
select pg_temp.assert((select count(*) from public.ui_order_accountability) > 0 and (select count(*) from public.ui_exception_history) > 0, 'accountability and history views readable');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000ff', false);
select pg_temp.assert((select count(*) from public.ui_exceptions) = 0 and public.ui_my_role() is null, 'a signed-in stranger with no role sees nothing');
reset role;
set role anon;
do $$ begin begin perform count(*) from public.ui_exceptions; raise exception 'anonymous could read exceptions'; exception when insufficient_privilege then null; end; end $$;
reset role;
\echo ui view tests passed
