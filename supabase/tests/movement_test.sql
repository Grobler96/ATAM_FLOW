-- Producer movement flows: producers, rates, what can be sent, cancelling, read models.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'false') where key = 'artwork.options';
create temp table r (k text primary key, j jsonb);

-- 1. producers
insert into r select 'p1', flow.mv_upsert_producer('{"name":"Moveworks Embroidery","capable_methods":["Embroidery"," dtf"],"turnaround_days":4,"email":"a@b.test","can_direct_dispatch":true}'::jsonb, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'created')::bool and j->>'code' = 'MOVEWO' from r where k = 'p1'), 'producer created with a code: ' || (select j::text from r where k = 'p1'));
select (j->>'producer_id')::uuid as mp from r where k = 'p1' \gset
select pg_temp.assert((select capable_methods = '{embroidery,dtf}' and turnaround_days = 4 from flow.producers where id = :'mp'), 'methods normalised');
insert into r select 'p2', flow.mv_upsert_producer('{"name":"Moveworks Embroidery"}'::jsonb, 'tester');
select pg_temp.assert((select j->>'code' = 'MOVEWO2' from r where k = 'p2'), 'duplicate names get a distinct code');
select pg_temp.assert(not (flow.mv_upsert_producer('{"name":"  "}'::jsonb, 't')->>'ok')::bool and not (flow.mv_upsert_producer('{"name":"X","turnaround_days":99}'::jsonb, 't')->>'ok')::bool, 'blank name and silly turnaround refused');
insert into r select 'p3', flow.mv_upsert_producer(jsonb_build_object('id', :'mp', 'name', 'Moveworks Embroidery', 'phone', '0113 000', 'is_active', true), 'tester');
select pg_temp.assert((select phone = '0113 000' and turnaround_days = 4 and email = 'a@b.test' from flow.producers where id = :'mp'), 'update keeps fields not sent');
select pg_temp.assert((select count(*) from flow.audit_log where action in ('producer_created', 'producer_updated')) >= 3, 'producer changes audited');

-- 2. rates
select pg_temp.assert((flow.mv_set_rate(:'mp', 'Embroidery', 'per_1000_stitches', 1.2, 10, 25, null, 'tester')->>'ok')::bool, 'rate saved');
insert into r select 'rate2', flow.mv_set_rate(:'mp', 'embroidery', 'per_1000_stitches', 1.5, 10, 25, null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'rate2') and (select count(*) from flow.producer_rates where producer_id = :'mp') = 1 and (select unit_price from flow.producer_rates where producer_id = :'mp') = 1.5, 'rate upsert replaces, no duplicate');
select pg_temp.assert(not (flow.mv_set_rate(:'mp', 'dtf', 'per_hour', 1, 0, 0, null, 't')->>'ok')::bool and not (flow.mv_set_rate(:'mp', 'dtf', 'per_piece', -1, 0, 0, null, 't')->>'ok')::bool, 'bad basis and negative price refused');

-- 3. sendable lines
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values
  ('M1', '#M1', 'Move Customer', '2026-12-05 12:00+00', 'ready_for_production', true, 1, 30), ('M2', '#M2', 'No Stock', '2026-12-06 12:00+00', 'awaiting_stock', false, 9, 10);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select v.wi, o.id, v.sku, 'Navy', v.s, 'Polo', v.q, '{embroidery}' from (values ('ML1', 'M1', 'MV-POLO-M', 'M', 20), ('ML2', 'M1', 'MV-POLO-L', 'L', 10), ('ML3', 'M2', 'MV-POLO-S', 'S', 10)) v(wi, oid, sku, s, q) join flow.orders o on o.deco_order_id = v.oid;
select id as ml1 from flow.order_lines where deco_workflow_item_id = 'ML1' \gset
select id as ml2 from flow.order_lines where deco_workflow_item_id = 'ML2' \gset
select pg_temp.assert((select qty_sendable from flow.v_tp_sendable_lines where order_line_id = :'ml1') = 20 and not exists (select 1 from flow.v_tp_sendable_lines where sku = 'MV-POLO-S'), 'secured lines sendable, unsecured not');

-- 4. create, cancel a draft: units return, line sendable again, route cancelled, history kept
select flow.generate_bins('OUT', 'OUT', 2);
insert into r select 'c1', flow.create_outbound_movement(:'mp', jsonb_build_array(jsonb_build_object('order_line_id', :'ml1', 'qty', 20), jsonb_build_object('order_line_id', :'ml2', 'qty', 10)), 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'c1'), 'created: ' || (select j::text from r where k = 'c1'));
select j->>'movement_code' as mv1 from r where k = 'c1' \gset
select pg_temp.assert(not exists (select 1 from flow.v_tp_sendable_lines where order_line_id = :'ml1'), 'sent lines are no longer sendable');
select pg_temp.assert((select count(*) from flow.v_tp_items where movement_code = :'mv1') = 2 and (select count(*) from flow.v_tp_events where movement_code = :'mv1' and event = 'created') = 1, 'item and timeline views');
select pg_temp.assert(not (flow.mv_cancel_movement(:'mv1', 'tester', '')->>'ok')::bool, 'cancel needs a reason');
insert into r select 'x1', flow.mv_cancel_movement(:'mv1', 'tester', 'customer changed their mind');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'x1'), 'cancelled: ' || (select j::text from r where k = 'x1'));
select pg_temp.assert((select status from flow.tp_movements where movement_code = :'mv1') = 'cancelled' and exists (select 1 from flow.v_tp_sendable_lines where order_line_id = :'ml1' and qty_sendable = 20), 'cancelled movement frees the units to send again');
select pg_temp.assert((select coalesce(sum(qty), 0) from flow.stock_custody where movement_id = (select id from flow.tp_movements where movement_code = :'mv1')) = 0, 'nothing left in custody against the cancelled consignment');
select pg_temp.assert((select count(*) from flow.production_routes where route_status = 'cancelled') >= 1 and (select count(*) from flow.audit_log where action = 'movement_cancelled' and reason = 'customer changed their mind') = 1, 'route cancelled and cancellation audited');
select pg_temp.assert(not (flow.mv_cancel_movement(:'mv1', 'tester', 'again please')->>'ok')::bool, 'cannot cancel twice');

-- 5. cancel after picking works, after dispatch does not
insert into r select 'c2', flow.create_outbound_movement(:'mp', jsonb_build_array(jsonb_build_object('order_line_id', :'ml1', 'qty', 20)), 'tester');
select j->>'movement_code' as mv2 from r where k = 'c2' \gset
insert into r select 'pk', flow.tp_scan(:'mv2', 'picked', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'pk'), 'picked');
insert into r select 'x2', flow.mv_cancel_movement(:'mv2', 'tester', 'wrong garments picked');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'x2') and exists (select 1 from flow.v_tp_sendable_lines where order_line_id = :'ml1' and qty_sendable = 20), 'cancelling a picked consignment returns the units');
insert into r select 'c3', flow.create_outbound_movement(:'mp', jsonb_build_array(jsonb_build_object('order_line_id', :'ml1', 'qty', 20)), 'tester');
select j->>'movement_code' as mv3 from r where k = 'c3' \gset
select flow.tp_scan(:'mv3', 'picked', 'tester');
select flow.tp_scan(:'mv3', 'packed', 'tester');
select flow.tp_scan(:'mv3', 'dispatched', 'tester', '{"tracking_ref":"TRK1"}'::jsonb);
select pg_temp.assert(not (flow.mv_cancel_movement(:'mv3', 'tester', 'too late')->>'ok')::bool, 'a dispatched consignment cannot be cancelled');

-- 6. wrappers locked down
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_mv_cancel_movement(text,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_mv_upsert_producer(jsonb,text)', 'execute') and has_function_privilege('service_role', 'public.flow_mv_set_rate(uuid,text,text,numeric,numeric,numeric,text,text)', 'execute'), 'wrappers are service_role only');
\echo movement_test OK
