-- Embroidery step 3: files to update in DecoNetwork, the old-file warning, and the bulk "done before".
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.orders (deco_order_id, order_ref, customer_id, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values
 ('ED1', '#ED1', 'CUST-D', 'Dockside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('ED2', '#ED2', 'CUST-D', 'Dockside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '1 days', '{embroidery}', true),
 ('ED3', '#ED3', 'CUST-D', 'Dockside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true),
 ('ED4', '#ED4', 'CUST-E', 'Eastgate',    now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true);
select id as o1 from flow.orders where deco_order_id = 'ED1' \gset
select id as o2 from flow.orders where deco_order_id = 'ED2' \gset
select id as o3 from flow.orders where deco_order_id = 'ED3' \gset
select id as o4 from flow.orders where deco_order_id = 'ED4' \gset
-- order 1 holds the DecoNetwork file (signature sig-old); order 2 is another order with the same old file
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status, stitch_count, width_mm, height_mm, source) values
 (:'o1', 'L1', 'Left Chest', 'embroidery', 'dst', 'sig-old', 'failed', 'unknown', 5200, 80, 60, 'deconetwork'),
 (:'o2', 'L2', 'Left Chest', 'embroidery', 'dst', 'sig-old', 'failed', 'unknown', 5200, 80, 60, 'deconetwork');

-- 1. a swatch round: create, work on it, rework the file by hand, approve from the area
insert into r select 'c1', flow.emb_create_design(:'o1', 'L1', 'Left Chest', 'Dockside crest', 'dashboard:tester');
select j->>'design_id' as d1 from r where k = 'c1' \gset
select flow.emb_set_status(:'d1', 'swatch_in_progress', 'dashboard:tester', null);
select flow.emb_set_status(:'d1', 'swatch_sent', 'dashboard:tester', null);
select pg_temp.assert((select deco_status = 'in_sync' and approved_artwork_id is null from public.ui_emb_designs where id = :'d1'), 'a new design has no approved file and nothing to update');
-- the file is reworked and uploaded by hand: version 2, source manual
select flow.artwork_manual_replace(:'o1', 'L1', 'Left Chest', 'orders/ED1/left-chest/v2.dst', 'tester', 'Thread changes after the swatch', jsonb_build_object('stitch_count', 5400, 'file_format', 'DST'));
insert into r select 'a0', flow.emb_approve(:'d1', :'o2', 'L2', 'Left Chest', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a0'), 'approving from an area that is not linked to the design is refused');
insert into r select 'a1', flow.emb_approve(:'d1', :'o1', 'L1', 'Left Chest', 'dashboard:tester', 'Customer happy');
select pg_temp.assert((select (j->>'ok')::bool and j->>'deco_status' = 'update_needed' and j->>'file_source' = 'manual' from r where k = 'a1'), 'approving a hand-uploaded file puts the design on the DecoNetwork list: ' || (select j::text from r where k = 'a1'));
select pg_temp.assert((select status = 'swatch_approved' and deco_status = 'update_needed' and approved_by = 'dashboard:tester' and approved_at is not null and approved_file_path = 'orders/ED1/left-chest/v2.dst' and approved_version = 2 and approved_file_format = 'DST' from public.ui_emb_designs where id = :'d1'), 'the approved file, who and when are recorded');
select pg_temp.assert((select deco_signature = 'sig-old' from flow.emb_designs where id = :'d1'), 'the signature of the DecoNetwork file it replaced is remembered');
select pg_temp.assert((select count(*) = 1 from flow.emb_events where design_id = :'d1' and event = 'file_approved') and (select count(*) = 1 from flow.audit_log where entity_id = :'d1' and action = 'emb_design_file_approved'), 'the file approval is in the history and audited');
select pg_temp.assert((select deco_stale = false and area_status = 'swatch_approved' from public.ui_emb_areas where order_ref = '#ED1'), 'the reworked order itself is not stale');

-- 2. the next order arrives carrying the OLD DecoNetwork file: it is recognised and warned
select pg_temp.assert((select suggested_design_id = :'d1' and suggested_why = 'Same artwork' and deco_stale and deco_status = 'update_needed' and approved_file_path = 'orders/ED1/left-chest/v2.dst' from public.ui_emb_areas where order_ref = '#ED2'), 'the old file is still recognised as the same logo, flagged as old, with the approved file to use');
select flow.emb_link(:'o2', 'L2', 'Left Chest', :'d1', 'dashboard:tester');
select pg_temp.assert((select deco_stale and area_status = 'swatch_approved' and approved_file_path = 'orders/ED1/left-chest/v2.dst' from public.ui_emb_areas where order_ref = '#ED2'), 'a linked order carrying the old file is flagged too');
select pg_temp.assert((select count(*) = 1 from public.ui_emb_areas where deco_stale and order_ref in ('#ED1', '#ED2')), 'only the order that still carries the old file is flagged');
select pg_temp.assert((select embroidery = 'green' from public.ui_preproduction where order_ref = '#ED1'), 'the Embroidery light is still green for the approved design');

-- 3. tick it off once DecoNetwork has the new file
insert into r select 'u1', flow.emb_deco_updated(:'d1', 'dashboard:tester', 'Replaced on the Deco order');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'u1') and (select deco_status = 'updated' and deco_updated_by = 'dashboard:tester' and deco_updated_at is not null and deco_note = 'Replaced on the Deco order' from public.ui_emb_designs where id = :'d1'), 'ticking it off records who, when and a note');
select pg_temp.assert((select not deco_stale from public.ui_emb_areas where order_ref = '#ED2'), 'the warning goes once DecoNetwork has been updated');
insert into r select 'u2', flow.emb_deco_updated(:'d1', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'u2'), 'it cannot be ticked off twice');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where entity_id = :'d1' and action = 'emb_design_deco_updated') and exists (select 1 from flow.emb_events where design_id = :'d1' and event = 'deco_updated'), 'ticking off is audited and in the history');

-- 4. approving a file DecoNetwork already holds needs no update
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status, stitch_count, width_mm, height_mm, source) values
 (:'o4', 'L4', 'Back', 'embroidery', 'dst', 'sig-e', 'failed', 'unknown', 9000, 200, 100, 'deconetwork');
insert into r select 'c2', flow.emb_create_design(:'o4', 'L4', 'Back', null, 'dashboard:tester');
select j->>'design_id' as d2 from r where k = 'c2' \gset
select flow.emb_set_status(:'d2', 'swatch_in_progress', 'dashboard:tester', null);
insert into r select 'a2', flow.emb_approve(:'d2', :'o4', 'L4', 'Back', 'dashboard:tester', null);
select pg_temp.assert((select (j->>'ok')::bool and j->>'deco_status' = 'in_sync' from r where k = 'a2') and (select deco_status = 'in_sync' from public.ui_emb_designs where id = :'d2'), 'a file that came from DecoNetwork is in sync: nothing to update');
insert into r select 'u3', flow.emb_deco_updated(:'d2', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'u3'), 'a design with nothing to update cannot be ticked off');
insert into r select 'a3', flow.emb_approve(:'d2', :'o4', 'L4', 'Back', 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a3'), 'a design that is already approved cannot be approved again');

-- 5. a second round: reopen, upload another version, approve: back on the list
insert into r select 'r1', flow.emb_set_status(:'d1', 'swatch_required', 'dashboard:tester', 'Customer changed the logo');
select flow.emb_set_status(:'d1', 'swatch_in_progress', 'dashboard:tester', null);
select flow.artwork_manual_replace(:'o1', 'L1', 'Left Chest', 'orders/ED1/left-chest/v3.dst', 'tester', 'New logo from the customer', '{}'::jsonb);
insert into r select 'a4', flow.emb_approve(:'d1', :'o1', 'L1', 'Left Chest', 'dashboard:tester', null);
select pg_temp.assert((select deco_status = 'update_needed' and deco_updated_at is null and approved_file_path = 'orders/ED1/left-chest/v3.dst' and round = 2 from public.ui_emb_designs where id = :'d1'), 'a new approved file puts it back on the list with a fresh tick-off, in round 2');
select pg_temp.assert((select deco_signature = 'sig-old' from flow.emb_designs where id = :'d1'), 'the original DecoNetwork file is still remembered through two hand uploads');

-- 6. bulk "done before"
insert into flow.orders (deco_order_id, order_ref, customer_id, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values
 ('EB1', '#EB1', 'CUST-F', 'Fulham Co', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true),
 ('EB2', '#EB2', 'CUST-F', 'Fulham Co', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true),
 ('EB3', '#EB3', 'CUST-F', 'Fulham Co', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true),
 ('EB4', '#EB4', 'CUST-F', 'Fulham Co', now() + interval '9 days', 'dispatched',     false, 9, 8, now(), '{embroidery}', false),
 ('EB5', '#EB5', 'CUST-D', 'Dockside FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true);
select id as b1 from flow.orders where deco_order_id = 'EB1' \gset
select id as b2 from flow.orders where deco_order_id = 'EB2' \gset
select id as b3 from flow.orders where deco_order_id = 'EB3' \gset
select id as b4 from flow.orders where deco_order_id = 'EB4' \gset
select id as b5 from flow.orders where deco_order_id = 'EB5' \gset
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status, stitch_count, width_mm, height_mm, source) values
 (:'b1', 'M1', 'Left Chest', 'embroidery', 'dst', 'sig-f1', 'failed', 'unknown', 4000, 70, 50, 'deconetwork'),
 (:'b2', 'M2', 'Left Chest', 'embroidery', 'dst', 'sig-f1', 'failed', 'unknown', 4000, 70, 50, 'deconetwork'),
 (:'b3', 'M3', 'Left Chest', 'embroidery', 'dst', 'sig-f2', 'failed', 'unknown', 7000, 90, 90, 'deconetwork'),
 (:'b4', 'M4', 'Left Chest', 'embroidery', 'dst', 'sig-f1', 'failed', 'unknown', 4000, 70, 50, 'deconetwork'),
 (:'b5', 'M5', 'Left Chest', 'embroidery', 'dst', 'sig-old', 'failed', 'unknown', 1, 1, 1, 'deconetwork');
select flow.emb_set_status(:'d1', 'changes_needed', 'dashboard:tester', 'Another tweak from the customer');
insert into r select 'k0', flow.emb_bulk_known('[]'::jsonb, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'k0'), 'nothing chosen is refused');
insert into r select 'k1', flow.emb_bulk_known(jsonb_build_array(
  jsonb_build_object('order_id', :'b1', 'deco_line_id', 'M1', 'area', 'Left Chest'), jsonb_build_object('order_id', :'b2', 'deco_line_id', 'M2', 'area', 'Left Chest'), jsonb_build_object('order_id', :'b3', 'deco_line_id', 'M3', 'area', 'Left Chest'),
  jsonb_build_object('order_id', :'b4', 'deco_line_id', 'M4', 'area', 'Left Chest'), jsonb_build_object('order_id', :'o1', 'deco_line_id', 'L1', 'area', 'Left Chest'), jsonb_build_object('order_id', :'b1', 'deco_line_id', 'M1', 'area', 'Sleeve'),
  jsonb_build_object('order_id', :'b5', 'deco_line_id', 'M5', 'area', 'Left Chest')), 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'created')::int = 2 and (j->>'linked')::int = 1 and (j->>'skipped')::int = 3 and (j->>'in_progress')::int = 1 from r where k = 'k1'), 'two designs made, one area joined the first, three skipped (inactive, already linked, not on the order), one left alone because its design is in progress: ' || (select j::text from r where k = 'k1'));
select pg_temp.assert((select count(distinct design_id) = 2 and bool_and(area_status = 'known') from public.ui_emb_areas where order_ref in ('#EB1', '#EB2', '#EB3')), 'the same logo on two orders shares one design, both marked done before');
select pg_temp.assert((select count(*) = 2 from flow.audit_log where action = 'emb_design_created' and (after->>'bulk')::boolean) and exists (select 1 from flow.audit_log where action = 'emb_bulk_known'), 'a bulk run is audited');
select pg_temp.assert((select area_status = 'to_review' from public.ui_emb_areas where order_ref = '#EB5'), 'an area whose design is still in progress is not touched');
select pg_temp.assert((select embroidery = 'green' from public.ui_preproduction where order_ref = '#EB3'), 'an order with only done-before logos is green');
-- a later order for the same logo now gets a suggestion that points at a done design
insert into flow.orders (deco_order_id, order_ref, customer_id, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values ('EB6', '#EB6', 'CUST-F', 'Fulham Co', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true);
select id as b6 from flow.orders where deco_order_id = 'EB6' \gset
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status, stitch_count, width_mm, height_mm, source) values (:'b6', 'M6', 'Left Chest', 'embroidery', 'dst', 'sig-f1', 'failed', 'unknown', 4000, 70, 50, 'deconetwork');
select pg_temp.assert((select suggested_status = 'known' and suggested_why = 'Same artwork' and not deco_stale from public.ui_emb_areas where order_ref = '#EB6'), 'a later order for a logo marked done before is suggested, with no warning');

-- 7. privileges
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_emb_approve(uuid,uuid,text,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_emb_bulk_known(jsonb,text)', 'execute') and has_function_privilege('service_role', 'public.flow_emb_deco_updated(uuid,text,text)', 'execute') and not has_function_privilege('authenticated', 'flow.emb_bulk_known(jsonb,text)', 'execute'), 'only the service role can approve, tick off or bulk mark');
select 'emb_deco_test OK';
