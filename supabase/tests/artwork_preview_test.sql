-- The staff artwork view shows DecoNetwork's preview picture and still hides the source links; the sync's import keeps the preview and the stitch count.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units)
values ('APV1', '#APV1', 'Preview Co', now() + interval '9 days', 'ready_for_production', true, 1, 2);
select flow.artwork_upsert(jsonb_build_array(
  jsonb_build_object('deco_order_id', 'APV1', 'deco_line_id', 'LN1', 'area', 'Left Chest', 'process', 'embroidery', 'stitch_count', 4832, 'thumbnail_url', 'https://deco.example/preview-a.png?1'),
  jsonb_build_object('deco_order_id', 'APV1', 'deco_line_id', 'LN1', 'area', 'Back', 'process', 'dtf', 'thumbnail_url', 'https://deco.example/preview-b.png?1')), 'deconetwork sync');

select pg_temp.assert((select count(*) from public.ui_artwork_files where order_ref = '#APV1' and thumbnail_url like 'https://deco.example/preview-%') = 2, 'the view shows the preview picture for each area');
select pg_temp.assert((select stitch_count from public.ui_artwork_files where order_ref = '#APV1' and area = 'Left Chest') = 4832, 'the stitch count comes through');
select pg_temp.assert((select bool_and(storage_status = 'failed' and storage_path is null) from public.ui_artwork_files where order_ref = '#APV1'), 'with no file link the area shows as having no stored file (it is not faked)');
select pg_temp.assert(not ((select string_agg(column_name, ',') from information_schema.columns where table_schema = 'public' and table_name = 'ui_artwork_files') ~ '(source_url|production_url|editable_url)'), 'the view still hides the source links');

-- a changed preview picture address (DecoNetwork appends a timestamp) updates the picture without making a new version
select flow.artwork_upsert(jsonb_build_array(
  jsonb_build_object('deco_order_id', 'APV1', 'deco_line_id', 'LN1', 'area', 'Left Chest', 'process', 'embroidery', 'stitch_count', 4832, 'thumbnail_url', 'https://deco.example/preview-a.png?2')), 'deconetwork sync');
select pg_temp.assert((select count(*) from public.ui_artwork_files where order_ref = '#APV1' and area = 'Left Chest') = 1 and (select thumbnail_url from public.ui_artwork_files where order_ref = '#APV1' and area = 'Left Chest') like '%?2', 'a new preview address updates the picture and does not add a version');

-- a hand-uploaded file is never overwritten by the sync
select flow.artwork_manual_replace((select id from flow.orders where order_ref = '#APV1'), 'LN1', 'Back', 'orders/APV1/back/v2-file.png', 'tester', 'uploaded by hand', '{}'::jsonb);
select flow.artwork_upsert(jsonb_build_array(
  jsonb_build_object('deco_order_id', 'APV1', 'deco_line_id', 'LN1', 'area', 'Back', 'process', 'dtf', 'thumbnail_url', 'https://deco.example/preview-b.png?3')), 'deconetwork sync');
select pg_temp.assert((select source from public.ui_artwork_files where order_ref = '#APV1' and area = 'Back' and is_current) = 'manual', 'a hand-uploaded file is kept when the sync runs again');
