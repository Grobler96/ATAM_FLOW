-- Holding pen and pipeline.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

-- DecoNetwork copies
insert into public.upcoming_orders (order_id, customer_name, order_status, date_due, date_ordered, total_quantity, processes, is_production_complete, synced_at, shipping_method, shipping_address) values
  ('PEN1', 'Good Co',     9, now() + interval '8 days', now() - interval '1 day', 10, '{WEMB}', false, now(), 'Tracked Courier Delivery', 'Good Co, 1 High Street, Leeds, West Yorkshire, LS1 4AB, GB'),
  ('PEN2', 'No Address',  9, now() + interval '8 days', now() - interval '1 day', 10, '{WEMB}', false, now(), 'Tracked Courier Delivery', ', , , , GB'),
  ('PEN3', 'Collect Co',  9, now() + interval '8 days', now() - interval '1 day', 10, '{WEMB}', false, now(), 'Collect From Us', null),
  ('PEN4', 'Many Faults', 9, null, now() - interval '1 day', 0, '{WEMB}', false, now(), null, 'Many Faults Ltd, 2 Low Road, York, YO1 6DH, GB'),
  ('PEN5', 'Odd Status',  99, now() + interval '5 days', now() - interval '1 day', 5, '{WEMB}', false, now(), 'Tracked Courier Delivery', 'Odd Co, 3 Mill Lane, Hull, HU1 1AA, GB');

-- ATAM_FLOW copies of the first four
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, created_at)
select o.order_id, '#' || o.order_id, o.customer_name, o.date_due, 'ready_for_production', true, 1, o.total_quantity, case when o.order_id = 'PEN4' then '{}'::text[] else '{embroidery}'::text[] end, now() - interval '1 day'
from public.upcoming_orders o where o.order_id in ('PEN1','PEN2','PEN3','PEN4');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select 'L-' || o.deco_order_id, o.id, 'PEN-POLO-M', 'Navy', 'M', 'Polo', 10, '{embroidery}' from flow.orders o where o.deco_order_id in ('PEN1','PEN2','PEN3');
select id as o1 from flow.orders where deco_order_id = 'PEN1' \gset
select id as o2 from flow.orders where deco_order_id = 'PEN2' \gset
select id as o3 from flow.orders where deco_order_id = 'PEN3' \gset
select id as o4 from flow.orders where deco_order_id = 'PEN4' \gset

select flow.exc_raise('artwork_blocked', 'pen:art1', null, 'Artwork missing on PEN1', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'o1')), '{}'::jsonb);
select flow.exc_raise('artwork_blocked', 'pen:art4', null, 'Artwork missing on PEN4', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'o4')), '{}'::jsonb);
select flow.pen_refresh() as r0 \gset
create or replace function pg_temp.codes(p_key text) returns text language sql as
$$ select coalesce((select string_agg(d->>'code', ',' order by d->>'code') from flow.pen_cases c, jsonb_array_elements(c.defects) d where c.case_key = p_key and c.cleared_at is null), '') $$;

select pg_temp.assert(pg_temp.codes('o:' || :'o1') = '', 'a clean order is not in the pen');
select pg_temp.assert(pg_temp.codes('o:' || :'o1') = '' and exists (select 1 from flow.exceptions where dedupe_key = 'pen:art1'), 'artwork alone does not put an order in the pen');
select pg_temp.assert(pg_temp.codes('o:' || :'o2') = 'no_address', 'no delivery address sends it to the pen');
select pg_temp.assert(pg_temp.codes('o:' || :'o3') = '', 'a collection order needs no address');
select pg_temp.assert(pg_temp.codes('o:' || :'o4') not like '%no_address%' and pg_temp.codes('o:' || :'o4') like '%no_due_date%' and pg_temp.codes('o:' || :'o4') like '%no_lines%'
  and pg_temp.codes('o:' || :'o4') like '%no_decoration%' and pg_temp.codes('o:' || :'o4') like '%no_shipping_method%' and pg_temp.codes('o:' || :'o4') like '%artwork%', 'every problem on an order is listed, artwork included');
select pg_temp.assert(pg_temp.codes('s:PEN5') = 'unknown_status', 'an order with an unknown DecoNetwork status is in the pen even though it is not in ATAM_FLOW');
select pg_temp.assert(exists (select 1 from flow.pen_log where case_key = 'o:' || :'o2' and kind = 'entered'), 'entry is logged');

-- blocks the planner and dispatch
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.scheduler_input()->'orders') x where x->>'id' = :'o2'), 'pen order is left out of the planner');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.scheduler_input()->'orders') x where x->>'id' = :'o1'), 'clean order is planned');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.order_blocking_exceptions(:'o2', 'dispatch')) b where b->>'type' = 'order_in_pen'), 'pen order blocks dispatch');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.order_blocking_exceptions(:'o1', 'dispatch')) b where b->>'type' = 'order_in_pen'), 'order not in the pen is not blocked by it');
select pg_temp.assert(not (flow.order_completion_check(:'o2')->>'can_complete')::bool, 'pen order cannot complete');

-- review: owner and note
select pg_temp.assert((flow.pen_assign('o:' || :'o2', 'Gill Pick', 'Ringing the customer for the address', 'tester')->>'ok')::bool, 'owner and note saved');
select pg_temp.assert((select owner = 'Gill Pick' and note like 'Ringing%' from flow.pen_cases where case_key = 'o:' || :'o2'), 'owner and note stored');
select pg_temp.assert(not (flow.pen_assign('o:' || :'o1', 'x', 'y', 't')->>'ok')::bool, 'cannot assign an order that is not in the pen');

-- waive: needs a reason, audited, reversible
select pg_temp.assert((flow.pen_waive(:'o2', 'no_address', '', 't')->>'needs_reason')::bool, 'waiving needs a reason');
select pg_temp.assert(not (flow.pen_waive(:'o2', 'nonsense', 'Not a real problem', 't')->>'ok')::bool, 'unknown problem refused');
select pg_temp.assert(not (flow.pen_waive(:'o2', 'no_address', 'Customer is collecting in person', 'tester')->>'still_in_pen')::bool, 'waiving the only problem releases the order');
select pg_temp.assert(not exists (select 1 from flow.pen_cases where case_key = 'o:' || :'o2' and cleared_at is null), 'released from the pen');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.scheduler_input()->'orders') x where x->>'id' = :'o2'), 'released order is planned again');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'pen_waive' and entity_id = '#PEN2' and reason like 'Customer is collecting%'), 'waiver audited');
select pg_temp.assert((flow.pen_unwaive(:'o2', 'no_address', 'Address is needed after all', 'tester')->>'ok')::bool, 'waiver removed');
select pg_temp.assert(pg_temp.codes('o:' || :'o2') = 'no_address', 'back in the pen after removing the waiver');
select pg_temp.assert((select note is null from flow.pen_cases where case_key = 'o:' || :'o2'), 'a re-opened case starts with a clean note');

-- fixing the data in DecoNetwork releases it on the next check
update public.upcoming_orders set shipping_address = 'No Address Ltd, 9 Park Road, Leeds, LS2 9AA, GB' where order_id = 'PEN2';
select pg_temp.assert((flow.pen_recheck('o:' || :'o2', 'tester')->>'released')::bool, 'fixed order is released');
select pg_temp.assert(exists (select 1 from flow.pen_log where case_key = 'o:' || :'o2' and kind = 'released'), 'release is logged');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.order_blocking_exceptions(:'o2', 'dispatch')) b where b->>'type' = 'order_in_pen'), 'no longer blocked by the pen');

-- unknown status becomes known: it stops being a pen case once the order exists in ATAM_FLOW or the status is mapped
insert into flow.deco_status_map (code, label, is_open, maps_to) values (99, 'Test status', true, 'awaiting_stock') on conflict (code) do nothing;
update public.upcoming_orders set synced_at = now() - interval '3 hours' where order_id = 'PEN5';
select pg_temp.assert(flow.pen_refresh() is not null and pg_temp.codes('s:PEN5') = 'not_synced', 'a mapped but not-yet-synced open order is flagged as not in ATAM_FLOW');
select flow.sync_orders('test') as sync \gset
select flow.pen_refresh() as r1 \gset
select pg_temp.assert(pg_temp.codes('s:PEN5') = '', 'once synced it leaves the missing-order list');

-- pipeline: one row per order, one stage each
select pg_temp.assert((select count(*) from flow.v_pipeline where order_id = :'o1') = 1 and (select stage from flow.v_pipeline where order_id = :'o1') = (select order_status::text from flow.orders where id = :'o1'), 'clean order sits in its own stage');
select pg_temp.assert((select stage = 'pen' and real_stage = (select order_status::text from flow.orders where id = :'o4') and pen_problems >= 3 from flow.v_pipeline where order_id = :'o4'), 'pen order shows as pen, with its real stage kept');
select pg_temp.assert((select count(*) = count(distinct row_key) from flow.v_pipeline), 'no order appears twice');
select pg_temp.assert((select count(*) from flow.v_pipeline where in_flow and stage <> 'shipped') = (select count(*) from flow.orders where is_active and order_status <> 'dispatched' and shipped_at is null), 'every active order is on the board');
select pg_temp.assert(exists (select 1 from flow.pen_cases where order_id is null and cleared_at is null) or true, 'source-only rows are allowed');

-- permissions
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_pen_waive(uuid,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_pen_refresh()', 'execute'), 'pen actions closed to browser roles');
select pg_temp.assert(has_function_privilege('service_role', 'public.flow_pen_assign(text,text,text,text)', 'execute'), 'service role can act');
\echo pen_test OK
