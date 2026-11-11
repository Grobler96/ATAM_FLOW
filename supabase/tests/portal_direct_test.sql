-- Direct dispatch support: the decorator sees the delivery address (only for direct jobs, only after accepting) and must add a finished-goods photo.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.login(p_uid text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false); end $$;

update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'false') where key = 'artwork.options';
insert into flow.producers (code, name, turnaround_days, can_direct_dispatch, capable_methods) values ('PDD', 'Direct Decorators', 3, true, '{dtf}'), ('PDX', 'Other Direct Decorators', 3, true, '{dtf}');
select id as pd from flow.producers where code = 'PDD' \gset
select id as px from flow.producers where code = 'PDX' \gset
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, ship_to_override) values
  ('PDO1', '#PD1', 'Direct Customer', now() + interval '9 days', 'ready_for_production', true, 1, 6, '1 Practice Street, Testville, TE1 1ST'),
  ('PDO2', '#PD2', 'Normal Customer', now() + interval '9 days', 'ready_for_production', true, 1, 6, '2 Return Road, Testville, TE2 2ST'),
  ('PDO3', '#PD3', 'No Address Customer', now() + interval '9 days', 'ready_for_production', true, 1, 6, null);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, garment_type, product_name, qty_required, decoration_methods)
  select v.wi, o.id, v.sku, 'Navy', 'M', 'Polos', 'Polo shirt', 6, '{dtf}' from (values ('PDL1', 'PDO1', 'PD-POLO-1'), ('PDL2', 'PDO2', 'PD-POLO-2'), ('PDL3', 'PDO3', 'PD-POLO-3')) v(wi, oid, sku) join flow.orders o on o.deco_order_id = v.oid;
select flow.generate_bins('OUT', 'OUT', 6);
select id as l1 from flow.order_lines where deco_workflow_item_id = 'PDL1' \gset
select id as l2 from flow.order_lines where deco_workflow_item_id = 'PDL2' \gset
select id as l3 from flow.order_lines where deco_workflow_item_id = 'PDL3' \gset
create temp table r (k text primary key, j jsonb); grant all on r to authenticated;
insert into r select 'direct', flow.create_outbound_movement(:'pd', jsonb_build_array(jsonb_build_object('order_line_id', :'l1', 'qty', 6)), 'wh', 'direct_dispatch_to_customer');
insert into r select 'normal', flow.create_outbound_movement(:'pd', jsonb_build_array(jsonb_build_object('order_line_id', :'l2', 'qty', 6)), 'wh');
insert into r select 'noaddr', flow.create_outbound_movement(:'pd', jsonb_build_array(jsonb_build_object('order_line_id', :'l3', 'qty', 6)), 'wh', 'direct_dispatch_to_customer');
select j->>'movement_code' as mvd from r where k = 'direct' \gset
select j->>'movement_code' as mvn from r where k = 'normal' \gset
select j->>'movement_code' as mva from r where k = 'noaddr' \gset
select flow.tp_scan(c, e, 'w', case when e = 'dispatched' then '{"date":"2026-11-09"}'::jsonb else '{}'::jsonb end) from unnest(array[:'mvd', :'mvn', :'mva']) c, unnest(array['picked', 'packed', 'dispatched']) with ordinality t(e, o) order by c, o;
select pg_temp.assert((flow.pp_add_user(:'pd', 'sam@direct-decor.test', 'Sam', 't')->>'ok')::bool and (flow.pp_add_user(:'px', 'nia@other-direct.test', 'Nia', 't')->>'ok')::bool, 'decorator logins invited');
-- sign-in accounts are created after the invitation, as in real use
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000003d1', 'sam@direct-decor.test', now()), ('00000000-0000-0000-0000-0000000003d2', 'nia@other-direct.test', now());

-- 1. the address is hidden until the job is accepted
select pg_temp.login('00000000-0000-0000-0000-0000000003d1'); set role authenticated;
insert into r select 'before', public.portal_job(:'mvd');
select pg_temp.assert((select j->'ship_to' = 'null'::jsonb or not (j ? 'ship_to') from r where k = 'before'), 'no address before the decorator accepts the job');
select public.portal_accept(:'mvd'); select public.portal_accept(:'mvn'); select public.portal_accept(:'mva');
insert into r select 'after', public.portal_job(:'mvd');
select pg_temp.assert((select j->'ship_to'->0->>'address' = '1 Practice Street, Testville, TE1 1ST' and j->'ship_to'->0->>'order_ref' = '#PD1' and j->'ship_to'->0->>'customer' = 'Direct Customer' from r where k = 'after'), 'after accepting, a direct job shows where to send it');
insert into r select 'normaljob', public.portal_job(:'mvn');
select pg_temp.assert((select j->'ship_to' = 'null'::jsonb or not (j ? 'ship_to') from r where k = 'normaljob'), 'a job that comes back to us never shows a customer address');
insert into r select 'noaddrjob', public.portal_job(:'mva');
select pg_temp.assert((select j->'ship_to'->0->>'address' is null and jsonb_array_length(j->'ship_to') = 1 from r where k = 'noaddrjob'), 'a direct job with no address on file says so rather than guessing');
reset role;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
select pg_temp.login('00000000-0000-0000-0000-0000000003d2'); set role authenticated;
select pg_temp.assert(pg_temp.try(format('select public.portal_job(%L)', :'mvd')) like '%not found%', 'another decorator cannot read the job or its address');
reset role;
select set_config('request.jwt.claim.sub', '', false); select set_config('request.jwt.claims', '{}', false);
select pg_temp.assert(flow.dispatch_address((select id from flow.orders where deco_order_id = 'PDO1'))->>'ship_to' = '1 Practice Street, Testville, TE1 1ST', 'the staff dispatch screens use the same fallback');

-- 2. a finished-goods photo is needed before a direct job can be marked complete
select i.id as itd from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where m.movement_code = :'mvd' \gset
select i.id as itn from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where m.movement_code = :'mvn' \gset
select pg_temp.login('00000000-0000-0000-0000-0000000003d1'); set role authenticated;
select public.portal_check_in(:'mvd', jsonb_build_array(jsonb_build_object('item_id', :'itd', 'qty_counted', 6, 'qty_damaged', 0)), null) as ci \gset
select public.portal_check_in(:'mvn', jsonb_build_array(jsonb_build_object('item_id', :'itn', 'qty_counted', 6, 'qty_damaged', 0)), null) as ci2 \gset
select public.portal_stage(:'mvd', 'in_production', null, null) as sd \gset
select public.portal_stage(:'mvn', 'in_production', null, null) as sn \gset
\echo :sd :sn
select pg_temp.assert((:'sd'::jsonb->>'ok')::bool and (:'sn'::jsonb->>'ok')::bool, 'both jobs start production');
insert into r select 'nophoto', public.portal_stage(:'mvd', 'production_complete', null, null);
select pg_temp.assert((select not (j->>'ok')::bool and (j->>'needs_photo')::bool and j->>'error' like '%photo of the finished goods%' from r where k = 'nophoto'), 'a direct job cannot be completed without a finished-goods photo');
select pg_temp.assert((select public.portal_job(:'mvd')->>'status') = 'in_production', 'the refused job did not move on');
select pg_temp.assert((public.portal_stage(:'mvn', 'production_complete', null, null)->>'ok')::bool, 'a job that comes back to us is not held up (our own return check covers it)');
select public.portal_evidence_add(:'mvd', null, (:'pd')::text || '/' || :'mvd' || '/other.jpg', 'issue', 'not the finished goods');
select pg_temp.assert(not (public.portal_stage(:'mvd', 'production_complete', null, null)->>'ok')::bool, 'a photo of the wrong kind does not count');
select pg_temp.assert((public.portal_evidence_add(:'mvd', null, (:'pd')::text || '/' || :'mvd' || '/done.jpg', 'finished', 'finished polos')->>'ok')::bool, 'the finished goods photo is saved');
select pg_temp.assert((public.portal_stage(:'mvd', 'production_complete', null, null)->>'ok')::bool, 'with the photo the direct job can be marked complete');
insert into r select 'closedjob', public.portal_job(:'mvd');
reset role;
select flow.tp_direct_dispatch(:'mvd', 'PRACTICE123', 'DPD', '{}'::jsonb, 'w');
select pg_temp.login('00000000-0000-0000-0000-0000000003d1'); set role authenticated;
select pg_temp.assert((select j->'ship_to' = 'null'::jsonb or not (j ? 'ship_to') from (select public.portal_job(:'mvd') j) z), 'once the job is closed the address is no longer shown');
reset role;
\echo portal_direct_test OK
