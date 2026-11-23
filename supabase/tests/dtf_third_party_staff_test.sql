-- Staff side of third-party DTF prints: the view, and moving transfers forward on a decorator's behalf.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000d1', 'manager'), ('00000000-0000-0000-0000-0000000000d2', 'viewer') on conflict do nothing;
insert into flow.producers (code, name, address, contact_name, turnaround_days, can_direct_dispatch, capable_methods) values ('TPS', 'Staff Test Transfers', '1 Mill St', 'Sam', 3, false, '{dtf}');
select id as tp from flow.producers where code = 'TPS' \gset
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, third_party_flag, producer_id, is_active) values
 ('TS1', '#TS1', 'Third', now() + interval '9 days', 'awaiting_stock', false, 1, 5, '{dtf}', true, :'tp', true),
 ('TS2', '#TS2', 'In house', now() + interval '9 days', 'awaiting_stock', false, 1, 5, '{dtf}', false, null, true);
select id as o1 from flow.orders where deco_order_id = 'TS1' \gset
select id as o2 from flow.orders where deco_order_id = 'TS2' \gset
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, qty_required, decoration_methods, product_name) values ('TSW1', 'M1', :'o1', 'S1', 5, '{dtf}', 'Polo'), ('TSW2', 'M2', :'o2', 'S2', 5, '{dtf}', 'Tee');
select flow.dtf_sync(:'o1', '[{"deco_line_id":"M1","area":"Back","qty":5},{"deco_line_id":"M1","area":"Front","qty":5}]'::jsonb);
select flow.dtf_sync(:'o2', '[{"deco_line_id":"M2","area":"Back","qty":5}]'::jsonb);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', false);
select pg_temp.assert((select count(*) = 2 and bool_and(producer_name = 'Staff Test Transfers') from public.ui_dtf_third_party where order_ref = '#TS1'), 'the view shows the third-party transfers with their decorator');
select pg_temp.assert(not exists (select 1 from public.ui_dtf_third_party where order_ref = '#TS2'), 'in-house work is not in the third-party view');
select id as i1 from flow.dtf_items where order_id = :'o1' and area = 'Back' \gset
select id as i2 from flow.dtf_items where order_id = :'o1' and area = 'Front' \gset
select id as i3 from flow.dtf_items where order_id = :'o2' \gset
select pg_temp.assert((select (public.dtf_third_party_set(array[:'i1']::uuid[], 'in_progress')->>'ok')::bool), 'a manager can start a transfer');
select pg_temp.assert((select status = 'in_progress' and status_by like 'staff:%' and status_at is not null from flow.dtf_items where id = :'i1'), 'it is marked with who and when');
select pg_temp.assert((select (public.dtf_third_party_set(array[:'i1', :'i2']::uuid[], 'done')->>'changed')::int = 2), 'both can be marked made, from either earlier stage');
select pg_temp.assert(not (select (public.dtf_third_party_set(array[:'i1']::uuid[], 'in_progress')->>'ok')::bool), 'moves only go forward');
select pg_temp.assert(not (select (public.dtf_third_party_set(array[:'i3']::uuid[], 'done')->>'ok')::bool), 'an in-house transfer cannot be moved here');
select pg_temp.assert(not (select (public.dtf_third_party_set(array[:'i1']::uuid[], 'bogus')->>'ok')::bool), 'an unknown stage is refused');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where action = 'staff_dtf_done'), 'the move is in the audit log');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d2', false);
select pg_temp.assert(not (select (public.dtf_third_party_set(array[:'i1']::uuid[], 'done')->>'ok')::bool), 'a viewer cannot confirm transfers');
select pg_temp.assert(not has_function_privilege('anon', 'public.dtf_third_party_set(uuid[],text)', 'execute') and not has_table_privilege('anon', 'public.ui_dtf_third_party', 'select'), 'anonymous visitors have no access');
select 'dtf_third_party_staff_test OK' as result;
