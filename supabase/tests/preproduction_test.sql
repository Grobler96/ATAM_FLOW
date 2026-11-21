-- Pre-production phase A: the "uses a process" tag condition, DTF placements, and the three traffic lights.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

-- fixtures ----------------------------------------------------------------------------------------------------------------------
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values
 ('PP1', '#PP1', 'Dtf only',    now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{dtf}',            true),
 ('PP2', '#PP2', 'Emb only',    now() + interval '9 days', 'awaiting_stock', true,  1, 4, now() - interval '2 days', '{embroidery}',     true),
 ('PP3', '#PP3', 'Both',        now() + interval '9 days', 'awaiting_stock', false, 1, 6, now() - interval '2 days', '{dtf,embroidery}', true),
 ('PP4', '#PP4', 'Neither',     now() + interval '9 days', 'awaiting_stock', false, 1, 2, now() - interval '2 days', '{uv}',             true),
 ('PP5', '#PP5', 'Inactive',    now() + interval '9 days', 'dispatched',     true,  9, 5, now() - interval '9 days', '{dtf}',            false);
select id as o1 from flow.orders where deco_order_id = 'PP1' \gset
select id as o2 from flow.orders where deco_order_id = 'PP2' \gset
select id as o3 from flow.orders where deco_order_id = 'PP3' \gset
select id as o4 from flow.orders where deco_order_id = 'PP4' \gset
select id as o5 from flow.orders where deco_order_id = 'PP5' \gset
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, qty_required, decoration_methods, product_name) values
 ('PPW1', 'L1', :'o1', 'S1', 3, '{dtf}', 'Pro polo'), ('PPW2', 'L1', :'o1', 'S2', 2, '{dtf}', 'Pro polo'), ('PPW3', 'L2', :'o1', 'S3', 3, '{dtf}', 'Hoodie'),
 ('PPW4', 'L3', :'o2', 'S4', 4, '{embroidery}', 'Cap'),
 ('PPW5', 'L4', :'o3', 'S5', 4, '{dtf,embroidery}', 'Tee'), ('PPW6', 'L5', :'o3', 'S6', 2, '{embroidery}', 'Tee'),
 ('PPW7', 'L6', :'o4', 'S7', 2, '{uv}', 'Mug');

-- 1. the new condition: a tag for every order that uses DTF ----------------------------------------------------------------------
select pg_temp.assert(exists (select 1 from flow.tag_definitions where code = 'needs_dtf') and exists (select 1 from flow.tag_rules where kind = 'method_includes' and params->>'method' = 'dtf'), 'the Needs DTF tag and its rule are seeded');
insert into r select 'facts', flow.order_facts_ingest(jsonb_build_array(
  jsonb_build_object('order_id', 'PP1', 'decoration_count', 4, 'dtf', jsonb_build_array(jsonb_build_object('deco_line_id', 'L1', 'area', 'Back', 'qty', 5), jsonb_build_object('deco_line_id', 'L1', 'area', 'Left Chest', 'qty', 5), jsonb_build_object('deco_line_id', 'L2', 'area', 'Back', 'qty', 3), jsonb_build_object('deco_line_id', 'L2', 'area', 'Back (2)', 'qty', 3))),
  jsonb_build_object('order_id', 'PP2', 'decoration_count', 2, 'dtf', '[]'::jsonb),
  jsonb_build_object('order_id', 'PP3', 'decoration_count', 3, 'dtf', jsonb_build_array(jsonb_build_object('deco_line_id', 'L4', 'area', 'Front', 'qty', 4))),
  jsonb_build_object('order_id', 'PP4', 'decoration_count', 1, 'dtf', '[]'::jsonb),
  jsonb_build_object('order_id', 'PP5', 'decoration_count', 1, 'dtf', jsonb_build_array(jsonb_build_object('deco_line_id', 'L9', 'area', 'Back', 'qty', 5)))), 'test');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'saved')::int = 5 from r where k = 'facts'), 'facts saved: ' || (select j::text from r where k = 'facts'));
select pg_temp.assert((select quantity = 8 and label = 'Needs DTF prints' from public.ui_order_tags where order_ref = '#PP1'), 'PP1 is tagged Needs DTF prints with its 8 garments');
select pg_temp.assert((select quantity = 4 from public.ui_order_tags where order_ref = '#PP3' and tag_code = 'needs_dtf'), 'PP3 counts only the garments that use DTF (4, not 6)');
select pg_temp.assert(not exists (select 1 from flow.order_tags where order_id in (:'o2', :'o4') and tag_code = 'needs_dtf'), 'orders without DTF are not tagged');

-- 2. DTF placements ---------------------------------------------------------------------------------------------------------------
select pg_temp.assert((select count(*) = 4 from flow.dtf_items where order_id = :'o1' and is_current and status = 'required'), 'PP1 has four DTF placements, all required');
select pg_temp.assert((select count(*) = 0 from flow.dtf_items where order_id in (:'o2', :'o4')), 'orders with an empty list have none');
select pg_temp.assert(not exists (select 1 from public.ui_dtf_items where order_ref = '#PP5'), 'an inactive order shows no DTF placements');
insert into flow.artwork_files (order_id, deco_line_id, area, process, thumbnail_url, file_format, signature, storage_status, content_hash, approval_status)
  values (:'o1', 'L2', 'Back', 'dtf', 'https://example.test/t.png', 'png', 'sig-pp1', 'stored', 'hash-1', 'pending');
select pg_temp.assert((select count(*) = 2 and bool_and(thumbnail_url = 'https://example.test/t.png') and bool_and(content_hash = 'hash-1') from public.ui_dtf_items where order_ref = '#PP1' and deco_line_id = 'L2'), 'a repeated placement (Back, Back (2)) both find the Back artwork and its thumbnail');
select pg_temp.assert((select thumbnail_url is null and product_name = 'Pro polo' and qty = 5 from public.ui_dtf_items where order_ref = '#PP1' and area = 'Left Chest'), 'a placement with no artwork file yet has no thumbnail, but names the product and the garments');

-- re-reading: idempotent, quantity updates, status survives, missing placements are not deleted -----------------------------------------
update flow.dtf_items set status = 'in_progress' where order_id = :'o1' and area = 'Left Chest';
insert into r select 'again', flow.order_facts_ingest('[{"order_id":"PP1","decoration_count":4,"dtf":[{"deco_line_id":"L1","area":"Back","qty":6},{"deco_line_id":"L1","area":"Left Chest","qty":5},{"deco_line_id":"L2","area":"Back","qty":3}]}]'::jsonb, 'test');
select pg_temp.assert((select qty = 6 from flow.dtf_items where order_id = :'o1' and deco_line_id = 'L1' and area = 'Back'), 'a changed quantity is updated');
select pg_temp.assert((select status = 'in_progress' from flow.dtf_items where order_id = :'o1' and area = 'Left Chest'), 'a re-read does not reset a status');
select pg_temp.assert((select count(*) = 4 from flow.dtf_items where order_id = :'o1') and (select not is_current from flow.dtf_items where order_id = :'o1' and area = 'Back (2)'), 'a placement that left the order is marked not current, not deleted');
select pg_temp.assert((select count(*) = 3 from public.ui_dtf_items where order_ref = '#PP1'), 'the view shows only current placements');
insert into r select 'nolist', flow.order_facts_ingest('[{"order_id":"PP1","decoration_count":4}]'::jsonb, 'test');
select pg_temp.assert((select count(*) = 3 from flow.dtf_items where order_id = :'o1' and is_current), 'a read that carries no DTF list leaves the placements alone');
insert into r select 'badrow', flow.order_facts_ingest('[{"order_id":"PP1","decoration_count":4,"dtf":[{"deco_line_id":"","area":"Back","qty":1},{"deco_line_id":"L7","area":"Back","qty":"lots"},{"deco_line_id":"L1","area":"Back","qty":6},{"deco_line_id":"L1","area":"Left Chest","qty":5},{"deco_line_id":"L2","area":"Back","qty":3}]}]'::jsonb, 'test');
select pg_temp.assert((select count(*) = 3 from flow.dtf_items where order_id = :'o1' and is_current), 'rows with no line, no placement or a bad quantity are ignored');

-- 3. the lights ----------------------------------------------------------------------------------------------------------------------------
-- prints: red when DTF is needed and nothing has started, amber when some have, green when all are done, none when no DTF
select pg_temp.assert((select prints = 'amber' and prints_items = 3 and prints_units = 14 and prints_done = 0 from public.ui_preproduction where order_ref = '#PP1'), 'prints: one placement in progress makes it amber');
update flow.dtf_items set status = 'required' where order_id = :'o1';
select pg_temp.assert((select prints = 'red' from public.ui_preproduction where order_ref = '#PP1'), 'prints: nothing started is red');
update flow.dtf_items set status = 'done' where order_id = :'o1';
select pg_temp.assert((select prints = 'green' from public.ui_preproduction where order_ref = '#PP1'), 'prints: all done is green');
update flow.dtf_items set status = 'done' where order_id = :'o1' and area = 'Back' and deco_line_id = 'L1'; update flow.dtf_items set status = 'required' where order_id = :'o1' and area <> 'Back';
select pg_temp.assert((select prints = 'amber' from public.ui_preproduction where order_ref = '#PP1'), 'prints: some done and some not is amber');
select pg_temp.assert((select prints = 'none' and embroidery = 'none' from public.ui_preproduction where order_ref = '#PP4'), 'an order with neither process has no prints or embroidery light');
update flow.orders set decoration_methods = '{dtf}' where id = :'o4'; delete from flow.dtf_items where order_id = :'o4';
select pg_temp.assert((select prints = 'red' and prints_items = 0 from public.ui_preproduction where order_ref = '#PP4'), 'an order that uses DTF but has no placements read yet is red, not blank');
update flow.orders set decoration_methods = '{uv}' where id = :'o4';
-- embroidery: red with no artwork, amber when some is approved or stored, green when every area is approved and stored
select pg_temp.assert((select embroidery = 'red' and embroidery_areas = 0 from public.ui_preproduction where order_ref = '#PP2'), 'embroidery: no artwork recorded is red');
insert into flow.artwork_files (order_id, deco_line_id, area, process, signature, storage_status, approval_status) values (:'o2', 'L3', 'Front', 'embroidery', 'sig-e1', 'stored', 'approved'), (:'o2', 'L3', 'Back', 'embroidery', 'sig-e2', 'stored', 'pending');
select pg_temp.assert((select embroidery = 'amber' and embroidery_areas = 2 and embroidery_approved = 1 and embroidery_stored = 2 from public.ui_preproduction where order_ref = '#PP2'), 'embroidery: one of two approved is amber');
update flow.artwork_files set approval_status = 'approved' where order_id = :'o2';
select pg_temp.assert((select embroidery = 'green' from public.ui_preproduction where order_ref = '#PP2'), 'embroidery: every area approved and stored is green');
update flow.artwork_files set storage_status = 'failed' where order_id = :'o2' and area = 'Back';
select pg_temp.assert((select embroidery = 'amber' from public.ui_preproduction where order_ref = '#PP2'), 'embroidery: an approved area whose file failed to store is not green');
-- stock
select pg_temp.assert((select stock = 'green' from public.ui_preproduction where order_ref = '#PP2') and (select stock = 'red' from public.ui_preproduction where order_ref = '#PP1'), 'stock: secured is green, not secured is red');
update flow.orders set alloc_state = 'partial' where id = :'o1';
select pg_temp.assert((select stock = 'amber' from public.ui_preproduction where order_ref = '#PP1'), 'stock: partly allocated is amber');
select pg_temp.assert(not exists (select 1 from public.ui_preproduction where order_ref = '#PP5'), 'an inactive order has no lights');
select pg_temp.assert((select count(*) = 4 from public.ui_preproduction where order_ref in ('#PP1', '#PP2', '#PP3', '#PP4')), 'one row per active order');

-- 4. rules can use the new condition ------------------------------------------------------------------------------------------------------
insert into r select 'newtag', flow.rr_save_tag_rule(null, 'needs_embroidery_check', 'Embroidery to check', 'Uses embroidery', 'method_includes', '{"method":"embroidery"}', true, 'tester', 'Embroidery check list');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'newtag') and (select quantity = 6 from flow.order_tags where order_id = :'o3' and tag_code = 'needs_embroidery_check'), 'a tag rule can use the new condition, and re-checks every order: ' || (select j::text from r where k = 'newtag'));
insert into r select 'notag', flow.rr_save_tag_rule(null, 'x_tag', 'X', 'No process', 'method_includes', '{}', true, 'tester', 'Missing process');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'notag'), 'a "uses a process" rule must name the process');
insert into r select 'route', flow.rr_save_routing_rule(null, 30, 'DTF orders to a third party', 'method_includes', '{"method":"dtf"}', 'third_party', null, true, 'tester', 'Trial in shadow mode');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'route'), 'a routing rule can use the new condition: ' || (select j::text from r where k = 'route'));
select pg_temp.assert((select outcome in ('would_change', 'protected', 'already_matches', 'manual_wins') and rule_name is not null from flow.routing_decisions where order_id = :'o1'), 'and it is evaluated in shadow mode like the others');
select pg_temp.assert((select scope = 'unclassified' from public.ui_order_scope where order_ref = '#PP1'), 'the real scope is still untouched');

-- 5. permissions -----------------------------------------------------------------------------------------------------------------------------------
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.dtf_sync(uuid,jsonb)', 'execute') and not has_function_privilege('anon', 'flow.dtf_sync(uuid,jsonb)', 'execute'), 'only the database itself can write DTF placements');
select pg_temp.assert(not has_table_privilege('authenticated', 'flow.dtf_items', 'insert') and not has_table_privilege('authenticated', 'flow.dtf_items', 'update'), 'staff cannot write DTF placements directly');
select pg_temp.assert(has_table_privilege('authenticated', 'public.ui_preproduction', 'select') and has_table_privilege('authenticated', 'public.ui_dtf_items', 'select') and not has_table_privilege('anon', 'public.ui_preproduction', 'select'), 'staff can read the lights and DTF views, anonymous users cannot');
\echo preproduction_test OK
