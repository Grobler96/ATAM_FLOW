-- Pre-production phase B: the in-house DTF order to Super Print, its email, and receiving the prints.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

-- fixtures: two in-house orders sharing one design, a third-party order, an order with no file yet ---------------------------------
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, third_party_flag) values
 ('DB1', '#DB1', 'Inhouse one', now() + interval '9 days', 'awaiting_stock', false, 1, 5, now() - interval '2 days', '{dtf}', false),
 ('DB2', '#DB2', 'Inhouse two', now() + interval '9 days', 'awaiting_stock', false, 1, 4, now() - interval '2 days', '{dtf}', false),
 ('DB3', '#DB3', 'Third party', now() + interval '9 days', 'awaiting_stock', false, 1, 3, now() - interval '2 days', '{dtf}', true),
 ('DB4', '#DB4', 'No file',     now() + interval '9 days', 'awaiting_stock', false, 1, 2, now() - interval '2 days', '{dtf}', false);
select id as o1 from flow.orders where deco_order_id = 'DB1' \gset
select id as o2 from flow.orders where deco_order_id = 'DB2' \gset
select id as o3 from flow.orders where deco_order_id = 'DB3' \gset
select id as o4 from flow.orders where deco_order_id = 'DB4' \gset
select flow.dtf_sync(:'o1', '[{"deco_line_id":"L1","area":"Back","qty":3},{"deco_line_id":"L2","area":"Left Chest","qty":2}]'::jsonb);
select flow.dtf_sync(:'o2', '[{"deco_line_id":"L3","area":"Back","qty":4}]'::jsonb);
select flow.dtf_sync(:'o3', '[{"deco_line_id":"L4","area":"Back","qty":3}]'::jsonb);
select flow.dtf_sync(:'o4', '[{"deco_line_id":"L5","area":"Back","qty":2}]'::jsonb);
insert into flow.artwork_files (order_id, deco_line_id, area, process, thumbnail_url, file_format, signature, storage_status, storage_path, content_hash) values
 (:'o1', 'L1', 'Back', 'dtf', 'https://example.test/a.png', 'png', 's1', 'stored', 'orders/DB1/back/v1-logo-a.png', 'hash-A'),
 (:'o1', 'L2', 'Left Chest', 'dtf', 'https://example.test/b.png', 'png', 's2', 'stored', 'orders/DB1/left-chest/v1-logo-b.png', 'hash-B'),
 (:'o2', 'L3', 'Back', 'dtf', 'https://example.test/a.png', 'png', 's3', 'stored', 'orders/DB2/back/v1-logo-a.png', 'hash-A'),
 (:'o3', 'L4', 'Back', 'dtf', 'https://example.test/c.png', 'png', 's4', 'stored', 'orders/DB3/back/v1-logo-c.png', 'hash-C');
select pg_temp.assert(exists (select 1 from flow.suppliers where code = 'SUPERPRINT' and name = 'Super Print'), 'Super Print is a supplier');

-- the plan: what goes on the order, what is left out and why ----------------------------------------------------------------------
insert into r select 'plan', flow.dtf_plan(array[:'o1', :'o2', :'o3', :'o4']::uuid[]);
select pg_temp.assert(jsonb_array_length(j->'included') = 3, 'three placements can be ordered: ' || j::text) from r where k = 'plan';
select pg_temp.assert((select count(*) = 2 from r, jsonb_array_elements(r.j->'skipped') s where r.k = 'plan' and s->>'reason' in ('Third-party order: the decorator orders their own DTFs', 'No file yet')), 'the third-party order and the placement with no file are left out, with the reason');
select pg_temp.assert((select (d->>'qty')::int = 7 and jsonb_array_length(d->'orders') = 2 from r, jsonb_array_elements(j->'designs') d where k = 'plan' and d->>'design_key' = 'h:hash-A'), 'the same design on two orders is one line with its total (3 + 4 = 7)');
select pg_temp.assert((select jsonb_array_length(j->'designs') = 2 from r where k = 'plan'), 'two designs in all');
select pg_temp.assert(not (flow.dtf_plan(null)->>'ok')::bool and not (flow.dtf_plan('{}')->>'ok')::bool, 'choosing nothing is refused');

-- building it: no email address yet, so the email waits as a draft ---------------------------------------------------------------------
insert into r select 'build', flow.dtf_build_order(array[:'o1', :'o2', :'o3', :'o4']::uuid[], jsonb_build_object('orders/DB1/back/v1-logo-a.png', 'https://example.test/sign/a?token=1', 'orders/DB1/left-chest/v1-logo-b.png', 'https://example.test/sign/b?token=2'), 'tester', 'First DTF order');
select pg_temp.assert((select (j->>'ok')::bool and j->>'batch_ref' like 'DTF-%' and (j->>'placements')::int = 3 and (j->>'designs')::int = 2 and (j->>'prints')::int = 9 and (j->>'no_recipient')::bool and j->>'comm_status' = 'draft' and (j->>'links_missing')::int = 0 from r where k = 'build'), 'built: ' || (select j::text from r where k = 'build'));
select id as b1 from flow.dtf_batches order by created_at desc limit 1 \gset
select pg_temp.assert((select count(*) = 3 and bool_and(status = 'required') from flow.dtf_items where batch_id = :'b1'), 'the three placements are on the order, still red until it is sent');
select pg_temp.assert((select status = 'draft' and note = 'First DTF order' from flow.dtf_batches where id = :'b1'), 'the DTF order is a draft');
select pg_temp.assert((select c.status = 'draft' and c.kind = 'other' and c.entity_type = 'dtf_batch' and c.requires_review and c.subject like 'DTF order DTF-%' and c.body_html like '%<img src="https://example.test/a.png"%' and c.body_html like '%<b>7</b>%' and c.body_html like '%https://example.test/sign/a?token=1%' and c.body_text like '%Total: 9 prints%' from flow.communications c join flow.dtf_batches b on b.comm_id = c.id where b.id = :'b1'), 'the email lists each design with its picture, quantity and download link, and waits for review');
select pg_temp.assert((select (flow.comm_approve(b.comm_id, 'tester')->>'ok')::bool = false from flow.dtf_batches b where b.id = :'b1'), 'with no address for Super Print the email cannot be approved');
-- nothing left to order on the same orders
insert into r select 'again', flow.dtf_build_order(array[:'o1', :'o2']::uuid[], '{}'::jsonb, 'tester', null);
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like 'Nothing can go%' from r where k = 'again'), 'the same placements cannot go on a second order');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_dtf_build_order(uuid[],jsonb,text,text)', 'execute') and has_function_privilege('service_role', 'public.flow_dtf_build_order(uuid[],jsonb,text,text)', 'execute'), 'only n8n can build one');
-- receiving before it is sent is refused
select pg_temp.assert(not (flow.dtf_receive(:'b1', null, 'tester', null)->>'ok')::bool, 'nothing can be received before the email has been sent');

-- once Super Print has an address: approve, send, then the prints are in progress -------------------------------------------------------
update flow.suppliers set email = 'orders@superprint.test' where code = 'SUPERPRINT';
update flow.order_tags set quantity = quantity where false;
insert into r select 'build2', flow.dtf_build_order(array[:'o4']::uuid[], '{}'::jsonb, 'tester', null);
select pg_temp.assert((select not (j->>'ok')::bool from r where k = 'build2'), 'a placement with no file cannot be ordered');
-- a fresh order with an address: pending review, then approved and sent
update flow.dtf_items set batch_id = null, status = 'required' where batch_id = :'b1';
update flow.dtf_batches set status = 'cancelled' where id = :'b1';
insert into r select 'build3', flow.dtf_build_order(array[:'o1', :'o2']::uuid[], jsonb_build_object('orders/DB1/back/v1-logo-a.png', 'https://example.test/sign/a?token=3', 'orders/DB1/left-chest/v1-logo-b.png', 'https://example.test/sign/b?token=4'), 'tester', null);
select id as b2 from flow.dtf_batches where batch_ref = (select j->>'batch_ref' from r where k = 'build3') \gset
select pg_temp.assert((select not (j->>'no_recipient')::bool and j->>'comm_status' = 'pending_review' from r where k = 'build3'), 'with an address the email goes to review');
select pg_temp.assert((select (flow.comm_approve(c.id, 'tester')->>'ok')::bool from flow.dtf_batches b join flow.communications c on c.id = b.comm_id where b.id = :'b2'), 'it can be approved');
select pg_temp.assert((select status = 'draft' from flow.dtf_batches where id = :'b2'), 'approving does not mark the prints as ordered: only sending does');
select pg_temp.assert((select (flow.comm_mark_sent(c.id, 'test')->>'ok')::bool from flow.dtf_batches b join flow.communications c on c.id = b.comm_id where b.id = :'b2'), 'the sender marks it sent');
select pg_temp.assert((select status = 'ordered' and ordered_at is not null from flow.dtf_batches where id = :'b2'), 'the DTF order is ordered');
select pg_temp.assert((select count(*) = 3 and bool_and(status = 'in_progress') from flow.dtf_items where batch_id = :'b2'), 'the placements are in progress (amber, Prints ordered)');
select pg_temp.assert((select prints = 'amber' from public.ui_preproduction where order_ref = '#DB1'), 'the order prints light is amber');

-- receiving: part, then the rest ----------------------------------------------------------------------------------------------------------
select id as i1 from flow.dtf_items where batch_id = :'b2' and area = 'Back' and order_id = :'o1' \gset
select id as i2 from flow.dtf_items where batch_id = :'b2' and order_id = :'o2' \gset
insert into r select 'part', flow.dtf_receive(:'b2', array[:'i1', :'i2']::uuid[], 'tester', 'First box');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'received')::int = 2 and (j->>'left')::int = 1 and not (j->>'complete')::bool from r where k = 'part'), 'part of the order can be received');
select pg_temp.assert((select status = 'ordered' from flow.dtf_batches where id = :'b2'), 'the DTF order stays open while prints are outstanding');
select pg_temp.assert((select prints = 'green' from public.ui_preproduction where order_ref = '#DB2') and (select prints = 'amber' from public.ui_preproduction where order_ref = '#DB1'), 'an order is green when all its prints are in, amber while some are not');
insert into r select 'rest', flow.dtf_receive(:'b2', null, 'tester', null);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'complete')::bool from r where k = 'rest'), 'the rest can be received');
select pg_temp.assert((select status = 'received' and received_at is not null from flow.dtf_batches where id = :'b2') and (select prints = 'green' from public.ui_preproduction where order_ref = '#DB1'), 'the DTF order is received and the order is green');
select pg_temp.assert(not (flow.dtf_receive(:'b2', null, 'tester', null)->>'ok')::bool, 'a received order cannot be received again');
select pg_temp.assert((select count(*) = 2 from flow.audit_log where entity = 'dtf_batches' and entity_id = :'b2' and action = 'dtf_received'), 'each receipt is audited');

-- cancelling the email frees the prints ------------------------------------------------------------------------------------------------------
update flow.dtf_items set status = 'required' where order_id = :'o2';
update flow.dtf_items set batch_id = null where order_id = :'o2';
insert into r select 'build4', flow.dtf_build_order(array[:'o2']::uuid[], '{}'::jsonb, 'tester', null);
select id as b3 from flow.dtf_batches where batch_ref = (select j->>'batch_ref' from r where k = 'build4') \gset
select pg_temp.assert((select (j->>'ok')::bool and (j->>'links_missing')::int = 1 from r where k = 'build4'), 'a missing download link is counted, not hidden');
select pg_temp.assert((select (flow.comm_cancel(c.id, 'tester')->>'ok')::bool from flow.dtf_batches b join flow.communications c on c.id = b.comm_id where b.id = :'b3'), 'the email can be cancelled');
select pg_temp.assert((select status = 'cancelled' from flow.dtf_batches where id = :'b3') and not exists (select 1 from flow.dtf_items where batch_id = :'b3') and (select status = 'required' and batch_id is null from flow.dtf_items where order_id = :'o2'), 'cancelling frees the placements to go on another order');
-- views and permissions
select pg_temp.assert((select count(*) >= 2 from public.ui_dtf_batches) and (select batch_ref is not null from public.ui_dtf_items where order_ref = '#DB1' limit 1), 'staff can see DTF orders, and each placement knows its order');
select pg_temp.assert(not has_table_privilege('authenticated', 'flow.dtf_batches', 'insert') and not has_table_privilege('anon', 'public.ui_dtf_batches', 'select') and has_table_privilege('authenticated', 'public.ui_dtf_batches', 'select'), 'staff can read DTF orders but not write them');
\echo dtf_order_test OK
