-- Pre-production phase D: a person can check embroidery; a fully allocated order has a green stock light.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values
 ('PL1', '#PL1', 'Emb no art',   now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('PL2', '#PL2', 'Emb approved', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{embroidery}', true),
 ('PL3', '#PL3', 'No emb',       now() + interval '9 days', 'awaiting_stock', false, 1, 8, now() - interval '2 days', '{dtf}',        true),
 ('PL4', '#PL4', 'Inactive',     now() + interval '9 days', 'dispatched',     false, 9, 8, now() - interval '9 days', '{embroidery}', false);
select id as o1 from flow.orders where deco_order_id = 'PL1' \gset
select id as o2 from flow.orders where deco_order_id = 'PL2' \gset
select id as o3 from flow.orders where deco_order_id = 'PL3' \gset
select id as o4 from flow.orders where deco_order_id = 'PL4' \gset
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status)
  values (:'o2', 'L1', 'Left Chest', 'embroidery', 'dst', 'sig-pl2', 'stored', 'approved');

-- 1. embroidery: red with nothing recorded, green once every area is approved and stored (as before)
select pg_temp.assert((select embroidery = 'red' from public.ui_preproduction where order_ref = '#PL1'), 'no embroidery artwork recorded is red');
select pg_temp.assert((select embroidery = 'green' from public.ui_preproduction where order_ref = '#PL2'), 'every area approved and stored is green');
select pg_temp.assert((select embroidery = 'none' from public.ui_preproduction where order_ref = '#PL3'), 'an order with no embroidery is none');

-- 2. a person checks it
create temp table r (k text primary key, j jsonb);
insert into r select 'c1', flow.embroidery_check(:'o1', true, 'dashboard:tester', 'Checked on the production screen');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'c1'), 'the check is accepted: ' || (select j::text from r where k = 'c1'));
select pg_temp.assert((select embroidery = 'green' and embroidery_checked_by = 'dashboard:tester' and embroidery_checked_at is not null from public.ui_preproduction where order_ref = '#PL1'), 'a checked order is green, with who and when');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where entity = 'orders' and entity_id = :'o1' and action = 'embroidery_checked' and actor = 'dashboard:tester'), 'the check is audited');
insert into r select 'c2', flow.embroidery_check(:'o1', true, 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c2'), 'checking twice is refused');
insert into r select 'u1', flow.embroidery_check(:'o1', false, 'dashboard:tester', 'Customer changed the logo');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'u1'), 'the check can be undone');
select pg_temp.assert((select embroidery = 'red' and embroidery_checked_at is null and embroidery_checked_by is null from public.ui_preproduction where order_ref = '#PL1'), 'undoing puts the light back and clears who and when');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where entity_id = :'o1' and action = 'embroidery_unchecked'), 'the undo is audited');
insert into r select 'u2', flow.embroidery_check(:'o1', false, 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'u2'), 'undoing when not checked is refused');
insert into r select 'x1', flow.embroidery_check(:'o3', true, 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'x1') and (select j->>'error' from r where k = 'x1') = 'This order has no embroidery.', 'an order with no embroidery cannot be checked');
insert into r select 'x2', flow.embroidery_check(:'o4', true, 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'x2'), 'an inactive order cannot be checked');
insert into r select 'x3', flow.embroidery_check(gen_random_uuid(), true, 'dashboard:tester', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'x3'), 'an unknown order is refused');
insert into r select 'x4', flow.embroidery_check(:'o1', true, null, null);
select pg_temp.assert((select embroidery_checked_by = 'dashboard' from flow.orders where id = :'o1'), 'a missing actor falls back to dashboard');
select pg_temp.assert((select count(*) = 0 from flow.orders where embroidery_checked_at is not null and not ('embroidery' = any (decoration_methods))), 'only embroidery orders are ever checked');

-- 3. stock
update flow.orders set alloc_state = 'full' where id = :'o2';
update flow.orders set alloc_state = 'partial' where id = :'o1';
update flow.orders set alloc_state = 'none' where id = :'o3';
select pg_temp.assert((select stock = 'green' from public.ui_preproduction where order_ref = '#PL2'), 'fully allocated in Flow is green even if DecoNetwork has not said secured');
select pg_temp.assert((select stock = 'amber' from public.ui_preproduction where order_ref = '#PL1'), 'partly allocated is amber');
select pg_temp.assert((select stock = 'red' from public.ui_preproduction where order_ref = '#PL3'), 'nothing allocated and not secured is red');
update flow.orders set stock_secured = true where id = :'o3';
select pg_temp.assert((select stock = 'green' from public.ui_preproduction where order_ref = '#PL3'), 'DecoNetwork secured is still green');

-- 4. privileges
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_embroidery_check(uuid,boolean,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_embroidery_check(uuid,boolean,text,text)', 'execute') and has_function_privilege('service_role', 'public.flow_embroidery_check(uuid,boolean,text,text)', 'execute'), 'only the service role can run the check');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.embroidery_check(uuid,boolean,text,text)', 'execute'), 'the internal function is private');
select 'prepro_lights_test OK';
