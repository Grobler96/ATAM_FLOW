-- DecoNetwork Priority Order flag -> third-party scope.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at) values
 ('PRF1', '#PRF1', 'Flag One', now() + interval '9 days', 'ready_for_production', true, 1, 12, now() - interval '2 days'),
 ('PRF2', '#PRF2', 'Flag Two', now() + interval '9 days', 'awaiting_stock', false, 1, 12, now() - interval '2 days');
select id as o1 from flow.orders where deco_order_id = 'PRF1' \gset
select id as o2 from flow.orders where deco_order_id = 'PRF2' \gset

select pg_temp.assert(not (flow.sync_priority_flags('{"a":1}'::jsonb, 't')->>'ok')::bool, 'a list is required');
insert into r select 'first', flow.sync_priority_flags('[{"order_id":"PRF1","is_priority":true},{"order_id":"PRF2","is_priority":false},{"order_id":"NOT-OURS","is_priority":true}]'::jsonb, 'test');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'changed')::int = 2 and (j->>'flagged')::int = 2 and (j->>'not_in_flow')::int = 1 from r where k = 'first'), 'first read: two orders set, one unknown: ' || (select j::text from r where k = 'first'));
select pg_temp.assert((select scope = 'third_party' and source = 'deco_flag' from public.ui_order_scope where order_ref = '#PRF1'), 'flagged order is third party');
select pg_temp.assert((select scope = 'unclassified' from public.ui_order_scope where order_ref = '#PRF2'), 'an unflagged order stays unclassified, not in-house');
select pg_temp.assert(not exists (select 1 from flow.order_changes where order_id in (:'o1', :'o2')), 'the first time a flag is seen is not a change');

-- idempotent
insert into r select 'again', flow.sync_priority_flags('[{"order_id":"PRF1","is_priority":true}]'::jsonb, 'test');
select pg_temp.assert((select (j->>'changed')::int = 0 from r where k = 'again'), 'reading the same flag again changes nothing');

-- a manual scope wins over the flag
select flow.sc_set_order_scope(:'o1', 'in_house', 'We are doing this one ourselves', 'tester');
select pg_temp.assert((select scope = 'in_house' and source = 'override' from public.ui_order_scope where order_ref = '#PRF1'), 'manual scope wins over the DecoNetwork flag');
select flow.sc_set_order_scope(:'o1', null, 'Back to following DecoNetwork', 'tester');

-- the flag changing on a protected order is a change to review
insert into r select 'flip', flow.sync_priority_flags('[{"order_id":"PRF1","is_priority":false}]'::jsonb, 'test');
select pg_temp.assert((select count(*) = 1 and bool_and(severity = 'high') from flow.order_changes where order_id = :'o1' and field = 'third_party_flag' and old_value = 'on' and new_value = 'off'), 'flag removed from a protected order raises a high-severity change');
select pg_temp.assert((select scope = 'unclassified' from public.ui_order_scope where order_ref = '#PRF1'), 'flag removed: no longer third party');
select pg_temp.assert(exists (select 1 from flow.flow_runs where workflow = 'priority_flags'), 'each read is logged');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_sync_priority_flags(jsonb,text)', 'execute'), 'wrapper closed to browser roles');
\echo priority_flag_test OK
