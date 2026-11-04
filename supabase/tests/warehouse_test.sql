-- Warehouse flows: bins, assignment rules + overrides, release, labels, print audit, search.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, order_value, decoration_methods) values
  ('H1', '#H1', 'Hall Customer', '2026-12-01 12:00+00', 'ready_for_production', true, 1, 12, 100, '{embroidery}'),
  ('H2', '#H2', 'Second Customer', '2026-12-02 12:00+00', 'stock_allocated', true, 1, 30, 100, '{dtf}'),
  ('H3', '#H3', 'Third Customer', '2026-12-03 12:00+00', 'awaiting_stock', false, 1, 5, 100, '{dtf}');
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, product_name, colour, size, qty_required, decoration_methods)
select v.wi, 'HDL', o.id, v.sku, 'Polo', 'Navy', v.s, v.q, '{embroidery}' from (values ('HW1','H-POLO-M','M',8), ('HW2','H-POLO-L','L',4)) v(wi, sku, s, q) join flow.orders o on o.deco_order_id = 'H1';
select id as o1 from flow.orders where deco_order_id = 'H1' \gset
select id as o2 from flow.orders where deco_order_id = 'H2' \gset
select id as o3 from flow.orders where deco_order_id = 'H3' \gset
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand) values ('H-POLO-M', 'Polo', 'Navy', 'M', 10);

-- 1. create bins: idempotent numbering continues, bad input rejected
create temp table r (k text primary key, j jsonb);
insert into r select 'c1', flow.wh_create_bins('STG', 'WH', 3, 'bin_bay', 20, 'tester');
insert into r select 'c2', flow.wh_create_bins('STG', 'WH', 2, 'bin_bay', 20, 'tester');
select pg_temp.assert((select (j->>'created')::int = 3 and j->>'first_code' = 'WH-01' from r where k = 'c1'), 'first batch WH-01..03');
select pg_temp.assert((select j->>'first_code' = 'WH-04' from r where k = 'c2') and (select count(*) from flow.bins where bin_code like 'WH-%') = 5, 'second batch continues at WH-04');
select pg_temp.assert(not (flow.wh_create_bins('NOPE', 'ZZ', 1)->>'ok')::bool and not (flow.wh_create_bins('STG', 'bad prefix!', 1)->>'ok')::bool and not (flow.wh_create_bins('STG', 'ZZ', 0)->>'ok')::bool, 'bad zone, prefix and count rejected');

-- 2. suggestion picks a free STG bin with room and explains why
-- other suites leave unlimited STG bins around; retire them so these tests see only the WH bins
update flow.bins set is_active = false where bin_code not like 'WH-%';
insert into r select 's1', flow.wh_suggest_bin(:'o1', null);
select pg_temp.assert((select j->'suggestion'->>'bin_code' = 'WH-01' and (j->'suggestion'->>'why') like '%tightest%' from r where k = 's1'), 'suggests WH-01: ' || (select j::text from r where k = 's1'));
insert into r select 's2', flow.wh_suggest_bin(:'o2', 50);
select pg_temp.assert((select j->'suggestion' = 'null'::jsonb and j->>'message' like 'No active bin%' from r where k = 's2'), 'no bin fits 50 units: ' || (select j::text from r where k = 's2'));

-- 3. assign, then the suggestion for another order skips the occupied bin (one order per bin)
insert into r select 'a1', flow.wh_assign_bin(:'o1', 'wh-01', 12, 'tester', false, null, jsonb_build_array(jsonb_build_object('order_line_id', (select id from flow.order_lines where sku = 'H-POLO-M'), 'qty', 8)));
select pg_temp.assert((select (j->>'ok')::bool and (j->>'units_in_bin')::int = 12 from r where k = 'a1'), 'assigned: ' || (select j::text from r where k = 'a1'));
select pg_temp.assert((select status from flow.bins where bin_code = 'WH-01') = 'allocated', 'bin allocated');
select pg_temp.assert((select j->'suggestion'->>'bin_code' from (select flow.wh_suggest_bin(:'o3', 5) j) x) = 'WH-02', 'next order goes to WH-02');
select pg_temp.assert((select count(*) from flow.bin_contents) = 1, 'bin contents recorded');

-- 4. rule breaks need an override, then a reason
insert into r select 'a2', flow.wh_assign_bin(:'o3', 'WH-01', 5, 'tester', false, null, null);
select pg_temp.assert((select (j->>'needs_override')::bool and not (j->>'ok')::bool from r where k = 'a2'), 'second order blocked without override');
insert into r select 'a3', flow.wh_assign_bin(:'o3', 'WH-01', 5, 'tester', true, '', null);
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'a3'), 'override without reason refused');
insert into r select 'a4', flow.wh_assign_bin(:'o3', 'WH-01', 5, 'tester', true, 'Overflow while WH-02 is cleaned', null);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'overridden')::bool from r where k = 'a4'), 'override with reason accepted');
select pg_temp.assert((select count(*) from flow.audit_log where action = 'bin_assigned_override' and reason like 'Overflow%') = 1, 'override audited with reason');
-- capacity override
insert into r select 'a5', flow.wh_assign_bin(:'o2', 'WH-02', 30, 'tester', false, null, null);
select pg_temp.assert((select (j->>'needs_override')::bool and (j->>'error') like '%capacity%' from r where k = 'a5'), 'capacity breach flagged: ' || (select j::text from r where k = 'a5'));
select pg_temp.assert(not (flow.wh_assign_bin(:'o2', 'NOPE-1', 5)->>'ok')::bool and not (flow.wh_assign_bin(:'o2', 'WH-02', 0)->>'ok')::bool, 'unknown bin and zero units rejected');

-- 5. releasing needs a reason, keeps history, frees the bin
select pg_temp.assert((flow.wh_release_bin('WH-01', :'o3', 'tester', '')->>'needs_reason')::bool, 'release needs reason');
select flow.wh_release_bin('WH-01', :'o3', 'tester', 'moved to WH-03');
select pg_temp.assert((select units_in_bin from flow.v_bins_live where bin_code = 'WH-01') = 12 and (select count(*) from flow.bin_assignments where released_at is not null) = 1, 'only o3 released, history kept');
select pg_temp.assert(exists (select 1 from flow.v_orders_to_bin where order_ref = '#H2') and not exists (select 1 from flow.v_orders_to_bin where order_ref in ('#H1', '#H3')), 'orders to bin lists unbinned H2 only');

-- 6. move order between bins
insert into r select 'm1', flow.wh_move_order(:'o1', 'WH-01', 'WH-02', 'tester', false, 'consolidating');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'm1') and (select units_in_bin from flow.v_bins_live where bin_code = 'WH-02') = 12 and (select units_in_bin from flow.v_bins_live where bin_code = 'WH-01') = 0, 'moved');
select pg_temp.assert((select status from flow.bins where bin_code = 'WH-01') = 'available', 'source bin free again');

-- 7. status changes
select pg_temp.assert(not (flow.wh_set_bin_status('WH-02', 'available', 'tester', 'x clean')->>'ok')::bool, 'cannot free an occupied bin');
insert into r select 'st1', flow.wh_set_bin_status('WH-03', 'needs_emptying', 'tester', 'spill');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'st1') and (select status from flow.bins where bin_code = 'WH-03') = 'needs_emptying', 'flag for emptying');
select pg_temp.assert((flow.wh_assign_bin(:'o2', 'WH-03', 3, 'tester')->>'needs_override')::bool, 'cannot assign a bin that needs emptying');
insert into r select 'st2', flow.wh_set_bin_status('WH-05', 'retired', 'tester', 'broken');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'st2') and not (select is_active from flow.bins where bin_code = 'WH-05'), 'retire an empty bin');
insert into r select 'st3', flow.wh_set_stock_location('H-POLO-M', 'Shelf A2', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'st3') and (select storage_location from flow.stock_items where sku = 'H-POLO-M') = 'Shelf A2', 'stock location saved');

-- 8. labels: create, idempotent, change → reprint needed
insert into r select 'l1', flow.wh_generate_order_labels(:'o1', 'tester', false);
select pg_temp.assert((select jsonb_array_length(j->'labels') = 3 from r where k = 'l1'), 'order + pick + bin label: ' || (select j::text from r where k = 'l1'));
select pg_temp.assert((select label_status from flow.orders where id = :'o1') = 'pending', 'order marked label pending');
insert into r select 'l2', flow.wh_generate_order_labels(:'o1', 'tester', false);
select pg_temp.assert((select bool_and(e->>'state' = 'unchanged') from r, jsonb_array_elements(j->'labels') e where k = 'l2'), 'regenerating is idempotent');
select pg_temp.assert((select count(*) from flow.labels) = 3, 'still three labels');
select pg_temp.assert((flow.wh_generate_label('stock', 'H-POLO-M')->>'state') = 'created' and (flow.wh_generate_label('bin', 'WH-04')->>'state') = 'created', 'stock and bin labels');
select pg_temp.assert(not (flow.wh_generate_label('order', '#NOPE')->>'ok')::bool and not (flow.wh_generate_label('weird', 'x')->>'ok')::bool, 'unknown targets rejected');
select pg_temp.assert((select qr_payload from flow.labels where label_type = 'order') = 'order:#H1', 'order QR payload');
select pg_temp.assert((select payload->'bins'->0->>'bin_code' from flow.labels where label_type = 'pick') = 'WH-02' and (select jsonb_array_length(payload->'lines') from flow.labels where label_type = 'pick') = 2, 'pick list shows bin and lines');

-- 9. print: first print needs no reason; reprint does
select label_code as ol from flow.labels where label_type = 'order' \gset
insert into r select 'p1', flow.wh_mark_printed(array[:'ol'], 'tester', null, 'thermal', 1);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'printed')::int = 1 and (j->>'reprints')::int = 0 from r where k = 'p1'), 'first print ok');
select pg_temp.assert((flow.wh_mark_printed(array[:'ol'], 'tester', null, 'A4', 1)->>'needs_reason')::bool, 'reprint without reason refused');
insert into r select 'p2', flow.wh_mark_printed(array[:'ol'], 'tester', 'label damaged', 'A4', 2);
select pg_temp.assert((select (j->>'reprints')::int = 1 from r where k = 'p2') and (select print_count from flow.labels where label_code = :'ol') = 2, 'reprint recorded');
select pg_temp.assert((select count(*) from flow.label_prints where is_reprint and reason = 'label damaged') = 1 and (select count(*) from flow.label_prints) = 2, 'print audit');
select pg_temp.assert(not (flow.wh_mark_printed(array[:'ol'], 't', null, 'poster', 1)->>'ok')::bool, 'bad format rejected');
-- order stays pending until the pick + bin labels are printed too
select pg_temp.assert((select label_status from flow.orders where id = :'o1') = 'pending', 'order not fully printed yet');
select flow.wh_mark_printed(array(select label_code from flow.labels where order_id = :'o1' or label_type = 'bin'), 'tester', 'reprint all', 'A4', 1);
select pg_temp.assert((select label_status from flow.orders where id = :'o1') = 'printed' and (select label_printed from flow.bins where bin_code = 'WH-02'), 'order printed, bin label flag set');
-- change after printing → version bump, reprint needed
select flow.wh_assign_bin(:'o1', 'WH-02', 2, 'tester', true, 'extra units arrived', null);
select flow.wh_generate_label('pick', '#H1', 'tester');
select pg_temp.assert((select version = 2 and print_status = 'pending' from flow.labels where label_type = 'pick'), 'changed pick list bumps version');
select pg_temp.assert((select label_status from flow.orders where id = :'o1') = 'reprint_needed', 'order flagged reprint_needed');
select flow.wh_mark_print_failed(array(select label_code from flow.labels where label_type = 'pick'), 'tester', 'printer jam');
select pg_temp.assert((select print_status from flow.labels where label_type = 'pick') = 'failed', 'print failure recorded');

-- 10. search + read models (needs a signed-in member)
insert into flow.user_roles values ('00000000-0000-0000-0000-0000000000e1', 'warehouse') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', false);
select pg_temp.assert((select count(*) from public.ui_wh_find('WH-02') where kind = 'bin') = 1, 'find bin');
select pg_temp.assert((select count(*) from flow.v_bin_assignments a, public.ui_wh_find('Hall') f where f.kind = 'order in bin' and f.label like '#H1%') >= 1, 'find by customer');
select pg_temp.assert((select count(*) from public.ui_wh_find('H-POLO-M') where kind in ('stock location', 'sku in bin')) >= 1, 'find by sku');
select pg_temp.assert((select count(*) from public.ui_wh_find('LAB-') ) = 0 and (select count(*) from public.ui_wh_find('ORD-')) >= 1, 'find label code');

select set_config('request.jwt.claim.sub', '', false);
-- 11. wrappers locked down
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_wh_assign_bin(uuid,text,int,text,boolean,text,jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.flow_wh_mark_printed(text[],text,text,text,int)', 'execute')
  and has_function_privilege('service_role', 'public.flow_wh_release_bin(text,uuid,text,text)', 'execute'), 'wrappers are service_role only');
\echo warehouse_test OK
