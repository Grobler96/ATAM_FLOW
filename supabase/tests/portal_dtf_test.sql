-- Decorator portal, DTF prints: only my assigned third-party orders, nothing else, forward moves only, and a storage rule for just those files.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

-- two decorators; orders assigned to each, plus a defaulted one, an in-house one, an inactive one and one on an in-house DTF order ---------------
insert into flow.producers (code, name, address, contact_name, turnaround_days, can_direct_dispatch, capable_methods) values
  ('PDA', 'DTF Stitchers', '1 Mill St', 'Sam', 3, false, '{dtf}'), ('PDB', 'DTF Others', '2 Dock Rd', 'Nia', 3, false, '{dtf}');
select id as pda from flow.producers where code = 'PDA' \gset
select id as pdb from flow.producers where code = 'PDB' \gset
insert into flow.flow_settings (key, value, description) values ('third_party.default_producer', jsonb_build_object('producer_id', :'pda'), 'test default') on conflict (key) do update set value = excluded.value;
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, third_party_flag, producer_id, is_active) values
 ('DX1', '#DX1', 'Sam customer',   now() + interval '9 days', 'awaiting_stock', false, 1, 5, now() - interval '2 days', '{dtf}', true,  :'pda', true),
 ('DX2', '#DX2', 'Nia customer',   now() + interval '9 days', 'awaiting_stock', false, 1, 4, now() - interval '2 days', '{dtf}', true,  :'pdb', true),
 ('DX3', '#DX3', 'Default customer', now() + interval '9 days', 'awaiting_stock', false, 1, 3, now() - interval '2 days', '{dtf}', true, null, true),
 ('DX4', '#DX4', 'In house',       now() + interval '9 days', 'awaiting_stock', false, 1, 3, now() - interval '2 days', '{dtf}', false, :'pda', true),
 ('DX5', '#DX5', 'Inactive',       now() - interval '9 days', 'dispatched',     true,  9, 3, now() - interval '20 days', '{dtf}', true, :'pda', false),
 ('DX6', '#DX6', 'On a DTF order', now() + interval '9 days', 'awaiting_stock', false, 1, 3, now() - interval '2 days', '{dtf}', true,  :'pda', true);
select id as o1 from flow.orders where deco_order_id = 'DX1' \gset
select id as o2 from flow.orders where deco_order_id = 'DX2' \gset
select id as o3 from flow.orders where deco_order_id = 'DX3' \gset
select id as o4 from flow.orders where deco_order_id = 'DX4' \gset
select id as o5 from flow.orders where deco_order_id = 'DX5' \gset
select id as o6 from flow.orders where deco_order_id = 'DX6' \gset
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, qty_required, decoration_methods, product_name) values
 ('DXW1', 'M1', :'o1', 'S1', 5, '{dtf}', 'Pro polo'), ('DXW2', 'M2', :'o2', 'S2', 4, '{dtf}', 'Hoodie'), ('DXW3', 'M3', :'o3', 'S3', 3, '{dtf}', 'Tee'), ('DXW4', 'M4', :'o4', 'S4', 3, '{dtf}', 'Mug'),
 ('DXW5', 'M5', :'o5', 'S5', 3, '{dtf}', 'Cap'), ('DXW6', 'M6', :'o6', 'S6', 3, '{dtf}', 'Bag');
select flow.dtf_sync(:'o1', '[{"deco_line_id":"M1","area":"Back","qty":5},{"deco_line_id":"M1","area":"Left Chest","qty":5}]'::jsonb);
select flow.dtf_sync(:'o2', '[{"deco_line_id":"M2","area":"Back","qty":4}]'::jsonb);
select flow.dtf_sync(:'o3', '[{"deco_line_id":"M3","area":"Back","qty":3}]'::jsonb);
select flow.dtf_sync(:'o4', '[{"deco_line_id":"M4","area":"Back","qty":3}]'::jsonb);
select flow.dtf_sync(:'o5', '[{"deco_line_id":"M5","area":"Back","qty":3}]'::jsonb);
select flow.dtf_sync(:'o6', '[{"deco_line_id":"M6","area":"Back","qty":3}]'::jsonb);
insert into flow.artwork_files (order_id, deco_line_id, area, process, thumbnail_url, file_format, signature, storage_status, storage_path, content_hash, source_url) values
 (:'o1', 'M1', 'Back', 'dtf', 'https://example.test/a.png', 'png', 's1', 'stored', 'dx/o1/back/v1-logo-a.png', 'hash-A', 'https://secret.example/key=abc'),
 (:'o2', 'M2', 'Back', 'dtf', 'https://example.test/b.png', 'png', 's2', 'stored', 'dx/o2/back/v1-logo-b.png', 'hash-B', null),
 (:'o3', 'M3', 'Back', 'dtf', 'https://example.test/c.png', 'png', 's3', 'stored', 'dx/o3/back/v1-logo-c.png', 'hash-C', null),
 (:'o4', 'M4', 'Back', 'dtf', 'https://example.test/d.png', 'png', 's4', 'stored', 'dx/o4/back/v1-logo-d.png', 'hash-D', null),
 (:'o5', 'M5', 'Back', 'dtf', 'https://example.test/e.png', 'png', 's5', 'stored', 'dx/o5/back/v1-logo-e.png', 'hash-E', null),
 (:'o6', 'M6', 'Back', 'dtf', 'https://example.test/f.png', 'png', 's6', 'stored', 'dx/o6/back/v1-logo-f.png', 'hash-F', null);
-- DX6's placement is on an in-house DTF order (a batch), so it is never the decorator's
insert into flow.suppliers (code, name) values ('DXSUP', 'DX supplier') on conflict (code) do nothing;
insert into flow.dtf_batches (batch_ref, supplier_id) select 'DTF-TEST-1', id from flow.suppliers where code = 'DXSUP';
update flow.dtf_items set batch_id = (select id from flow.dtf_batches where batch_ref = 'DTF-TEST-1') where order_id = :'o6';

select (flow.pp_add_user(:'pda', 'sam@dtf.test', 'Sam', 'tester')->>'ok')::bool as u1 \gset
select (flow.pp_add_user(:'pdb', 'nia@dtf.test', 'Nia', 'tester')->>'ok')::bool as u2 \gset
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000a7', 'sam@dtf.test', now()), ('00000000-0000-0000-0000-0000000000a8', 'nia@dtf.test', now());
select pg_temp.assert(:'u1'::bool and :'u2'::bool, 'users added');

-- 1. Sam sees his own assigned third-party orders (including the defaulted one) and nothing else --------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
insert into r select 'sam', public.portal_dtf();
select pg_temp.assert((select (j->>'ok')::bool and (select count(*) from jsonb_array_elements(j->'items') e where e->>'order_ref' like '#DX%') = 3 from r where k = 'sam'), 'Sam sees three placements: his two on #DX1 and the defaulted #DX3: ' || (select j::text from r where k = 'sam'));
select pg_temp.assert((select bool_and((e->>'order_ref') in ('#DX1', '#DX3')) from r, jsonb_array_elements(j->'items') e where k = 'sam' and e->>'order_ref' like '#DX%'), 'only his own and the defaulted order');
select pg_temp.assert(not exists (select 1 from r, jsonb_array_elements(j->'items') e where k = 'sam' and (e->>'order_ref') in ('#DX2', '#DX4', '#DX5', '#DX6')), 'not another decorator''s, not an in-house order, not an inactive one, not one on an in-house DTF order');
select pg_temp.assert((select e->>'file' = 'dx/o1/back/v1-logo-a.png' and e->>'file_name' = 'v1-logo-a.png' and (e->>'qty')::int = 5 and e->>'status' = 'required' and e->>'design_key' = 'h:hash-A' and e->>'customer' = 'Sam customer' and e->>'product' = 'Pro polo' from r, jsonb_array_elements(j->'items') e where k = 'sam' and e->>'order_ref' = '#DX1' and e->>'area' = 'Back'), 'a placement shows its file, quantity, status, design and product');
select pg_temp.assert((select e->>'file' is null and e->>'design_key' is null from r, jsonb_array_elements(j->'items') e where k = 'sam' and e->>'order_ref' = '#DX1' and e->>'area' = 'Left Chest'), 'a placement with no file yet shows none, not a broken link');
select pg_temp.assert(not ((select jsonb_agg(e)::text from r, jsonb_array_elements(j->'items') e where k = 'sam' and e->>'order_ref' like '#DX%') ~* '(cost|margin|price|source_url|secret|artwork_id|address|email)'), 'no prices, internal links, addresses or emails');
reset role;

-- 2. Nia sees only hers ----------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a8');
set role authenticated;
insert into r select 'nia', public.portal_dtf();
select pg_temp.assert((select count(*) = 1 and bool_and(e->>'order_ref' = '#DX2') from r, jsonb_array_elements(j->'items') e where k = 'nia' and e->>'order_ref' like '#DX%'), 'Nia sees only #DX2');
reset role;

-- 3. Moving prints forward: own prints only, forward only, audited --------------------------------------------------------------------------------
select id as sam_back from flow.dtf_items where order_id = :'o1' and area = 'Back' \gset
select id as sam_chest from flow.dtf_items where order_id = :'o1' and area = 'Left Chest' \gset
select id as nia_back from flow.dtf_items where order_id = :'o2' \gset
select id as in_house_item from flow.dtf_items where order_id = :'o4' \gset
select id as batch_item from flow.dtf_items where order_id = :'o6' \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
insert into r select 'start', public.portal_dtf_start(array[:'sam_back', :'sam_chest', :'nia_back', :'in_house_item', :'batch_item']::uuid[]);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'changed')::int = 2 and (j->>'requested')::int = 5 from r where k = 'start'), 'only his own two were started, the other three were ignored: ' || (select j::text from r where k = 'start'));
reset role;
select pg_temp.assert((select status = 'in_progress' and status_by = 'producer:DTF Stitchers' and status_at is not null from flow.dtf_items where id = :'sam_back'), 'started: in progress, by him, with a time');
select pg_temp.assert((select status = 'required' from flow.dtf_items where id in (:'nia_back', :'in_house_item', :'batch_item') group by status), 'the other decorator''s, the in-house and the batched placements were not touched');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where action = 'portal_dtf_start' and actor = 'producer:DTF Stitchers' and (after->>'count')::int = 2), 'the change is audited as the decorator');
select pg_temp.assert((select prints = 'amber' from public.ui_preproduction where order_ref = '#DX1'), 'staff see the order go amber');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
insert into r select 'again', public.portal_dtf_start(array[:'sam_back']::uuid[]);
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like 'Nothing was changed%' from r where k = 'again'), 'starting what is already started changes nothing, in plain words');
insert into r select 'done', public.portal_dtf_done(array[:'sam_back', :'sam_chest']::uuid[]);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'changed')::int = 2 from r where k = 'done'), 'both can be marked produced, even one that was never marked started');
insert into r select 'back', public.portal_dtf_start(array[:'sam_back']::uuid[]);
select pg_temp.assert((select not (j->>'ok')::bool from r where k = 'back'), 'a produced print cannot be moved back');
select pg_temp.assert(not (public.portal_dtf_start(null)->>'ok')::bool and not (public.portal_dtf_done('{}')->>'ok')::bool, 'choosing nothing is refused');
reset role;
select pg_temp.assert((select prints = 'amber' from public.ui_preproduction where order_ref = '#DX1') = false and (select prints = 'green' from public.ui_preproduction where order_ref = '#DX1'), 'staff see the order go green once every placement is produced');
-- finished prints stay on his list for 14 days, then drop off
update flow.dtf_items set status_at = now() - interval '15 days' where id = :'sam_chest';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
select pg_temp.assert((select count(*) = 2 from jsonb_array_elements(public.portal_dtf()->'items') e where e->>'order_ref' like '#DX%'), 'a print finished more than 14 days ago drops off his list');
reset role;

-- 4. The storage rule -----------------------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
select pg_temp.assert(flow.portal_can_read_dtf('dx/o1/back/v1-logo-a.png') and flow.portal_can_read_dtf('dx/o3/back/v1-logo-c.png'), 'Sam can fetch the files of his own and his defaulted order');
select pg_temp.assert(not flow.portal_can_read_dtf('dx/o2/back/v1-logo-b.png') and not flow.portal_can_read_dtf('dx/o4/back/v1-logo-d.png') and not flow.portal_can_read_dtf('dx/o5/back/v1-logo-e.png') and not flow.portal_can_read_dtf('dx/o6/back/v1-logo-f.png'), 'not another decorator''s, not an in-house order''s, not an inactive order''s, not one on an in-house DTF order');
select pg_temp.assert(not flow.portal_can_read_dtf('anything/else.pdf') and not flow.portal_can_read_dtf(null), 'nothing else in the bucket');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a8');
set role authenticated;
select public.portal_whoami();
select pg_temp.assert(flow.portal_can_read_dtf('dx/o2/back/v1-logo-b.png') and not flow.portal_can_read_dtf('dx/o1/back/v1-logo-a.png'), 'Nia can fetch only her own file');
reset role;
-- an order that stops being third party disappears at once
update flow.orders set third_party_flag = false, scope_override = 'in_house' where id = :'o1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
select pg_temp.assert((select count(*) = 1 from jsonb_array_elements(public.portal_dtf()->'items') e where e->>'order_ref' like '#DX%') and not flow.portal_can_read_dtf('dx/o1/back/v1-logo-a.png'), 'an order made in-house disappears from the decorator and its file closes');
reset role;
-- a switched-off decorator gets nothing
select (flow.pp_set_user_active((select id from flow.producer_users where lower(email) = 'sam@dtf.test'), false, 'Testing a switch-off', 'tester')->>'ok')::bool as off \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a7');
set role authenticated;
select pg_temp.assert(not flow.portal_can_read_dtf('dx/o3/back/v1-logo-c.png') and pg_temp.try('select public.portal_dtf()') like '%access%', 'a switched-off login can read and see nothing');
reset role;

-- 5. nobody signed in, and the internals are closed -----------------------------------------------------------------------------------------------
select pg_temp.as_user('');
select pg_temp.assert(not flow.portal_can_read_dtf('dx/o3/back/v1-logo-c.png'), 'a visitor with no login can read nothing');
select pg_temp.assert(not has_function_privilege('anon', 'public.portal_dtf()', 'execute') and not has_function_privilege('anon', 'public.portal_dtf_start(uuid[])', 'execute') and not has_function_privilege('anon', 'public.portal_dtf_done(uuid[])', 'execute') and not has_function_privilege('anon', 'flow.portal_can_read_dtf(text)', 'execute'), 'anonymous visitors can call none of it');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.portal_dtf_set(uuid[],text)', 'execute') and not has_function_privilege('authenticated', 'flow.dtf_decorator(flow.orders)', 'execute'), 'the internals are not callable directly');
\echo portal_dtf_test OK
