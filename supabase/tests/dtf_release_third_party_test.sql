-- Switching an order to third party frees its placements from a draft in-house DTF order, and leaves a sent one alone.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, third_party_flag) values
 ('RL1', '#RL1', 'Switches', now() + interval '9 days', 'awaiting_stock', false, 1, 5, '{dtf}', false),
 ('RL2', '#RL2', 'Stays in house', now() + interval '9 days', 'awaiting_stock', false, 1, 4, '{dtf}', false),
 ('RL3', '#RL3', 'Already sent', now() + interval '9 days', 'awaiting_stock', false, 1, 3, '{dtf}', false);
select id as o1 from flow.orders where deco_order_id = 'RL1' \gset
select id as o2 from flow.orders where deco_order_id = 'RL2' \gset
select id as o3 from flow.orders where deco_order_id = 'RL3' \gset
select flow.dtf_sync(:'o1', '[{"deco_line_id":"M1","area":"Back","qty":5}]'::jsonb);
select flow.dtf_sync(:'o2', '[{"deco_line_id":"M2","area":"Back","qty":4}]'::jsonb);
select flow.dtf_sync(:'o3', '[{"deco_line_id":"M3","area":"Back","qty":3}]'::jsonb);
insert into flow.artwork_files (order_id, deco_line_id, area, process, thumbnail_url, file_format, signature, storage_status, storage_path, content_hash) values
 (:'o1', 'M1', 'Back', 'dtf', 'https://example.test/a.png', 'png', 'r1', 'stored', 'rl/o1/back/v1-a.png', 'hash-RA'),
 (:'o2', 'M2', 'Back', 'dtf', 'https://example.test/b.png', 'png', 'r2', 'stored', 'rl/o2/back/v1-b.png', 'hash-RB'),
 (:'o3', 'M3', 'Back', 'dtf', 'https://example.test/c.png', 'png', 'r3', 'stored', 'rl/o3/back/v1-c.png', 'hash-RC');
create temp table r (k text primary key, j jsonb);
-- a draft DTF order holding RL1 and RL2, and a separate DTF order that has been sent holding RL3
insert into r select 'b1', flow.dtf_build_order(array[:'o1', :'o2']::uuid[], jsonb_build_object('rl/o1/back/v1-a.png', 'https://example.test/s/a', 'rl/o2/back/v1-b.png', 'https://example.test/s/b'), 'tester', 'draft');
select (j->>'batch_id')::uuid as b1 from r where k = 'b1' \gset
insert into r select 'b2', flow.dtf_build_order(array[:'o3']::uuid[], jsonb_build_object('rl/o3/back/v1-c.png', 'https://example.test/s/c'), 'tester', 'sent');
select (j->>'batch_id')::uuid as b2 from r where k = 'b2' \gset
update flow.dtf_batches set status = 'ordered', ordered_at = now() where id = :'b2';
select pg_temp.assert((select count(*) = 2 and bool_and(batch_id = :'b1') from flow.dtf_items where order_id in (:'o1', :'o2')), 'RL1 and RL2 start on the draft DTF order');

-- changing something that does not change the scope does nothing
update flow.orders set customer_name = 'Switches (renamed)' where id = :'o1';
select pg_temp.assert((select batch_id = :'b1' from flow.dtf_items where order_id = :'o1'), 'an unrelated change leaves the placement alone');
-- switching to third party frees the placements and cancels the draft DTF order and its email
update flow.orders set third_party_flag = true where id = :'o1';
select pg_temp.assert((select batch_id is null from flow.dtf_items where order_id = :'o1'), 'RL1 is free once it is third party');
select pg_temp.assert((select batch_id is null from flow.dtf_items where order_id = :'o2'), 'RL2, on the same DTF order, is freed too so it can go on a new one');
select pg_temp.assert((select status = 'cancelled' from flow.dtf_batches where id = :'b1'), 'the draft DTF order is cancelled');
select pg_temp.assert((select c.status = 'cancelled' from flow.communications c join flow.dtf_batches b on b.comm_id = c.id where b.id = :'b1'), 'and its email is cancelled');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where action = 'dtf_order_cancelled' and entity_id = :'b1'::text and reason like '%#RL1%'), 'the cancellation is in the audit log with the reason');
-- RL1 now shows to a team member on the third-party page; RL2 can be ordered again
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000087a1', 'manager') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000087a1', false);
select pg_temp.assert((select count(*) = 1 from public.ui_dtf_third_party where order_ref = '#RL1'), 'RL1 now shows on the 3PD DTF prints page');
select set_config('request.jwt.claim.sub', '', false);
-- a DTF order that has already been sent is left alone
update flow.orders set scope_override = 'third_party' where id = :'o3';
select pg_temp.assert((select batch_id = :'b2' from flow.dtf_items where order_id = :'o3') and (select status = 'ordered' from flow.dtf_batches where id = :'b2'), 'a DTF order that was already sent is not touched');
-- switching back and forth again does nothing more
update flow.orders set third_party_flag = false where id = :'o1';
update flow.orders set third_party_flag = true where id = :'o1';
select pg_temp.assert((select count(*) = 1 from flow.audit_log where action = 'dtf_order_cancelled' and entity_id = :'b1'::text), 'nothing more is cancelled the second time');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.dtf_release_third_party()', 'execute') and not has_function_privilege('anon', 'flow.dtf_release_third_party()', 'execute'), 'the trigger function cannot be called by a person');
select 'dtf_release_third_party_test OK' as result;
