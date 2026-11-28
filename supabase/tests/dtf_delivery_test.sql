-- Choosing next day delivery on a DTF order adds one bold line to the email to Super Print.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, third_party_flag) values
 ('DL1', '#DL1', 'Delivery', now() + interval '9 days', 'awaiting_stock', false, 1, 3, '{dtf}', false),
 ('DL2', '#DL2', 'Delivery', now() + interval '9 days', 'awaiting_stock', false, 1, 3, '{dtf}', false),
 ('DL3', '#DL3', 'Delivery', now() + interval '9 days', 'awaiting_stock', false, 1, 3, '{dtf}', false);
select id as o1 from flow.orders where deco_order_id = 'DL1' \gset
select id as o2 from flow.orders where deco_order_id = 'DL2' \gset
select id as o3 from flow.orders where deco_order_id = 'DL3' \gset
select flow.dtf_sync(:'o1', '[{"deco_line_id":"N1","area":"Back","qty":1}]'::jsonb);
select flow.dtf_sync(:'o2', '[{"deco_line_id":"N2","area":"Back","qty":1}]'::jsonb);
select flow.dtf_sync(:'o3', '[{"deco_line_id":"N3","area":"Back","qty":1}]'::jsonb);
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, storage_path, content_hash) values
 (:'o1', 'N1', 'Back', 'dtf', 'png', 'd1', 'stored', 'dl/1.png', 'hash-D1'),
 (:'o2', 'N2', 'Back', 'dtf', 'png', 'd2', 'stored', 'dl/2.png', 'hash-D2'),
 (:'o3', 'N3', 'Back', 'dtf', 'png', 'd3', 'stored', 'dl/3.png', 'hash-D3');
create temp table r (k text primary key, j jsonb);
-- standard (no choice): no extra line
insert into r select 's', flow.dtf_build_order(array[:'o1']::uuid[], '{"dl/1.png":"https://example.test/1"}'::jsonb, 'tester');
-- next day
insert into r select 'n', flow.dtf_build_order(array[:'o2']::uuid[], '{"dl/2.png":"https://example.test/2"}'::jsonb, 'tester', null, 'next_day_pre12');
-- explicitly standard
insert into r select 'x', flow.dtf_build_order(array[:'o3']::uuid[], '{"dl/3.png":"https://example.test/3"}'::jsonb, 'tester', 'a note', 'standard');
select pg_temp.assert((select bool_and((j->>'ok')::bool) from r), 'all three built: ' || (select string_agg(j::text, ' ') from r));
select pg_temp.assert((select delivery from flow.dtf_batches where id = (select (j->>'batch_id')::uuid from r where k = 's')) = 'standard', 'default is standard');
select pg_temp.assert((select delivery from flow.dtf_batches where id = (select (j->>'batch_id')::uuid from r where k = 'n')) = 'next_day_pre12', 'next day is stored');
select c.body_text as nt, c.body_html as nh from flow.communications c join flow.dtf_batches b on b.comm_id = c.id where b.id = (select (j->>'batch_id')::uuid from r where k = 'n') \gset
select c.body_text as st, c.body_html as sh from flow.communications c join flow.dtf_batches b on b.comm_id = c.id where b.id = (select (j->>'batch_id')::uuid from r where k = 's') \gset
select pg_temp.assert(:'nh' like '%<p><b>Please can we have this Tomorrow on Pre 12 next day delivery.</b></p>%', 'the html has the line in bold');
select pg_temp.assert(:'nt' like '%Please can we have this Tomorrow on Pre 12 next day delivery.%', 'the plain text has the line');
select pg_temp.assert(:'nh' like 'Hi Supa print%' or :'nh' like '<p>Hi Supa print,</p>%', 'still opens the same way');
select pg_temp.assert(:'nh' like '%Atam Support Team%' and :'nh' like '%<table%', 'the rest of the email is unchanged');
select pg_temp.assert(:'sh' not like '%Pre 12%' and :'st' not like '%Pre 12%', 'a standard order has no extra line');
-- a bad choice is refused and nothing is created
select pg_temp.assert(not (flow.dtf_build_order(array[:'o1']::uuid[], '{}'::jsonb, 'tester', null, 'sometime')->>'ok')::bool, 'a made-up delivery choice is refused');
-- the view carries what the page needs to approve the email itself
select pg_temp.assert((select count(*) from public.ui_dtf_batches where comm_id is not null and delivery in ('standard', 'next_day_pre12') and id in (select (j->>'batch_id')::uuid from r)) = 3, 'ui_dtf_batches shows comm_id and delivery');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_dtf_build_order(uuid[],jsonb,text,text,text)', 'execute'), 'logged-in users cannot call the build');
select 'dtf_delivery_test OK' as result;
