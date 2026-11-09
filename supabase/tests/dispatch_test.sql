-- Dispatch queue and courier labels: readiness, packing, printing, tracking, scan-to-hand-over, cancelling, and who can see what.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

-- DecoNetwork copies (delivery address and method) and our orders: D1 ready, D2 collection, D3 not ready, D4 ready but blocked by an issue
insert into public.upcoming_orders (order_id, customer_name, order_status, date_due, date_ordered, total_quantity, processes, is_production_complete, synced_at, shipping_method, shipping_address, customer_po_number) values
  ('DSP1', 'Ship Co', 2, now() + interval '3 days', now() - interval '5 days', 10, '{WEMB}', true, now(), 'DPD Next Working Day Delivery', E'Sam Ship\nShip Co, 1 High Street\nLeeds, West Yorkshire, LS1 4AB, GB', 'PO-77'),
  ('DSP2', 'Collect Co', 2, now() + interval '3 days', now() - interval '5 days', 5, '{WEMB}', true, now(), 'Collect From Us', 'Collect Co, 2 Low Road, York, YO1 6DH, GB', null),
  ('DSP3', 'Early Co', 1, now() + interval '9 days', now() - interval '5 days', 5, '{WEMB}', false, now(), 'Tracked Courier Delivery', 'Early Co, 3 Mill Lane, Hull, HU1 1AA, GB', null),
  ('DSP4', 'Blocked Co', 2, now() + interval '3 days', now() - interval '5 days', 5, '{WEMB}', true, now(), 'Tracked Courier Delivery', 'Blocked Co, 4 Dock Road, Selby, YO8 9TP, GB', null);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, shipping_method, created_at)
select u.order_id, '#' || u.order_id, u.customer_name, u.date_due, case u.order_id when 'DSP3' then 'in_production' else 'ready_for_dispatch' end::flow.order_status, true, u.order_status, u.total_quantity, '{embroidery}'::text[], u.shipping_method, now() - interval '4 days'
from public.upcoming_orders u where u.order_id in ('DSP1','DSP2','DSP3','DSP4');
select id as d1 from flow.orders where order_ref = '#DSP1' \gset
select id as d2 from flow.orders where order_ref = '#DSP2' \gset
select id as d3 from flow.orders where order_ref = '#DSP3' \gset
select id as d4 from flow.orders where order_ref = '#DSP4' \gset
select flow.exc_raise('artwork_blocked', 'dsp:block4', null, 'Artwork changed after approval on DSP4', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'d4')), '{"blocks":["dispatch"]}'::jsonb);

-- 1. readiness in plain words
select pg_temp.assert((flow.dispatch_state(:'d1')->>'can_pack')::bool and (flow.dispatch_state(:'d1')->>'ship_to') like '%Leeds%' and flow.dispatch_state(:'d1')->>'customer_po' = 'PO-77', 'a ready order says so and carries its address and PO');
select pg_temp.assert((flow.dispatch_state(:'d2')->>'is_collection')::bool, 'a collection is recognised');
select pg_temp.assert(not (flow.dispatch_state(:'d3')->>'can_pack')::bool and flow.dispatch_state(:'d3')->'blockers'->>0 like '%in production%not ready for dispatch%', 'an order still in production says why it cannot go');
select pg_temp.assert(not (flow.dispatch_state(:'d4')->>'can_pack')::bool and flow.dispatch_state(:'d4')->'blockers'->>0 like '%Artwork changed%', 'an open blocking issue shows as the reason');
select pg_temp.assert(exists (select 1 from public.ui_dispatch_queue where order_ref = '#DSP1' and stage = 'ready') and exists (select 1 from public.ui_dispatch_queue where order_ref = '#DSP4' and stage = 'blocked')
  and not exists (select 1 from public.ui_dispatch_queue where order_ref = '#DSP3'), 'the queue lists ready and blocked orders but not one that is still in production');

-- 2. packing
insert into r select 'p3', flow.dispatch_pack(:'d3', 1, null, null, null, null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p3') and (select (j->>'needs_override')::bool from r where k = 'p3'), 'packing an order that is not ready is refused and says an override is possible');
insert into r select 'p3o', flow.dispatch_pack(:'d3', 1, null, null, null, null, 'ok', 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p3o'), 'a one-word override is not enough');
insert into r select 'bad', flow.dispatch_pack(:'d1', 0, null, null, null, null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'bad'), 'at least one parcel');
insert into r select 'p1', flow.dispatch_pack(:'d1', 2, array[3.5, 1.2], null, 'Next day', 'Fragile', null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and jsonb_array_length(j->'labels') = 2 and j->'labels'->>0 = 'DSP-DSP1-1of2' from r where k = 'p1'), 'two parcels, numbered labels');
select pg_temp.assert((select count(*) from flow.dispatch_parcels where order_id = :'d1' and status = 'packed' and carrier = 'DPD Next Working Day Delivery' and service = 'Next day') = 2, 'carrier defaults to the order''s shipping method');
select pg_temp.assert((select weight_kg from flow.dispatch_parcels where label_code = 'DSP-DSP1-2of2') = 1.2, 'weights are kept per parcel');
insert into r select 'p1b', flow.dispatch_pack(:'d1', 1, null, null, null, null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p1b'), 'an order cannot be packed twice');
insert into r select 'p2', flow.dispatch_pack(:'d2', 1, null, null, null, null, null, 'tester');
select pg_temp.assert((select j->>'kind' = 'collection' from r where k = 'p2') and (select carrier = 'Customer collection' and kind = 'collection' from flow.dispatch_parcels where order_id = :'d2'), 'a collection gets a collection label');
select pg_temp.assert(exists (select 1 from public.ui_dispatch_queue where order_ref = '#DSP1' and stage = 'packed' and parcels = 2 and parcels_printed = 0), 'the queue shows it as packed, not yet printed');
-- override on a blocked order
insert into r select 'p4', flow.dispatch_pack(:'d4', 1, null, null, null, null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p4') and (select j->'blockers'->>0 like '%Artwork changed%' from r where k = 'p4'), 'a blocked order is refused with its reasons');
insert into r select 'p4o', flow.dispatch_pack(:'d4', 1, null, null, null, null, 'Customer approved the new artwork by phone', 'manager');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'p4o'), 'a manager can override with a written reason');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'dispatch_pack_override' and entity_id = '#DSP4' and reason like 'Customer approved%'), 'the override and its reason are audited');

-- 3. printing
insert into r select 'pr1', flow.dispatch_printed(:'d1', null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'reprint')::bool from r where k = 'pr1'), 'first print recorded');
insert into r select 'pr2', flow.dispatch_printed(:'d1', null, 'tester');
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'pr2'), 'a reprint needs a reason');
insert into r select 'pr3', flow.dispatch_printed(:'d1', 'Label smudged on the printer', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'reprint')::bool from r where k = 'pr3') and (select min(print_count) from flow.dispatch_parcels where order_id = :'d1') = 2, 'reprint with a reason');
select pg_temp.assert(not (flow.dispatch_printed(:'d3', null, 'tester')->>'ok')::bool, 'nothing to print before packing');

-- 4. tracking
select pg_temp.assert(not (flow.dispatch_set_tracking(:'d1', 'DPD', 'x', null, 'tester')->>'ok')::bool, 'a real tracking reference is required');
select pg_temp.assert((flow.dispatch_set_tracking(:'d1', 'DPD', '15501234567890', null, 'tester')->>'parcels')::int = 2, 'tracking goes on every parcel by default');
select (flow.dispatch_set_tracking(:'d1', null, '15509999999999', 2, 'tester')->>'parcels')::int as one \gset
select pg_temp.assert(:'one'::int = 1 and (select tracking_ref from flow.dispatch_parcels where label_code = 'DSP-DSP1-2of2') = '15509999999999' and (select tracking_ref from flow.dispatch_parcels where label_code = 'DSP-DSP1-1of2') = '15501234567890', 'or on one parcel');

-- 5. hand over by scanning the label
insert into r select 'h1', flow.dispatch_handover('dsp-dsp1-1of2', null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'all_handed')::bool and (j->>'parcels_left')::int = 1 and j->>'order_ref' = '#DSP1' from r where k = 'h1'), 'first parcel handed over (label case does not matter); one left');
insert into r select 'h1b', flow.dispatch_handover('DSP-DSP1-1of2', null, 'tester');
select pg_temp.assert((select (j->>'already')::bool from r where k = 'h1b'), 'scanning it again is harmless');
select pg_temp.assert(not (flow.dispatch_cancel(:'d1', 'Changed my mind about it', 'tester')->>'ok')::bool, 'cannot cancel once something has left');
insert into r select 'h2', flow.dispatch_handover('DSP-DSP1-2of2', null, 'tester');
select pg_temp.assert((select (j->>'all_handed')::bool and not (j->>'tracking_missing')::bool from r where k = 'h2') and exists (select 1 from public.ui_dispatch_queue where order_ref = '#DSP1' and stage = 'with_courier' and tracking like '%15501234567890%'), 'last parcel: with the courier, tracking shown');
select pg_temp.assert(not (flow.dispatch_handover('NOPE-1', null, 'tester')->>'ok')::bool, 'an unknown label is refused');
-- hand-over re-checks the order: a new blocking issue appears after D2 was packed
select flow.exc_raise('artwork_blocked', 'dsp:block2', null, 'Customer changed the order after packing', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'d2')), '{"blocks":["dispatch"]}'::jsonb);
insert into r select 'h3', flow.dispatch_handover((select label_code from flow.dispatch_parcels where order_id = :'d2'), null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'h3') and (select (j->>'needs_override')::bool from r where k = 'h3'), 'handing over an order that became blocked is refused');
insert into r select 'h3o', flow.dispatch_handover((select label_code from flow.dispatch_parcels where order_id = :'d2'), 'Customer confirmed the change is fine', 'manager');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'h3o'), 'a manager can hand it over with a written reason');

-- 6. cancelling, and a cancelled label is dead
select pg_temp.assert(not (flow.dispatch_cancel(:'d4', 'no', 'tester')->>'ok')::bool, 'cancelling needs a reason');
select pg_temp.assert((flow.dispatch_cancel(:'d4', 'Wrong box used, repacking', 'tester')->>'cancelled')::int = 1, 'packing can be cancelled before anything leaves');
select pg_temp.assert(not (flow.dispatch_handover('DSP-DSP4-1of1', 'Customer approved the new artwork', 'tester')->>'ok')::bool and flow.dispatch_handover('DSP-DSP4-1of1', 'Customer approved the new artwork', 'tester')->>'error' like '%cancelled%', 'a cancelled label cannot be handed over');
insert into r select 'p4b', flow.dispatch_pack(:'d4', 1, null, null, null, null, 'Customer approved the new artwork by phone', 'manager');
select pg_temp.assert((select (j->>'ok')::bool and j->'labels'->>0 like 'DSP-DSP4-1of1-%' from r where k = 'p4b'), 'repacking gives new, different label codes');

-- 7. who can see what
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000e1', 'staff@dispatch.test', now()), ('00000000-0000-0000-0000-0000000000e2', 'outsider@dispatch.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000e1', 'warehouse') on conflict (user_id) do update set role = 'warehouse';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_dispatch_queue where order_ref like '#DSP%') >= 3 and (select count(*) from public.ui_dispatch_parcels where order_ref like '#DSP%') >= 4, 'a team member sees the queue and the parcels');
select pg_temp.assert(flow.dispatch_state(:'d1') is not null, 'a team member can read an order''s dispatch state');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_dispatch_queue) = 0 and (select count(*) from public.ui_dispatch_parcels) = 0, 'a logged-in outsider (for example a decorator) sees nothing');
select pg_temp.assert(flow.dispatch_state(:'d1') is null and flow.dispatch_address(:'d1') is null, 'and the helpers return nothing for them');
select pg_temp.assert(pg_temp.try(format('select flow.dispatch_pack(%L::uuid, 1, null, null, null, null, null, ''x'')', :'d1')) like '%permission denied%', 'nobody in the browser can pack directly');
select pg_temp.assert(pg_temp.try('select public.flow_dispatch_handover(''DSP-DSP1-1of2'', null, ''x'')') like '%permission denied%', 'nor hand over directly');
reset role;
select pg_temp.assert(has_function_privilege('service_role', 'public.flow_dispatch_pack(uuid,int,numeric[],text,text,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_dispatch_handover(text,text,text)', 'execute') and not has_function_privilege('anon', 'flow.dispatch_state(uuid)', 'execute'), 'only the service role can act; anonymous visitors can call nothing');
\echo dispatch_test OK
