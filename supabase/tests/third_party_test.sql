-- Chain-of-custody lifecycle tests. Runs after all migrations (psql, ON_ERROR_STOP).
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.custody(p_line uuid, p_state text) returns int language sql as
$$ select coalesce(sum(qty), 0)::int from flow.stock_custody where order_line_id = p_line and location_state = p_state::flow.custody_state $$;

-- artwork gating is tested in artwork_test.sql; switch it off for these custody tests
update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'false') where key = 'artwork.options';
-- ---- fixtures ----
insert into flow.producers (code, name, address, contact_name, turnaround_days, can_direct_dispatch, capable_methods, special_instructions) values
  ('STW', 'Stitchworks Embroidery', '1 Mill Street, Leeds', 'Sam', 3, true, '{embroidery}', 'Left chest only, no backing show-through'),
  ('NDL', 'NoDirect Ltd', '2 Dock Road', 'Nia', 2, false, '{dtf}', null);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, priority, total_units) values
  ('T1','#T1','Northside FC','2026-11-20 12:00+00','ready_for_production',true,1,1,96),
  ('T2','#T2','Cityline','2026-11-21 12:00+00','ready_for_production',true,1,0,20),
  ('T3','#T3','No Stock Ltd','2026-11-22 12:00+00','awaiting_stock',false,9,0,10),
  ('T4','#T4','Damaged Co','2026-11-23 12:00+00','ready_for_production',true,1,0,30),
  ('T5','#T5','Direct Customer','2026-11-24 12:00+00','ready_for_production',true,1,0,12),
  ('T6','#T6','Late Ltd','2026-11-25 12:00+00','ready_for_production',true,1,0,15);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, garment_type, product_name, qty_required, decoration_methods)
select v.wi, o.id, v.sku, v.colour, v.size, 'Polos', 'Polo shirt', v.q, '{embroidery}'
from (values ('TL1','T1','POLO-BLK-M','Black','M',48), ('TL2','T1','POLO-NVY-M','Navy','M',48), ('TL3','T2','POLO-BLK-L','Black','L',20),
             ('TL4','T3','POLO-BLK-S','Black','S',10), ('TL5','T4','POLO-RED-M','Red','M',30), ('TL6','T5','POLO-GRN-M','Green','M',12),
             ('TL7','T6','POLO-WHT-M','White','M',15)) v(wi, oid, sku, colour, size, q)
join flow.orders o on o.deco_order_id = v.oid;
select flow.generate_bins('OUT', 'OUT', 3);

select id as stw from flow.producers where code = 'STW' \gset
select id as ndl from flow.producers where code = 'NDL' \gset
select id as tl1 from flow.order_lines where deco_workflow_item_id = 'TL1' \gset
select id as tl2 from flow.order_lines where deco_workflow_item_id = 'TL2' \gset
select id as tl3 from flow.order_lines where deco_workflow_item_id = 'TL3' \gset
select id as tl4 from flow.order_lines where deco_workflow_item_id = 'TL4' \gset
select id as tl5 from flow.order_lines where deco_workflow_item_id = 'TL5' \gset
select id as tl6 from flow.order_lines where deco_workflow_item_id = 'TL6' \gset
select id as tl7 from flow.order_lines where deco_workflow_item_id = 'TL7' \gset
select id as o1 from flow.orders where deco_order_id = 'T1' \gset

-- ---- guard rails: nothing is created when a request is invalid ----
create temp table r (k text primary key, j jsonb);
insert into r select 'nostock', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl4', 'qty', 5)), 'tester');
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like '%no secured stock%' from r where k='nostock'), 'orders without secured stock cannot be sent');
insert into r select 'over', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl1', 'qty', 60)), 'tester');
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like '%can still be sent%' from r where k='over'), 'cannot send more than the order needs');
insert into r select 'nodirect', flow.create_outbound_movement(:'ndl', jsonb_build_array(jsonb_build_object('order_line_id', :'tl1', 'qty', 5)), 'tester', 'direct_dispatch_to_customer');
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like '%not set up for direct dispatch%' from r where k='nodirect'), 'direct dispatch needs a capable producer');
select pg_temp.assert((select count(*) from flow.tp_movements) = 0 and (select count(*) from flow.stock_custody) = 0 and (select count(*) from flow.production_routes) = 0, 'failed requests leave no trace');

-- ---- 1. outbound consignment for two orders ----
insert into r select 'c1', flow.create_outbound_movement(:'stw', jsonb_build_array(
  jsonb_build_object('order_line_id', :'tl1', 'qty', 48), jsonb_build_object('order_line_id', :'tl2', 'qty', 48), jsonb_build_object('order_line_id', :'tl3', 'qty', 20)), 'warehouse1', null, 'courier', 'fragile logo');
select pg_temp.assert((select (j->>'ok')::bool and j->>'movement_code' ~ '^TP-[0-9]{4}-[0-9]{5}$' and jsonb_array_length(j->'pick_list') = 3 and j->>'staging_bin' = 'OUT-01' from r where k='c1'), 'movement created with code, 3-line pick list and staging bin');
select j->>'movement_code' as mv1 from r where k = 'c1' \gset
select id as mv1id from flow.tp_movements where movement_code = :'mv1' \gset
select pg_temp.assert(pg_temp.custody(:'tl1', 'allocated_to_order') = 48 and (select sum(qty) from flow.stock_custody) = 116, 'units reserved in custody for the consignment');
select pg_temp.assert((select count(*) from flow.production_routes where kind = 'third_party' and route_status = 'confirmed' and tp_status = 'ready_to_send') = 2, 'one confirmed route per order (2 orders, 3 lines)');
insert into r select 'dup', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl1', 'qty', 1)), 'tester');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='dup'), 'the same garments cannot be sent twice');

-- ---- 2. scans must happen in order ----
insert into r select 'early', flow.tp_scan(:'mv1', 'dispatched', 'warehouse1');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='early'), 'cannot dispatch before picked and packed');
select flow.tp_scan(:'mv1', 'picked', 'warehouse1');
select pg_temp.assert(pg_temp.custody(:'tl1', 'picked_for_producer') = 48, 'picked units tracked');
select flow.tp_scan(:'mv1', 'packed', 'warehouse1', '{"cartons": 2, "weight_kg": 14.5}');
insert into r select 'disp', flow.tp_scan(:'mv1', 'dispatched', 'warehouse1', '{"date": "2026-11-09", "tracking_ref": "DPD123", "carrier": "DPD"}');
select pg_temp.assert((select j->>'status' = 'dispatched' and j->>'expected_return_date' = '2026-11-13' from r where k='disp'), 'expected return = dispatch + 1 day transit + 3 day turnaround');
select pg_temp.assert(pg_temp.custody(:'tl1', 'in_transit_to_producer') = 48 and pg_temp.custody(:'tl1', 'picked_for_producer') = 0, 'stock is in transit, not at the producer yet');
select pg_temp.assert((select status = 'available' from flow.bins where bin_code = 'OUT-01'), 'staging bin released on dispatch');
select pg_temp.assert((select order_status = 'in_production' from flow.orders where deco_order_id = 'T1'), 'order shows as with the producer');
select pg_temp.assert(not exists (select 1 from flow.v_stock_position where qty_available < 0), 'warehouse available stock unaffected');

-- ---- 3. producer confirms receipt: turnaround clock starts ----
select flow.tp_scan(:'mv1', 'received_by_producer', 'producer', '{"at": "2026-11-10T09:00:00Z"}');
select pg_temp.assert((select expected_return_date = date '2026-11-13' and received_by_producer_at is not null from flow.tp_movements where id = :'mv1id'), 'clock restarted at receipt (10 Nov + 3 days)');
select pg_temp.assert(pg_temp.custody(:'tl1', 'at_producer') = 48 and pg_temp.custody(:'tl1', 'in_transit_to_producer') = 0, 'stock now confirmed at producer');
select pg_temp.assert((select sum(qty) from flow.v_producer_held_stock where producer_id = :'stw') = 116, 'producer-held stock visible separately');
select flow.tp_scan(:'mv1', 'production_started', 'producer');
select pg_temp.assert(pg_temp.custody(:'tl1', 'in_production_at_producer') = 48, 'in production at producer');
select flow.tp_scan(:'mv1', 'production_complete', 'producer');
select flow.tp_scan(:'mv1', 'return_dispatched', 'producer', '{"tracking_ref": "RET999"}');
select pg_temp.assert(pg_temp.custody(:'tl1', 'in_transit_back') = 48 and pg_temp.custody(:'tl2', 'in_transit_back') = 48, 'stock travelling back');

-- ---- 4. partial return: 90 of 96 ----
select id as it1 from flow.tp_movement_items where movement_id = :'mv1id' and order_line_id = :'tl1' \gset
select id as it2 from flow.tp_movement_items where movement_id = :'mv1id' and order_line_id = :'tl2' \gset
select id as it3 from flow.tp_movement_items where movement_id = :'mv1id' and order_line_id = :'tl3' \gset
insert into r select 'ret1', flow.tp_record_return(:'mv1', jsonb_build_array(
  jsonb_build_object('item_id', :'it1', 'qty_received', 48), jsonb_build_object('item_id', :'it2', 'qty_received', 42), jsonb_build_object('item_id', :'it3', 'qty_received', 20)), 'warehouse1');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'partially_returned' and not (j->>'complete_return')::bool from r where k='ret1'), 'partial return flagged, not closed');
select pg_temp.assert((select (s->>'outstanding')::int = 6 and (s->>'blocks_dispatch')::bool from r, jsonb_array_elements(r.j->'items') s where k='ret1' and s->>'order_ref' = '#T1' and s->>'colour' = 'Navy'), '6 navy polos outstanding and blocking dispatch');
select pg_temp.assert((select r.j->'recommendations' @> '[{"order_ref": "#T1"}]' from r where k='ret1') and (select case when current_date > date '2026-11-13' then j::text like '%Chase the producer for the 6 outstanding%' else j::text like '%Wait for the remaining 6%' end from r where k='ret1'), 'recommended action given (chase once the pinned return date of 13 Nov has passed, wait before)');
select pg_temp.assert((select qty = 6 and status = 'open' from flow.tp_discrepancies where item_id = :'it2' and disc_type = 'shortage'), 'shortage discrepancy opened for 6');
select pg_temp.assert(pg_temp.custody(:'tl2', 'returned_to_warehouse') = 42 and pg_temp.custody(:'tl2', 'in_transit_back') = 6, '42 back in warehouse, 6 still travelling');
select pg_temp.assert(not (flow.order_completion_check(:'o1')->>'can_complete')::bool and flow.order_completion_check(:'o1')->'blockers'::text is not null, 'partial return cannot complete the order');
select pg_temp.assert((select order_status <> 'ready_for_dispatch' and order_status <> 'dispatched' from flow.orders where deco_order_id = 'T1'), 'order not released while units are missing');
insert into r select 'chk_early', flow.tp_check_return(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it2', 'qty_ok', 43)), 'warehouse1');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='chk_early'), 'cannot check more units than have arrived');

-- ---- 5. remainder arrives; shortage closes itself ----
insert into r select 'ret2', flow.tp_record_return(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it2', 'qty_received', 6)), 'warehouse1');
select pg_temp.assert((select j->>'status' = 'returned' and (j->>'complete_return')::bool from r where k='ret2'), 'movement returned once everything is back');
select pg_temp.assert((select status = 'resolved' and resolution = 'received_later' from flow.tp_discrepancies where item_id = :'it2' and disc_type = 'shortage'), 'shortage auto-resolved');
select pg_temp.assert((select actual_return_date = current_date from flow.tp_movements where id = :'mv1id'), 'actual return date recorded');

-- ---- 6. goods-in check releases for dispatch ----
insert into r select 'chk', flow.tp_check_return(:'mv1', jsonb_build_array(
  jsonb_build_object('item_id', :'it1', 'qty_ok', 48), jsonb_build_object('item_id', :'it2', 'qty_ok', 48), jsonb_build_object('item_id', :'it3', 'qty_ok', 20)), 'warehouse1');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'checked' from r where k='chk'), 'movement checked');
select pg_temp.assert(pg_temp.custody(:'tl1', 'ready_for_dispatch') = 48 and (select order_status = 'ready_for_dispatch' from flow.orders where deco_order_id = 'T1'), 'order ready for dispatch');
select pg_temp.assert((flow.order_completion_check(:'o1')->>'can_dispatch_all')::bool and not (flow.order_completion_check(:'o1')->>'can_complete')::bool, 'dispatchable but not complete until it ships');
update flow.orders set shipped_at = now() where deco_order_id in ('T1','T2');
select flow.tp_reconcile_shipped();
select pg_temp.assert(pg_temp.custody(:'tl1', 'dispatched_to_customer') = 48 and (select status = 'closed' from flow.tp_movements where id = :'mv1id'), 'shipped goods leave custody; movement closed');
select pg_temp.assert((flow.order_completion_check(:'o1')->>'can_complete')::bool, 'order can complete once every unit is dispatched');

-- ---- 7. damaged and rejected goods create exceptions and block completion ----
insert into r select 'c2', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl5', 'qty', 30)), 'warehouse1');
select j->>'movement_code' as mv2 from r where k = 'c2' \gset
select id as mv2id from flow.tp_movements where movement_code = :'mv2' \gset
select flow.tp_scan(:'mv2', 'picked', 'w'); select flow.tp_scan(:'mv2', 'packed', 'w'); select flow.tp_scan(:'mv2', 'dispatched', 'w', '{"date":"2026-11-09"}');
select flow.tp_scan(:'mv2', 'received_by_producer', 'p'); select flow.tp_scan(:'mv2', 'production_complete', 'p'); select flow.tp_scan(:'mv2', 'return_dispatched', 'p');
select id as it5 from flow.tp_movement_items where movement_id = :'mv2id' \gset
select id as o4 from flow.orders where deco_order_id = 'T4' \gset
insert into r select 'ret3', flow.tp_record_return(:'mv2', jsonb_build_array(jsonb_build_object('item_id', :'it5', 'qty_received', 25, 'qty_damaged', 3, 'qty_rejected', 2, 'note', 'misplaced logo')), 'w');
select pg_temp.assert((select j->>'status' = 'exception' and (j->>'notify')::bool from r where k='ret3'), 'damaged/rejected return becomes an exception and notifies');
select pg_temp.assert((select count(*) = 2 from flow.tp_discrepancies where movement_id = :'mv2id' and status = 'open'), 'a discrepancy per problem');
select pg_temp.assert((select order_status = 'blocked' from flow.orders where deco_order_id = 'T4'), 'order blocked by the exception');
select pg_temp.assert(pg_temp.custody(:'tl5', 'lost_damaged_discrepancy') = 5 and pg_temp.custody(:'tl5', 'returned_to_warehouse') = 25, 'bad units quarantined, good units returned');
select id as d_dam from flow.tp_discrepancies where movement_id = :'mv2id' and disc_type = 'damaged' \gset
select id as d_rej from flow.tp_discrepancies where movement_id = :'mv2id' and disc_type = 'rejected' \gset
insert into r select 'res_noreason', flow.tp_resolve_discrepancy(:'d_dam', 'replaced', '', 'manager');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='res_noreason'), 'resolution needs a note');
select flow.tp_resolve_discrepancy(:'d_dam', 'replaced', 'producer will remake 3', 'manager');
select flow.tp_resolve_discrepancy(:'d_rej', 'written_off', 'customer accepts 2 short', 'manager');
select flow.tp_check_return(:'mv2', jsonb_build_array(jsonb_build_object('item_id', :'it5', 'qty_ok', 25)), 'w');
select pg_temp.assert(not (flow.order_completion_check(:'o4')->>'can_complete')::bool, 'cannot complete: 3 replacement units are still unaccounted for');
insert into r select 'repl', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl5', 'qty', 3)), 'w');
select pg_temp.assert((select (j->>'ok')::bool from r where k='repl'), 'replacement units can be sent (damaged units free up the requirement)');

-- ---- 8. direct dispatch: stock never comes back ----
insert into r select 'c3', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl6', 'qty', 12)), 'w', 'direct_dispatch_to_customer');
select j->>'movement_code' as mv3 from r where k = 'c3' \gset
select id as mv3id from flow.tp_movements where movement_code = :'mv3' \gset
select pg_temp.assert((select qty_expected_back = 0 from flow.tp_movement_items where movement_id = :'mv3id'), 'direct dispatch expects nothing back');
select flow.tp_scan(:'mv3', 'picked', 'w'); select flow.tp_scan(:'mv3', 'packed', 'w'); select flow.tp_scan(:'mv3', 'dispatched', 'w', '{"date":"2026-11-09"}');
select flow.tp_scan(:'mv3', 'received_by_producer', 'p'); select flow.tp_scan(:'mv3', 'production_complete', 'p');
insert into r select 'rt_direct', flow.tp_record_return(:'mv3', jsonb_build_array(jsonb_build_object('item_id', (select id from flow.tp_movement_items where movement_id = :'mv3id'), 'qty_received', 12)), 'w');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='rt_direct'), 'a direct-dispatch movement cannot be booked as a return');
insert into r select 'dd_notrack', flow.tp_direct_dispatch(:'mv3', '', 'DPD', null, 'p');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='dd_notrack'), 'tracking reference is mandatory');
insert into r select 'dd', flow.tp_direct_dispatch(:'mv3', 'TRK555', 'DPD', '{"signed_by": "J Smith", "delivered_at": "2026-11-12"}', 'p');
select pg_temp.assert((select (j->>'ok')::bool from r where k='dd'), 'direct dispatch recorded');
select pg_temp.assert(pg_temp.custody(:'tl6', 'dispatched_to_customer') = 12 and pg_temp.custody(:'tl6', 'returned_to_warehouse') = 0, 'stock went to the customer, never to the warehouse');
select pg_temp.assert((select order_status = 'dispatched' and shipped_at is null from flow.orders where deco_order_id = 'T5'), 'order dispatched via the producer (DecoNetwork still to be updated)');
select pg_temp.assert((select route.tp_status = 'completed' from flow.production_routes route join flow.orders o on o.id = route.order_id where o.deco_order_id = 'T5'), 'route completed with proof of delivery');

-- ---- 9. overdue alerts are raised once ----
insert into r select 'c4', flow.create_outbound_movement(:'stw', jsonb_build_array(jsonb_build_object('order_line_id', :'tl7', 'qty', 15)), 'w');
select j->>'movement_code' as mv4 from r where k = 'c4' \gset
select flow.tp_scan(:'mv4', 'picked', 'w'); select flow.tp_scan(:'mv4', 'packed', 'w'); select flow.tp_scan(:'mv4', 'dispatched', 'w', '{"date":"2026-10-01"}');
insert into r select 'od1', flow.tp_overdue_check();
insert into r select 'od2', flow.tp_overdue_check();
select pg_temp.assert((select (j->>'newly_flagged')::int = 1 from r where k='od1') and (select (j->>'newly_flagged')::int = 0 from r where k='od2'), 'overdue flagged once, not repeatedly');
select pg_temp.assert((select jsonb_array_length(j->'overdue') = 1 and (j->'overdue'->0->>'days_late')::int > 0 from r where k='od2'), 'overdue list still returned for notification');
select pg_temp.assert((select is_overdue and return_bucket = 'overdue' from flow.v_tp_movements_live where movement_code = :'mv4'), 'dashboard view shows the late return');
select pg_temp.assert((select count(*) = 1 from flow.v_tp_open_discrepancies where disc_type = 'late'), 'late return visible as an open exception');

-- ---- 10. scorecards, labels, immutability, permissions ----
select flow.refresh_producer_stats();
select pg_temp.assert((select open_jobs >= 1 and units_in_transit = 15 and late_returns >= 1 and on_time_rate is not null from flow.producer_stats where producer_id = :'stw'), 'producer scorecard computed');
insert into r select 'lab', flow.tp_label_payloads(:'mv1');
select pg_temp.assert((select j->>'qr_payload' like 'tp:TP-%' and j->'outbound_label'->>'producer' = 'Stitchworks Embroidery' and (j->'outbound_label'->>'total_units')::int = 116
  and jsonb_array_length(j->'job_sheet'->'lines') = 3 and jsonb_array_length(j->'return_checklist'->'steps') > 0 from r where k='lab'), 'label, job sheet and return checklist payloads built');
select pg_temp.assert((select j->'outbound_label'->>'decoration' = 'EMBROIDERY' and j->'outbound_label'->>'special_instructions' like '%Left chest only%' from r where k='lab'), 'decoration and producer instructions on the label');
do $$ begin begin update flow.custody_events set qty = 1 where id = (select min(id) from flow.custody_events); raise exception 'ASSERT FAILED: custody ledger was editable';
  exception when raise_exception then if sqlerrm like 'ASSERT%' then raise; end if; end; end $$;
do $$ begin begin update flow.tp_movement_events set note = 'x'; raise exception 'ASSERT FAILED: event log was editable';
  exception when raise_exception then if sqlerrm like 'ASSERT%' then raise; end if; end; end $$;
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_tp_scan(text,text,text,jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.flow_create_outbound_movement(uuid,jsonb,text,text,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'flow.custody_move(uuid,flow.custody_state,uuid,flow.custody_state,uuid,int,uuid,text,text)', 'execute'), 'browser roles cannot run movement functions');
insert into auth.users values ('00000000-0000-0000-0000-0000000000cc') on conflict do nothing;
insert into flow.user_roles values ('00000000-0000-0000-0000-0000000000cc', 'viewer') on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000dd', false);
select pg_temp.assert((select count(*) from flow.tp_movements) = 0 and (select count(*) from flow.producers) = 0, 'non-members see no third-party data');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000cc', false);
select pg_temp.assert((select count(*) from flow.tp_movements) > 0 and (select count(*) from flow.v_tp_orders) > 0, 'members can read movements and orders with producers');
select pg_temp.assert(not exists (select 1 from flow.tp_movements where false), 'ok');
do $$ begin begin insert into flow.producers (code, name) values ('HACK', 'x'); raise exception 'ASSERT FAILED: viewer created a producer';
  exception when insufficient_privilege or others then if sqlerrm like 'ASSERT%' then raise; end if; end; end $$;
reset role;
\echo THIRD PARTY TESTS PASSED
