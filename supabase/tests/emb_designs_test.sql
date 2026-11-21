-- Embroidery step 1: the design register, swatch statuses, suggestions and the Embroidery light.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.orders (deco_order_id, order_ref, customer_id, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values
 ('EM1', '#EM1', 'CUST-A', 'Northside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('EM2', '#EM2', 'CUST-A', 'Northside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('EM3', '#EM3', 'CUST-B', 'Other Club',   now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('EM4', '#EM4', 'CUST-A', 'Northside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('EM5', '#EM5', 'CUST-A', 'Northside FC', now() + interval '9 days', 'dispatched',     false, 9, 8, now() - interval '9 days', '{embroidery}', false);
select id as o1 from flow.orders where deco_order_id = 'EM1' \gset
select id as o2 from flow.orders where deco_order_id = 'EM2' \gset
select id as o3 from flow.orders where deco_order_id = 'EM3' \gset
select id as o4 from flow.orders where deco_order_id = 'EM4' \gset
select id as o5 from flow.orders where deco_order_id = 'EM5' \gset
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status, stitch_count, width_mm, height_mm, thumbnail_url) values
 (:'o1', 'L1', 'Left Chest', 'embroidery', 'dst', 'sig-crest', 'failed', 'unknown', 5200, 80, 60, 'https://example.test/crest.png'),
 (:'o1', 'L1', 'Back',       'embroidery', 'dst', 'sig-back',  'failed', 'unknown', 9100, 250, 120, null),
 (:'o2', 'L2', 'Left Chest', 'embroidery', 'dst', 'sig-crest', 'failed', 'unknown', 5200, 80, 60, null),
 (:'o3', 'L3', 'Left Chest', 'embroidery', 'dst', 'sig-crest', 'failed', 'unknown', 5200, 80, 60, null),
 (:'o4', 'L4', 'Left Chest', 'embroidery', 'dst', 'sig-crest-v2', 'failed', 'unknown', 5200, 81, 59, null),
 (:'o5', 'L5', 'Left Chest', 'embroidery', 'dst', 'sig-crest', 'failed', 'unknown', 5200, 80, 60, null);

-- 1. before anything is done: every area is "to review" and the light is red
select pg_temp.assert((select count(*) = 2 and bool_and(area_status = 'to_review') from public.ui_emb_areas where order_ref = '#EM1'), 'unlinked areas are to review');
select pg_temp.assert(not exists (select 1 from public.ui_emb_areas where order_ref = '#EM5'), 'an inactive order shows no areas');
select pg_temp.assert((select embroidery = 'red' from public.ui_preproduction where order_ref = '#EM1'), 'red before any design');
select pg_temp.assert((select bool_and(suggested_design_id is null) from public.ui_emb_areas), 'no design yet, so no suggestions');

-- 2. a new logo: create a design from the area
insert into r select 'c1', flow.emb_create_design(:'o1', 'L1', 'Left Chest', null, 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'c1'), 'a design is created: ' || (select j::text from r where k = 'c1'));
select j->>'design_id' as d1 from r where k = 'c1' \gset
select pg_temp.assert((select area_status = 'swatch_required' and design_name = 'Northside FC · Left Chest · #EM1' and design_round = 1 from public.ui_emb_areas where order_ref = '#EM1' and area = 'Left Chest'), 'the new design is swatch required and named from the customer, area and order');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where entity = 'emb_designs' and entity_id = :'d1' and action = 'emb_design_created'), 'creating is audited');
insert into r select 'c2', flow.emb_create_design(:'o1', 'L1', 'Left Chest', null, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c2'), 'an area that is already linked cannot be made into a second design');
insert into r select 'c3', flow.emb_create_design(:'o1', 'L1', 'Sleeve', null, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c3'), 'an area that is not on the order is refused');
insert into r select 'c4', flow.emb_create_design(:'o5', 'L5', 'Left Chest', null, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c4'), 'an inactive order is refused');

-- 3. suggestions: same customer, same artwork or same stitches and size; never another customer
select pg_temp.assert((select suggested_design_id = :'d1' and suggested_why = 'Same artwork' and suggested_status = 'swatch_required' from public.ui_emb_areas where order_ref = '#EM2'), 'the same artwork for the same customer is suggested');
select pg_temp.assert((select suggested_design_id is null from public.ui_emb_areas where order_ref = '#EM3'), 'the same artwork for another customer is never suggested');
select pg_temp.assert((select suggested_design_id = :'d1' and suggested_why = 'Same stitch count and size' from public.ui_emb_areas where order_ref = '#EM4'), 'a near-identical stitch count and size is suggested, with that reason');
select pg_temp.assert((select suggested_design_id is null from public.ui_emb_areas where order_ref = '#EM1' and area = 'Back'), 'a different logo has no suggestion');

-- 4. confirming a suggestion links the area
insert into r select 'l1', flow.emb_link(:'o2', 'L2', 'Left Chest', :'d1', 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'l1'), 'the area is linked');
select pg_temp.assert((select area_status = 'swatch_required' and suggested_design_id is null from public.ui_emb_areas where order_ref = '#EM2'), 'a linked area takes its design status and stops being a suggestion');
insert into r select 'l2', flow.emb_link(:'o2', 'L2', 'Left Chest', :'d1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'l2'), 'linking twice is refused');
insert into r select 'l3', flow.emb_link(:'o3', 'L3', 'Left Chest', :'d1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'l3') and (select j->>'error' from r where k = 'l3') = 'That design belongs to a different customer.', 'a design cannot be used for another customer');
select pg_temp.assert((select orders_using = 2 from public.ui_emb_designs where id = :'d1'), 'the design is used on two orders');

-- 5. statuses, rounds and the light
insert into r select 's0', flow.emb_set_status(:'d1', 'swatch_sent', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's0'), 'a swatch cannot be sent before it is made');
insert into r select 's1', flow.emb_set_status(:'d1', 'swatch_in_progress', 'dashboard:tester', null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 's1') and (select area_status = 'swatch_in_progress' from public.ui_emb_areas where order_ref = '#EM2'), 'swatch in progress shows on every order using the design');
select pg_temp.assert((select embroidery = 'amber' from public.ui_preproduction where order_ref = '#EM2'), 'a swatch under way is amber');
insert into r select 's2', flow.emb_set_status(:'d1', 'swatch_sent', 'dashboard:tester', null);
insert into r select 's3', flow.emb_set_status(:'d1', 'changes_needed', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's3'), 'asking for changes needs a reason');
insert into r select 's4', flow.emb_set_status(:'d1', 'changes_needed', 'dashboard:tester', 'Thread too dark');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'round')::int = 1 from r where k = 's4'), 'changes needed keeps the round until work starts again');
insert into r select 's5', flow.emb_set_status(:'d1', 'swatch_in_progress', 'dashboard:tester', null);
select pg_temp.assert((select (j->>'round')::int = 2 from r where k = 's5') and (select design_round = 2 from public.ui_emb_areas where order_ref = '#EM2'), 'starting again after a rejection is round 2');
insert into r select 's6', flow.emb_set_status(:'d1', 'swatch_approved', 'dashboard:tester', null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 's6'), 'a swatch in progress can be approved');
select pg_temp.assert((select embroidery = 'green' from public.ui_preproduction where order_ref = '#EM2'), 'every area on the order has an approved design, so green');
select pg_temp.assert((select embroidery = 'amber' from public.ui_preproduction where order_ref = '#EM1'), 'one area done and one still to review is amber');
insert into r select 's7', flow.emb_set_status(:'d1', 'swatch_required', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's7'), 'reopening an approved design needs a reason');
insert into r select 's8', flow.emb_set_status(:'d1', 'swatch_required', 'dashboard:tester', 'Customer changed the logo');
select pg_temp.assert((select (j->>'round')::int = 3 from r where k = 's8') and (select embroidery = 'red' from public.ui_preproduction where order_ref = '#EM2'), 'reopening starts round 3 and the light goes back to red');
select pg_temp.assert((select count(*) >= 6 from public.ui_emb_events where design_id = :'d1'), 'every change is in the history');
select pg_temp.assert((select count(*) >= 6 from flow.audit_log where entity = 'emb_designs' and entity_id = :'d1' and action = 'emb_design_status'), 'every status change is audited');

-- 6. "done before": a logo we already did can be marked known straight away
insert into r select 'c5', flow.emb_create_design(:'o1', 'L1', 'Back', 'Northside back print', 'dashboard:tester');
select j->>'design_id' as d2 from r where k = 'c5' \gset
insert into r select 'k1', flow.emb_set_status(:'d2', 'known', 'dashboard:tester', null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'k1') and (select area_status = 'known' and design_name = 'Northside back print' from public.ui_emb_areas where order_ref = '#EM1' and area = 'Back'), 'a logo done before is marked known, with the name given');

-- 7. unlinking switches the link off and keeps the history
insert into r select 'u1', flow.emb_unlink(:'o2', 'L2', 'Left Chest', 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'u1') and (select area_status = 'to_review' from public.ui_emb_areas where order_ref = '#EM2'), 'an unlinked area goes back to review');
select pg_temp.assert((select count(*) = 1 from flow.emb_links where order_id = :'o2' and not is_active) and exists (select 1 from flow.emb_events where design_id = :'d1' and event = 'unlinked'), 'the old link is kept, switched off');
insert into r select 'u2', flow.emb_unlink(:'o2', 'L2', 'Left Chest', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'u2'), 'unlinking an unlinked area is refused');
insert into r select 'l4', flow.emb_link(:'o2', 'L2', 'Left Chest', :'d1', 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'l4'), 'it can be linked again');

-- 7b. the proof sheet can download the stored stitch file: the view carries its path
update flow.artwork_files set storage_status = 'stored', storage_path = 'orders/EM1/left-chest/v1.dst' where order_id = :'o1' and area = 'Left Chest';
select pg_temp.assert((select storage_path = 'orders/EM1/left-chest/v1.dst' and storage_status = 'stored' from public.ui_emb_areas where order_ref = '#EM1' and area = 'Left Chest'), 'a stored stitch file shows its path');
select pg_temp.assert((select storage_path is null from public.ui_emb_areas where order_ref = '#EM1' and area = 'Back'), 'an area with no stored file has no path');

-- 8. privileges
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_emb_set_status(uuid,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_emb_set_status(uuid,text,text,text)', 'execute') and has_function_privilege('service_role', 'public.flow_emb_set_status(uuid,text,text,text)', 'execute'), 'only the service role can change a design');
select pg_temp.assert(not has_table_privilege('authenticated', 'flow.emb_designs', 'insert') and has_table_privilege('authenticated', 'flow.emb_designs', 'select'), 'staff can read designs but not write them directly');
select 'emb_designs_test OK';
