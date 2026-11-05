-- Order changes after work began, impact, review gate, and hold/release/priority overrides.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, shipping_method, created_at) values
 ('OCH1', '#OCH1', 'Change Co', now() + interval '10 days', 'ready_for_production', true, 1, 24, 'Courier', now() - interval '3 days'),
 ('OCH2', '#OCH2', 'Early Co', now() + interval '20 days', 'awaiting_stock', false, 1, 10, 'Courier', now() - interval '3 days');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods) select 'OCHL1', id, 'OCH-POLO-M', 'Navy', 'M', 'Polo', 24, '{embroidery}' from flow.orders where deco_order_id = 'OCH1';
select id as o1 from flow.orders where deco_order_id = 'OCH1' \gset
select id as o2 from flow.orders where deco_order_id = 'OCH2' \gset
delete from flow.order_changes where order_id in (:'o1', :'o2');

-- 1. unprotected order: a change is logged as a warning only
update flow.orders set total_units = 12 where id = :'o2';
select pg_temp.assert((select count(*) = 1 and bool_and(severity = 'warning') from flow.order_changes where order_id = :'o2'), 'early order change is a warning');

-- 2. protected order (ready_for_production): changes are high, several fields tracked, label flagged for reprint
update flow.orders set label_status = 'printed' where id = :'o1';
update flow.orders set due_date = due_date + interval '4 days', total_units = 30 where id = :'o1';
select pg_temp.assert((select count(*) = 2 and bool_and(severity = 'high') from flow.order_changes where order_id = :'o1'), 'protected order changes are high: ' || (select coalesce(string_agg(field || '/' || severity, ','), 'none') from flow.order_changes where order_id = :'o1'));
select pg_temp.assert((select label_status = 'reprint_needed' from flow.orders where id = :'o1'), 'printed label flagged for reprint');
update flow.orders set due_date = due_date where id = :'o1';
select pg_temp.assert((select count(*) = 2 from flow.order_changes where order_id = :'o1'), 'no change, no new row');

-- 3. line quantity change
update flow.order_lines set qty_required = 30 where deco_workflow_item_id = 'OCHL1';
select pg_temp.assert((select count(*) = 1 from flow.order_changes where order_id = :'o1' and field = 'line_qty' and old_value = '24' and new_value = '30'), 'line qty change logged');

-- 4. impact lists what to do
insert into r select 'imp', flow.oc_impact(:'o1');
select pg_temp.assert((select (j->>'ok')::bool and jsonb_array_length(j->'actions') >= 2 from r where k = 'imp'), 'impact recommends actions: ' || (select j::text from r where k = 'imp'));

-- 5. exception blocks dispatch until reviewed
select pg_temp.assert(jsonb_array_length(flow.exc_detect_order_changes()) >= 1 and exists (select 1 from jsonb_array_elements(flow.exc_detect_order_changes()) e where e->>'key' = 'ochg:' || :'o1'), 'order_changed detected for the protected order');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.exc_detect_order_changes()) e where e->>'key' = 'ochg:' || :'o2'), 'warnings do not raise the exception');

-- 6. review needs a note for high-severity
select pg_temp.assert((flow.oc_review_order(:'o1', 'accepted', '', 't')->>'needs_reason')::bool, 'high-severity review needs a note');
insert into r select 'rv', flow.oc_review_order(:'o1', 'accepted', 'Re-planned, new date agreed with customer', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'reviewed')::int = 3 from r where k = 'rv'), 'all three reviewed');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.exc_detect_order_changes()) e where e->>'key' = 'ochg:' || :'o1'), 'exception clears after review');
select pg_temp.assert(not (flow.oc_review((select id from flow.order_changes where order_id = :'o1' limit 1), 'accepted', 'again please', 't')->>'ok')::bool, 'cannot review twice');
select pg_temp.assert((select (flow.oc_review(id, 'dismissed', null, 't')->>'ok')::bool from flow.order_changes where order_id = :'o2' limit 1), 'warnings can be dismissed without a note');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'order_change_accepted'), 'review audited');

-- 7. hold / release
select pg_temp.assert((flow.ov_hold_order(:'o1', 'no', 't')->>'needs_reason')::bool, 'hold needs a reason');
insert into r select 'hold', flow.ov_hold_order(:'o1', 'Customer artwork dispute', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'hold') and (select order_status = 'on_hold' and status_before_hold = 'ready_for_production' from flow.orders where id = :'o1'), 'held, previous status kept');
select pg_temp.assert(not (flow.ov_hold_order(:'o1', 'Customer artwork dispute', 't')->>'ok')::bool, 'cannot hold twice');
select pg_temp.assert((select bool_or(o->>'hold_reason' like 'Held in ATAM_FLOW%') from jsonb_array_elements(flow.scheduler_input()->'orders') o where o->>'order_ref' = '#OCH1'), 'planner sees the manual hold');
select pg_temp.assert((flow.ov_release_order(:'o1', '', 't')->>'needs_reason')::bool, 'release needs a note');
insert into r select 'rel', flow.ov_release_order(:'o1', 'Dispute resolved', 'tester');
select pg_temp.assert((select j->>'restored' = 'ready_for_production' from r where k = 'rel') and (select order_status = 'ready_for_production' and status_before_hold is null from flow.orders where id = :'o1'), 'restored the previous status');
select pg_temp.assert(not (flow.ov_release_order(:'o1', 'Not held now', 't')->>'ok')::bool, 'cannot release an order that is not held');

-- 8. hold refused while a job is running
insert into flow.job_steps (order_id, method_code, step_no, status) values (:'o1', 'embroidery', 1, 'in_progress');
select pg_temp.assert(not (flow.ov_hold_order(:'o1', 'Trying to hold mid-job', 't')->>'ok')::bool, 'cannot hold while a job step is in progress');

-- 9. priority
select pg_temp.assert(not (flow.ov_set_priority(:'o2', 9, 'Bad value here', 't')->>'ok')::bool, 'priority range checked');
select pg_temp.assert((flow.ov_set_priority(:'o2', 2, '', 't')->>'needs_reason')::bool, 'priority needs a reason');
insert into r select 'pri', flow.ov_set_priority(:'o2', 2, 'Customer called, needs it early', 'tester');
select pg_temp.assert((select priority = 2 and priority_note like 'Customer called%' from flow.orders where id = :'o2'), 'priority set');
select pg_temp.assert((select (before->>'priority')::int = 0 from flow.audit_log where action = 'order_priority' order by id desc limit 1), 'previous priority audited');

-- 10. grants: wrappers service_role only
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_ov_hold_order(uuid,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_ov_hold_order(uuid,text,text)', 'execute'), 'wrapper closed to browser roles');
\echo order_changes_test OK
