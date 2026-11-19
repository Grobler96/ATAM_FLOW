-- Artwork files from Google Drive (supabase/pending/20261119000068). Runs after all migrations.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

-- ---- reading file names ----
select pg_temp.assert(flow.drive_parse_name('order-636894-3730138646-Front-Left_Chest-EMB.dst') = '{"kind":"design","order":"636894","line":"3730138646","location":"Front","area":"Left Chest","process":"EMB","ext":"dst"}'::jsonb, 'normal name');
select pg_temp.assert(flow.drive_parse_name('order-636894-3730138646-_Right_Sleeve-Right_Sleeve_(Long)-EMB.dst')->>'area' = 'Right Sleeve (Long)', 'underscores become spaces, custom location');
select pg_temp.assert(flow.drive_parse_name('order-636894-3730138646-_Right_Sleeve-Right_Sleeve_(Long)-EMB.dst')->>'location' = 'Right Sleeve', 'leading underscore trimmed');
select pg_temp.assert(flow.drive_parse_name('order-1-2-Left_Chest-EMB.dst')->>'area' = 'Left Chest', 'name without a location part');
select pg_temp.assert(flow.drive_parse_name('worksheet-636084.pdf')->>'kind' = 'worksheet', 'worksheet');
select pg_temp.assert(flow.drive_parse_name('holiday.jpg')->>'kind' = 'other', 'other file');
select pg_temp.assert(flow.drive_process('EMB') = 'embroidery' and flow.drive_process('dtf') = 'dtf' and flow.drive_process('XYZ') = 'xyz', 'process codes');

-- ---- data: order 900001 with one embroidered line; DecoNetwork already recorded two areas (no file) ----
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units) values ('900001', '#900001', 'Drive Co', '2026-12-01 12:00+00', 'ready_for_production', 1, true, 10);
select id as o1 from flow.orders where deco_order_id = '900001' \gset
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
values ('DRW1', '3730138646', :'o1', 'DR-SKU', 'Navy', 'M', 'Polo', 10, '{embroidery}');
insert into flow.artwork_files (order_id, deco_line_id, area, process, stitch_count, thumbnail_url, approval_status, version, signature, source, storage_status)
values (:'o1', '3730138646', 'Left Chest', 'embroidery', 5400, 'https://example.test/lc.png', 'unknown', 1, 'sig1', 'deconetwork', 'failed'),
       (:'o1', '3730138646', 'Right Sleeve (Long)', 'embroidery', 1200, null, 'unknown', 1, 'sig2', 'deconetwork', 'failed');

create temp table r (k text primary key, j jsonb);
insert into r select 'plan1', flow.drive_plan('[
 {"id":"d-ws","name":"worksheet-900001.pdf","md5":"w1","size":"60000","modified":"2026-11-19T10:00:00Z"},
 {"id":"d-lc","name":"order-900001-3730138646-Front-Left_Chest-EMB.dst","md5":"m1","size":"22464","modified":"2026-11-19T10:00:00Z","link":"https://drive.test/lc"},
 {"id":"d-rs","name":"order-900001-3730138646-_Right_Sleeve-Right_Sleeve_(Long)-EMB.dst","md5":"m2","size":"5280","modified":"2026-11-19T10:00:00Z"},
 {"id":"d-nolines","name":"order-900001-9999999999-Front-Left_Chest-EMB.dst","md5":"m3","size":"5000"},
 {"id":"d-noorder","name":"order-999999-1-Front-Left_Chest-EMB.dst","md5":"m4","size":"5000"},
 {"id":"d-other","name":"notes.txt","md5":"m5","size":"10"}]'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool and jsonb_array_length(j->'to_import') = 2 and (j->>'waiting')::int = 2 and (j->>'ignored')::int = 2 from r where k = 'plan1'), 'plan: 2 to fetch, 2 waiting, 2 ignored: ' || (select j::text from r where k = 'plan1'));
select pg_temp.assert((select status from flow.drive_files where drive_file_id = 'd-nolines') = 'waiting' and (select reason from flow.drive_files where drive_file_id = 'd-nolines') like '%line%', 'missing line waits');
select pg_temp.assert((select reason from flow.drive_files where drive_file_id = 'd-noorder') like '%not in Flow%', 'missing order waits');
select pg_temp.assert((select count(*) from public.ui_drive_files) = 3, 'the list shows 2 waiting + 1 unrecognised, not the worksheet');
select pg_temp.assert((select j->'to_import'->0->>'storage_path' from r where k = 'plan1') = 'drive/900001/3730138646/d-lc-order-900001-3730138646-Front-Left_Chest-EMB.dst', 'storage path is safe and unique');

-- ---- import: a new version on the existing row, unapproved, details kept ----
insert into r select 'imp1', flow.drive_import('d-lc', 'drive/900001/3730138646/d-lc-x.dst');
select pg_temp.assert((select (j->>'ok')::bool and j->>'outcome' = 'new_version' and (j->>'version')::int = 2 from r where k = 'imp1'), 'import makes v2: ' || (select j::text from r where k = 'imp1'));
select pg_temp.assert((select source = 'google_drive' and storage_status = 'stored' and approval_status = 'pending' and stitch_count = 5400 and thumbnail_url = 'https://example.test/lc.png' and file_format = 'dst' and area = 'Left Chest' and content_hash = 'm1' from flow.artwork_files where order_id = :'o1' and area = 'Left Chest' and is_current), 'new version is stored, unapproved, keeps stitches and preview');
select pg_temp.assert((select count(*) from flow.artwork_files where order_id = :'o1' and area = 'Left Chest') = 2 and (select count(*) from flow.artwork_files where order_id = :'o1' and area = 'Left Chest' and is_current) = 1, 'old version kept as history');
insert into r select 'imp2', flow.drive_import('d-rs', 'drive/900001/3730138646/d-rs-x.dst');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'imp2') and (select count(*) from flow.artwork_files where order_id = :'o1' and is_current and source = 'google_drive') = 2, 'second area imported');

-- ---- a second run does nothing; a changed file is a new version ----
insert into r select 'plan2', flow.drive_plan('[{"id":"d-lc","name":"order-900001-3730138646-Front-Left_Chest-EMB.dst","md5":"m1","size":"22464"}]'::jsonb);
select pg_temp.assert((select jsonb_array_length(j->'to_import') = 0 and (j->>'already_imported')::int = 1 from r where k = 'plan2'), 'unchanged file is not fetched again');
insert into r select 'plan3', flow.drive_plan('[{"id":"d-lc","name":"order-900001-3730138646-Front-Left_Chest-EMB.dst","md5":"m1b","size":"23000"}]'::jsonb);
select pg_temp.assert((select jsonb_array_length(j->'to_import') = 1 from r where k = 'plan3'), 'a changed file is fetched');
insert into r select 'imp3', flow.drive_import('d-lc', 'drive/900001/3730138646/d-lc-y.dst');
select pg_temp.assert((select (j->>'version')::int = 3 from r where k = 'imp3'), 'changed file becomes v3');
-- same content again (new Drive id, same checksum) does not make another version
insert into flow.drive_files (drive_file_id, name, md5, size_bytes, kind, deco_order_id, line_id, area, process_code, extension, status)
values ('d-lc2', 'order-900001-3730138646-Front-Left_Chest-EMB.dst', 'm1b', 23000, 'design', '900001', '3730138646', 'Left Chest', 'EMB', 'dst', 'ready');
insert into r select 'imp4', flow.drive_import('d-lc2', 'drive/900001/3730138646/d-lc2-y.dst');
select pg_temp.assert((select j->>'outcome' = 'unchanged' from r where k = 'imp4'), 'identical content is not a new version');

-- ---- the DecoNetwork sync must not replace a Drive version ----
select pg_temp.assert((flow.artwork_upsert(jsonb_build_array(jsonb_build_object('order_id', :'o1', 'deco_line_id', '3730138646', 'area', 'Left Chest', 'process', 'embroidery', 'stitch_count', 9999, 'production_url', 'https://x.test/f')), 'sync')->>'manual_kept')::int = 1, 'the DecoNetwork sync keeps the Drive version');
select pg_temp.assert((select version = 3 and source = 'google_drive' from flow.artwork_files where order_id = :'o1' and area = 'Left Chest' and is_current), 'still the Drive v3');

-- ---- an approved area that changes raises a warning ----
update flow.artwork_files set approval_status = 'approved' where order_id = :'o1' and area = 'Right Sleeve (Long)' and is_current;
insert into r select 'plan4', flow.drive_plan('[{"id":"d-rs","name":"order-900001-3730138646-_Right_Sleeve-Right_Sleeve_(Long)-EMB.dst","md5":"m2b","size":"6000"}]'::jsonb);
insert into r select 'imp5', flow.drive_import('d-rs', 'drive/900001/3730138646/d-rs-y.dst');
select pg_temp.assert((select count(*) from flow.notifications where title = 'Approved artwork changed on an order' and body like '%Right Sleeve (Long)%') >= 1, 'a changed approved area raises a notification');
select pg_temp.assert((select approval_status from flow.artwork_files where order_id = :'o1' and area = 'Right Sleeve (Long)' and is_current) = 'pending', 'and the new version needs approving again');

-- ---- hand uploads win ----
insert into flow.orders (deco_order_id, order_ref, customer_name, order_status, deco_status, stock_secured, total_units) values ('900002', '#900002', 'Manual Co', 'ready_for_production', 1, true, 5);
select id as o2 from flow.orders where deco_order_id = '900002' \gset
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, qty_required, decoration_methods) values ('DRW2', '111', :'o2', 'DR-SKU', 5, '{embroidery}');
insert into flow.artwork_files (order_id, deco_line_id, area, process, approval_status, version, signature, source, storage_status, storage_path, readable)
values (:'o2', '111', 'Back', 'embroidery', 'approved', 1, 'm', 'manual', 'manual', 'orders/900002/by-hand.dst', true);
insert into r select 'plan5', flow.drive_plan('[{"id":"d-man","name":"order-900002-111-Back-Back-EMB.dst","md5":"mm","size":"3000"}]'::jsonb);
insert into r select 'imp6', flow.drive_import('d-man', 'drive/900002/111/d-man.dst');
select pg_temp.assert((select j->>'outcome' = 'kept_manual' from r where k = 'imp6') and (select source = 'manual' and version = 1 from flow.artwork_files where order_id = :'o2' and is_current), 'a hand-uploaded version is kept');
select pg_temp.assert((select count(*) from public.ui_drive_files where drive_file_id = 'd-man') = 1, 'and the file shows on the list as not applied');

-- ---- a brand new area (the DecoNetwork sync had no row) ----
insert into r select 'plan6', flow.drive_plan('[{"id":"d-new","name":"order-900002-111-Front-Right_Chest-EMB.dst","md5":"n1","size":"4000"}]'::jsonb);
insert into r select 'imp7', flow.drive_import('d-new', 'drive/900002/111/d-new.dst');
select pg_temp.assert((select j->>'outcome' = 'new_area' from r where k = 'imp7') and (select version = 1 and process = 'embroidery' and approval_status = 'pending' from flow.artwork_files where order_id = :'o2' and area = 'Right Chest' and is_current), 'a new area is created at v1');

-- ---- too small, retries ----
insert into r select 'plan7', flow.drive_plan('[{"id":"d-tiny","name":"order-900002-111-Front-Left_Leg_(Long)-EMB.dst","md5":"t1","size":"20"}]'::jsonb);
insert into r select 'imp8', flow.drive_import('d-tiny', 'drive/900002/111/d-tiny.dst');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'imp8') and (select status from flow.drive_files where drive_file_id = 'd-tiny') = 'failed', 'an empty file fails');
insert into flow.drive_files (drive_file_id, name, md5, size_bytes, kind, deco_order_id, line_id, area, process_code, extension, status) values ('d-retry', 'order-900002-111-Front-Back-EMB.dst', 'q1', 5000, 'design', '900002', '111', 'Back', 'EMB', 'dst', 'ready');
do $$ declare i int; n int := 0; begin
  for i in 1..7 loop
    if jsonb_array_length(flow.drive_plan('[{"id":"d-retry","name":"order-900002-111-Front-Back-EMB.dst","md5":"q1","size":"5000"}]'::jsonb)->'to_import') > 0 then n := n + 1; end if;
  end loop;
  if n <> 5 then raise exception 'ASSERT FAILED: retried % times, expected 5', n; end if;
end $$;
select pg_temp.assert((select status from flow.drive_files where drive_file_id = 'd-retry') = 'failed', 'gives up after 5 tries and shows as failed');

-- ---- permissions ----
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_drive_plan(jsonb,int)', 'execute') and has_function_privilege('service_role', 'public.flow_drive_plan(jsonb,int)', 'execute'), 'only the service role can run the sync functions');
select pg_temp.assert(not has_table_privilege('anon', 'public.ui_drive_files', 'select') and has_table_privilege('authenticated', 'public.ui_drive_files', 'select'), 'the list is for signed-in staff only');
select 'drive_artwork_test passed' as result;
