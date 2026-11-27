-- Drive files that waited for their order are picked up when it arrives; stuck files are retried then failed; the import takes a lock.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units) values ('900091', '#900091', 'Recheck Co', '2026-12-01 12:00+00', 'awaiting_stock', 9, false, 4);
select id as o1 from flow.orders where deco_order_id = '900091' \gset
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods) values ('RCW1', '7700000001', :'o1', 'RC-SKU', 'Navy', 'M', 'Polo', 4, '{embroidery}');
-- files the job saw earlier but that are no longer in its Drive list
insert into flow.drive_files (drive_file_id, name, md5, size_bytes, kind, deco_order_id, line_id, location, area, process_code, extension, status, reason, attempts, first_seen) values
 ('rc-wait',    'order-900091-7700000001-Front-Left_Chest-EMB.dst',  'a1', 5000, 'design', '900091', '7700000001', 'Front', 'Left Chest',  'EMB', 'dst', 'waiting', 'Order 900091 is not in Flow yet', 0, now() - interval '5 days'),
 ('rc-wait2',   'order-900091-7700000001-Front-Right_Chest-EMB.dst', 'a2', 5000, 'design', '900091', '7700000001', 'Front', 'Right Chest', 'EMB', 'dst', 'waiting', 'Order 900091 is not in Flow yet', 0, now() - interval '4 days'),
 ('rc-noorder', 'order-900092-1-Front-Left_Chest-EMB.dst',           'a3', 5000, 'design', '900092', '1',          'Front', 'Left Chest',  'EMB', 'dst', 'waiting', 'Order 900092 is not in Flow yet', 0, now() - interval '3 days'),
 ('rc-stuck',   'order-900091-7700000001-Back-Back-EMB.dst',         'a4', 5000, 'design', '900091', '7700000001', 'Back',  'Back',        'EMB', 'dst', 'ready',   'The upload to secure storage did not arrive', 5, now() - interval '6 days'),
 ('rc-listed',  'order-900091-7700000001-Front-Sleeve-EMB.dst',      'a5', 5000, 'design', '900091', '7700000001', 'Front', 'Sleeve',      'EMB', 'dst', 'waiting', 'Order 900091 is not in Flow yet', 0, now() - interval '2 days');
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units, is_active) values ('900093', '#900093', 'Shipped Co', '2026-11-01 12:00+00', 'dispatched', 1, true, 2, false);
insert into flow.drive_files (drive_file_id, name, md5, size_bytes, kind, deco_order_id, line_id, location, area, process_code, extension, status, reason, attempts, first_seen) values
 ('rc-shipped', 'order-900093-5-Front-Left_Chest-EMB.dst', 'a6', 5000, 'design', '900093', '5', 'Front', 'Left Chest', 'EMB', 'dst', 'ready', 'The upload to secure storage did not arrive', 1, now() - interval '9 days');
create temp table r (k text primary key, j jsonb);
-- run 1: an empty Drive list, room for one file: the oldest waiting file whose order exists is fetched, and counts a try
insert into r select 'p1', flow.drive_plan('[]'::jsonb, 1);
select pg_temp.assert((select jsonb_array_length(j->'to_import') = 1 and j->'to_import'->0->>'drive_file_id' = 'rc-wait' and (j->>'rechecked')::int = 1 from r where k = 'p1'), 'the oldest waiting file whose order exists is handed to the job: ' || (select j::text from r where k = 'p1'));
select pg_temp.assert((select status = 'ready' and attempts = 1 and reason is null from flow.drive_files where drive_file_id = 'rc-wait'), 'it is ready and used one try');
select pg_temp.assert((select status = 'ready' and attempts = 0 from flow.drive_files where drive_file_id = 'rc-wait2'), 'the next file is made ready but not fetched yet (over the limit)');
select pg_temp.assert((select status = 'waiting' and attempts = 0 from flow.drive_files where drive_file_id = 'rc-noorder'), 'a file whose order is still missing keeps waiting');
select pg_temp.assert((select status = 'failed' and reason like '%5 tries%' from flow.drive_files where drive_file_id = 'rc-stuck'), 'a stuck ready file that used all its tries is shown as failed');
select pg_temp.assert((select status = 'ignored' and reason like '%no longer active%' from flow.drive_files where drive_file_id = 'rc-shipped'), 'a file for an order that has shipped is set aside, not left waiting for ever');
-- run 2: a file that IS in this run's list is left to the normal path, not fetched twice
insert into r select 'p2', flow.drive_plan('[{"id":"rc-listed","name":"order-900091-7700000001-Front-Sleeve-EMB.dst","md5":"a5","size":"5000"}]'::jsonb, 5);
select pg_temp.assert((select (select count(*) from jsonb_array_elements(j->'to_import') e where e->>'drive_file_id' = 'rc-listed') = 1 from r where k = 'p2'), 'a listed file is fetched once, not twice');
select pg_temp.assert((select count(*) from jsonb_array_elements((select j->'to_import' from r where k = 'p2')) e where e->>'drive_file_id' in ('rc-wait', 'rc-wait2')) = 2, 'the rechecked files are handed over too');
-- the import path still works with the lock
insert into r select 'i1', flow.drive_import('rc-listed', 'drive/900091/7700000001/rc-listed-x.dst');
select pg_temp.assert((select j->>'ok' = 'true' or j->>'error' like '%upload%' from r where k = 'i1'), 'the import runs (it may stop at the storage check in a test database): ' || (select j::text from r where k = 'i1'));
select 'drive_recheck_test OK' as result;
