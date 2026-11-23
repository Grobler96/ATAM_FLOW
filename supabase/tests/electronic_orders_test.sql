-- Ordering stock electronically (API / EDI suppliers).
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000b1', 'manager') on conflict do nothing;
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000c1', 'production') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);

-- an API supplier and an email supplier, each with a catalogue price
insert into r select 'sa', public.supplier_save(null, '{"name": "Etest Api Supplier", "order_method": "api", "email": "orders@etest-api.test", "account_number": "ACC-API"}'::jsonb);
insert into r select 'se', public.supplier_save(null, '{"name": "Etest Email Supplier", "order_method": "email", "email": "orders@etest-mail.test"}'::jsonb);
select j->>'id' as sa from r where k = 'sa' \gset
select j->>'id' as se from r where k = 'se' \gset
insert into r select 'so', public.supplier_shipping_save(:'sa', null, '{"name": "Next day", "cost": "6.95", "notes": "code: UKMAIN-UKNBD"}'::jsonb);
insert into flow.supplier_offers (supplier_id, sku, unit_cost) values (:'sa', 'ET-1', 2.50), (:'sa', 'ET-2', 4.00), (:'se', 'ET-1', 2.60);

-- 1. a PO to an API supplier prepares an electronic order, not an email ---------------------------------------------------------------------
insert into r select 'p1', flow.create_purchase_order(:'sa', '[{"sku":"ET-1","qty":10,"product_name":"Polo","colour":"Navy","size":"M","sources":[]},{"sku":"ET-2","qty":5,"product_name":"Cap","sources":[]}]'::jsonb, 'tester');
select j->>'po_id' as p1 from r where k = 'p1' \gset
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'p1'), 'PO created: ' || (select j::text from r where k = 'p1'));
select pg_temp.assert((select count(*) = 2 and bool_and(unit_cost is not null) from flow.po_lines where po_id = :'p1'), 'the PO lines are priced from the catalogue');
insert into r select 'p1s_early', flow.send_purchase_order(:'p1', 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p1s_early'), 'a draft PO cannot be sent');
select flow.approve_purchase_order(:'p1', 'tester');
insert into r select 'p1s', flow.send_purchase_order(:'p1', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'pending_review' from r where k = 'p1s'), 'an API supplier gets an electronic order waiting for approval: ' || (select j::text from r where k = 'p1s'));
select pg_temp.assert(not exists (select 1 from flow.communications where entity_id = :'p1'::uuid and kind = 'po_send'), 'no email is queued for an API supplier');
select pg_temp.assert((select po_status = 'approved' from flow.purchase_orders where id = :'p1'), 'the PO is not marked sent until it really goes');
select id as t1 from flow.po_transmissions where po_id = :'p1' \gset
select pg_temp.assert((select payload->>'po_ref' = (select af_po_ref from flow.purchase_orders where id = :'p1') and jsonb_array_length(payload->'lines') = 2 and payload#>>'{lines,0,sku}' = 'ET-1' and (payload#>>'{lines,0,qty}')::int = 10 and (payload#>>'{lines,0,unit_cost}')::numeric = 2.5
  and payload#>>'{delivery,postcode}' = 'LS25 6PD' and payload#>>'{supplier,account_number}' = 'ACC-API' and payload#>>'{shipping_option,name}' = 'Next day' and payload#>>'{shipping_option,notes}' = 'code: UKMAIN-UKNBD' from flow.po_transmissions where id = :'t1'), 'the order holds the PO reference, lines with costs, the delivery address, the account number and the delivery option');
insert into r select 'p1s2', flow.send_purchase_order(:'p1', 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p1s2'), 'the same PO cannot be prepared twice');

-- 2. only a manager or admin approves ------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
insert into r select 'a0', public.po_tx_approve(:'t1');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a0'), 'someone who is not a manager or admin cannot approve it');
insert into r select 'c0', public.po_tx_cancel(:'t1', 'no reason');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c0'), 'nor cancel it');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);
select pg_temp.assert(jsonb_array_length(flow.po_tx_claim('api', 5)->'orders') = 0, 'an order waiting for approval is not handed to n8n');
insert into r select 'a1', public.po_tx_approve(:'t1');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'queued' from r where k = 'a1') and (select status = 'queued' and approved_by is not null from flow.po_transmissions where id = :'t1'), 'a manager approves it, and it is queued');

-- 3. n8n claims it once ------------------------------------------------------------------------------------------------------------------------------
insert into r select 'cl_edi', flow.po_tx_claim('edi', 5);
select pg_temp.assert(jsonb_array_length((select j->'orders' from r where k = 'cl_edi')) = 0, 'an API order is not handed out as an EDI one');
insert into r select 'cl1', flow.po_tx_claim('api', 5);
select pg_temp.assert(jsonb_array_length((select j->'orders' from r where k = 'cl1')) = 1 and (select j#>>'{orders,0,id}' from r where k = 'cl1') = :'t1' and (select status = 'sending' and attempts = 1 from flow.po_transmissions where id = :'t1'), 'the approved order is claimed and marked sending');
insert into r select 'cl2', flow.po_tx_claim('api', 5);
select pg_temp.assert(jsonb_array_length((select j->'orders' from r where k = 'cl2')) = 0, 'a claimed order is never handed out again');
insert into r select 'c1', public.po_tx_cancel(:'t1', 'changed our mind');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c1'), 'an order that is being sent cannot be cancelled');

-- 4. a failure is kept with its reason, and a person retries it -----------------------------------------------------------------------------------------
insert into r select 'f1', flow.po_tx_failed(:'t1', 'Ralawise said: SkuNotFound', '{"messages":[{"errorCode":"SkuNotFound"}]}'::jsonb, 'n8n');
select pg_temp.assert((select status = 'failed' and last_error like '%SkuNotFound%' from flow.po_transmissions where id = :'t1') and (select po_status = 'approved' from flow.purchase_orders where id = :'p1'), 'a failed order keeps its reason and the PO stays approved');
select pg_temp.assert(jsonb_array_length(flow.po_tx_claim('api', 5)->'orders') = 0, 'a failed order is not sent again by itself');
insert into r select 'a2', public.po_tx_approve(:'t1');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'a2') and (select status = 'queued' from flow.po_transmissions where id = :'t1'), 'a person can approve a failed order to try again');
insert into r select 'cl3', flow.po_tx_claim('api', 5);
select pg_temp.assert((select attempts = 2 from flow.po_transmissions where id = :'t1'), 'the second try counts');

-- the supplier filter: a sender for another supplier does not claim this order
-- (checked on the next order below)
-- 5. success moves the PO to sent with the supplier's order number -----------------------------------------------------------------------------
insert into r select 'd1', flow.po_tx_done(:'t1', '20368068', '{"order":{"orderNumber":"20368068"},"warnings":"SkuNotFound: ET-9"}'::jsonb, 'n8n');
select pg_temp.assert((select status = 'sent' and supplier_order_ref = '20368068' and sent_at is not null and last_error = 'SkuNotFound: ET-9' from flow.po_transmissions where id = :'t1'), 'the order is marked sent with the supplier order number, and a supplier warning is kept visible');
select pg_temp.assert((select po_status = 'sent' and supplier_ref = '20368068' and sent_at is not null from flow.purchase_orders where id = :'p1'), 'the PO moves to sent and keeps the supplier order number');
insert into r select 'd2', flow.po_tx_done(:'t1', '1', '{}'::jsonb, 'n8n');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'd2'), 'a sent order cannot be marked sent again');
select pg_temp.assert((select count(*) >= 5 from flow.audit_log where action in ('queue_po_electronic', 'approve_po_electronic', 'po_failed_electronic', 'po_sent_electronic')), 'every step is audited');
select pg_temp.assert((select count(*) = 1 from public.ui_po_transmissions where po_id = :'p1'::uuid and status = 'sent' and line_count = 2 and goods_value = 45 and supplier = 'Etest Api Supplier'), 'the screen view shows the order with its value');

-- 6. cancelling a waiting order, and an incomplete address -------------------------------------------------------------------------------------
insert into r select 'p2', flow.create_purchase_order(:'sa', '[{"sku":"ET-1","qty":3,"sources":[]}]'::jsonb, 'tester');
select j->>'po_id' as p2 from r where k = 'p2' \gset
select flow.approve_purchase_order(:'p2', 'tester');
insert into r select 'p2s', flow.send_purchase_order(:'p2', 'tester');
select id as t2 from flow.po_transmissions where po_id = :'p2' \gset
select public.po_tx_approve(:'t2');
select pg_temp.assert(jsonb_array_length(flow.po_tx_claim('api', 5, 'Somebody Else')->'orders') = 0, 'a sender for another supplier does not claim this order');
select pg_temp.assert(jsonb_array_length(flow.po_tx_claim('api', 5, 'etest api')->'orders') = 1, 'the sender whose name matches claims it');
select flow.po_tx_failed(:'t2', 'test', null, 'n8n');
insert into r select 'c2', public.po_tx_cancel(:'t2', 'ordered by phone instead');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'c2') and (select status = 'cancelled' and cancel_reason = 'ordered by phone instead' from flow.po_transmissions where id = :'t2'), 'a waiting order can be cancelled with a reason');
select pg_temp.assert((select count(*) from flow.po_transmissions where po_id = :'p2') = 1, 'cancelling leaves the record');
update flow.flow_settings set value = value || '{"postcode": ""}'::jsonb where key = 'buying.delivery_address';
insert into r select 'p2s2', flow.send_purchase_order(:'p2', 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'p2s2') and (select j->>'error' like '%delivery address%' from r where k = 'p2s2'), 'an incomplete delivery address stops the order, with a plain reason');
update flow.flow_settings set value = value || '{"postcode": "LS25 6PD"}'::jsonb where key = 'buying.delivery_address';

-- 7. an email supplier still gets an email, and a PO set to deliver to a decorator is refused --------------------------------------------------------
insert into r select 'p3', flow.create_purchase_order(:'se', '[{"sku":"ET-1","qty":4,"sources":[]}]'::jsonb, 'tester');
select j->>'po_id' as p3 from r where k = 'p3' \gset
select flow.approve_purchase_order(:'p3', 'tester');
insert into r select 'p3s', flow.send_purchase_order(:'p3', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j ? 'communication_id' from r where k = 'p3s') and exists (select 1 from flow.communications where entity_id = :'p3'::uuid and kind = 'po_send') and not exists (select 1 from flow.po_transmissions where po_id = :'p3'::uuid), 'an email supplier still gets the email and no electronic order');

-- 8. permissions --------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.assert(not has_function_privilege('anon', 'public.po_tx_approve(uuid)', 'execute') and has_function_privilege('authenticated', 'public.po_tx_approve(uuid)', 'execute'), 'the approve and cancel wrappers are for signed-in staff only');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_po_tx_claim(text,integer,text)', 'execute') and not has_function_privilege('anon', 'public.flow_po_tx_done(uuid,text,jsonb,text)', 'execute') and not has_function_privilege('authenticated', 'flow.po_tx_claim(text,integer,text)', 'execute'), 'claiming, marking sent and marking failed are n8n only');
select pg_temp.assert(has_function_privilege('service_role', 'public.flow_po_tx_claim(text,integer,text)', 'execute') and has_function_privilege('service_role', 'public.flow_po_tx_failed(uuid,text,jsonb,text)', 'execute'), 'the service role can run the n8n functions');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c9', false);
select pg_temp.assert((select count(*) = 0 from public.ui_po_transmissions), 'someone who is not on the team sees no electronic orders');

select 'electronic_orders_test OK' as result;
