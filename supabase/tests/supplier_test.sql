-- Supplier resilience: reliability stats, approved alternatives, shortage advice, chase drafts.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.suppliers (code, name, contact_name, email, lead_time_days) values ('SRA', 'Reliable Garments', 'Ria', 'ria@sr.test', 2), ('SRB', 'Flaky Textiles', null, null, 5);
select id as sa from flow.suppliers where code = 'SRA' \gset
select id as sb from flow.suppliers where code = 'SRB' \gset

-- 1. stats: Reliable delivered 3 on time; Flaky delivered 1 on time, 1 late, and has 1 open late PO
insert into flow.purchase_orders (deco_po_id, po_number, supplier, supplier_ref_id, expected_date, actual_delivery, is_active, delivery_status) values
  (9100, 'S-A1', 'Reliable Garments', :'sa', now() - interval '30 days', current_date - 31, false, 'received'), (9101, 'S-A2', 'Reliable Garments', :'sa', now() - interval '20 days', current_date - 21, false, 'received'),
  (9102, 'S-A3', 'Reliable Garments', :'sa', now() - interval '10 days', current_date - 10, false, 'received'),
  (9103, 'S-B1', 'Flaky Textiles', :'sb', now() - interval '30 days', current_date - 30, false, 'received'), (9104, 'S-B2', 'Flaky Textiles', :'sb', now() - interval '20 days', current_date - 15, false, 'received'),
  (9105, 'S-B3', 'flaky textiles', null, now() - interval '5 days', null, true, 'expected');
insert into r select 'st', flow.refresh_supplier_stats();
select pg_temp.assert((select on_time_rate = 100 and pos_considered = 3 from flow.supplier_stats where supplier_id = :'sa'), 'reliable supplier: 100% over 3 POs');
select pg_temp.assert((select pos_considered = 3 and pos_late = 2 and on_time_rate = 33.33 and open_late = 1 and avg_days_late = 5.0 from flow.supplier_stats where supplier_id = :'sb'), 'flaky supplier: late counted incl. the open overdue PO matched by name: ' || (select row_to_json(x)::text from flow.supplier_stats x where supplier_id = :'sb'));
select pg_temp.assert((select on_time_rate = 100 from flow.suppliers where id = :'sa') and (select on_time_rate = 33.33 from flow.suppliers where id = :'sb'), 'supplier on_time_rate filled for the selection engine');
select pg_temp.assert((select (j->>'ok')::bool from (select flow.refresh_supplier_stats() j) x) and (select pos_considered from flow.supplier_stats where supplier_id = :'sb') = 3, 'refreshing again is stable');

-- 2. approved alternatives
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand) values ('AL-NAVY-M', 'Polo', 'Navy', 'M', 0), ('AL-ROYAL-M', 'Polo', 'Royal', 'M', 40), ('AL-OTHER', 'Hoodie', 'Black', 'L', 5);
insert into flow.stock_items (sku, product_name, qty_on_hand, is_placeholder) values ('AL-GHOST', 'Seen on an order only', 0, true);
insert into r select 'a1', flow.alt_add('AL-NAVY-M', 'AL-ROYAL-M', true, 'Closest shade', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'a1'), 'alternative approved');
select pg_temp.assert(not (flow.alt_add('AL-NAVY-M', 'AL-ROYAL-M', true, null, 't')->>'ok')::bool and not (flow.alt_add('AL-NAVY-M', 'AL-NAVY-M', true, null, 't')->>'ok')::bool and not (flow.alt_add('AL-NAVY-M', 'NOPE', true, null, 't')->>'ok')::bool
  and not (flow.alt_add('AL-NAVY-M', 'AL-GHOST', true, null, 't')->>'ok')::bool, 'duplicate, self, unknown and placeholder alternatives refused');

-- 3. shortage advice
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units) values ('SR1', '#SR1', 'Short Customer', now() + interval '6 days', 'awaiting_stock', 9, false, 30);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select 'SRL1', o.id, 'AL-NAVY-M', 'Navy', 'M', 'Polo', 30, '{embroidery}' from flow.orders o where o.deco_order_id = 'SR1';
insert into r select 'adv1', flow.shortage_advice('AL-NAVY-M');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'units_short')::int = 30 and j->'recommendation'->>'action' = 'substitute' and (j->'alternatives'->0->>'free')::int = 40 from r where k = 'adv1'), 'enough approved alternative stock: substitute: ' || (select j::text from r where k = 'adv1'));
select pg_temp.assert((select j->'recommendation'->>'text' like '%customer must agree%' from r where k = 'adv1'), 'says the customer must agree');
select pg_temp.assert(not (flow.shortage_advice('NO-SHORTAGE')->>'ok')::bool, 'no shortage, no advice');
-- reliable PO incoming before the due date: wait beats substitute
insert into flow.purchase_orders (deco_po_id, po_number, supplier, supplier_ref_id, expected_date, is_active, delivery_status) values (9200, 'S-WAIT', 'Reliable Garments', :'sa', now() + interval '3 days', true, 'expected');
insert into flow.po_lines (po_id, line_no, sku, qty_expected, expected_date) select id, 1, 'AL-NAVY-M', 30, current_date + 3 from flow.purchase_orders where deco_po_id = 9200;
insert into r select 'adv2', flow.shortage_advice('AL-NAVY-M');
select pg_temp.assert((select j->'recommendation'->>'action' = 'wait' from r where k = 'adv2'), 'reliable stock arriving in time: wait: ' || (select j::text from r where k = 'adv2'));
-- the same PO from an unreliable supplier does not count
update flow.purchase_orders set supplier = 'Flaky Textiles', supplier_ref_id = :'sb' where deco_po_id = 9200;
insert into r select 'adv3', flow.shortage_advice('AL-NAVY-M');
select pg_temp.assert((select j->'recommendation'->>'action' = 'substitute' from r where k = 'adv3'), 'an unreliable supplier PO does not justify waiting');
-- no alternatives and no PO: reorder from an offer that lands in time, else tell the customer
update flow.approved_alternatives set is_active = false, removed_reason = 'test' where sku = 'AL-NAVY-M';
update flow.purchase_orders set is_active = false where deco_po_id = 9200;
insert into r select 'adv4', flow.shortage_advice('AL-NAVY-M');
select pg_temp.assert((select j->'recommendation'->>'action' = 'tell_customer' from r where k = 'adv4'), 'nothing covers it: tell the customer');
insert into flow.supplier_offers (supplier_id, sku, unit_cost, lead_time_days) values (:'sa', 'AL-NAVY-M', 6.5, 2);
insert into r select 'adv5', flow.shortage_advice('AL-NAVY-M');
select pg_temp.assert((select j->'recommendation'->>'action' = 'reorder' and j->'recommendation'->>'text' like '%Reliable Garments%' from r where k = 'adv5'), 'an offer that lands in time: reorder: ' || (select j::text from r where k = 'adv5'));
insert into flow.supplier_offers (supplier_id, sku, lead_time_days) values (:'sb', 'AL-NAVY-M', 30) on conflict do nothing;
update flow.supplier_offers set lead_time_days = 30 where supplier_id = :'sa' and sku = 'AL-NAVY-M';
insert into r select 'adv6', flow.shortage_advice('AL-NAVY-M');
select pg_temp.assert((select j->'recommendation'->>'action' = 'tell_customer' and j->'recommendation'->>'text' like '%earliest stock could be here%' from r where k = 'adv6'), 'offers too slow: tell the customer with the earliest feasible date');

-- 4. chase drafts
insert into flow.purchase_orders (deco_po_id, po_number, supplier, supplier_ref_id, expected_date, is_active, delivery_status) values (9300, 'S-LATE', 'Reliable Garments', :'sa', now() - interval '6 days', true, 'expected'), (9301, 'S-LATE2', 'Flaky Textiles', :'sb', now() - interval '4 days', true, 'expected'), (9302, 'S-FUTURE', 'Reliable Garments', :'sa', now() + interval '5 days', true, 'expected');
insert into flow.po_lines (po_id, line_no, sku, colour, size, qty_expected) select id, 1, 'AL-ROYAL-M', 'Royal', 'M', 12 from flow.purchase_orders where deco_po_id in (9300, 9301, 9302);
select id as late1 from flow.purchase_orders where deco_po_id = 9300 \gset
select id as late2 from flow.purchase_orders where deco_po_id = 9301 \gset
select id as fut from flow.purchase_orders where deco_po_id = 9302 \gset
insert into r select 'c1', flow.po_chase_draft(:'late1', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'no_recipient')::bool from r where k = 'c1') and (select status = 'pending_review' and subject like 'Chase: purchase order S-LATE (6 days overdue)%' and body_text like '%12 x AL-ROYAL-M%' and body_text like '%Hello Ria%' from flow.communications where entity_id = :'late1'), 'chase queued for review with the lines and the supplier contact');
insert into r select 'c2', flow.po_chase_draft(:'late1', 'tester');
select pg_temp.assert((select (j->>'already_queued')::bool from r where k = 'c2') and (select count(*) from flow.communications where entity_id = :'late1') = 1, 'a second chase is not queued while one is waiting');
insert into r select 'c3', flow.po_chase_draft(:'late2', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'no_recipient')::bool from r where k = 'c3') and (select status = 'draft' from flow.communications where entity_id = :'late2'), 'no supplier email: draft, flagged as having no recipient');
select pg_temp.assert(not (flow.po_chase_draft(:'fut', 'tester')->>'ok')::bool, 'a PO that is not late is not chased');
update flow.communications set status = 'sent', sent_at = now() where entity_id = :'late1';
select pg_temp.assert((flow.po_chase_draft(:'late1', 'tester')->>'error') like '%less than 24 hours%', 'cannot chase again within a day of the last chase');
insert into r select 'all', flow.po_chase_all_late('tester', 2);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'already_queued')::int >= 1 from r where k = 'all') and (select count(*) from flow.audit_log where action = 'po_chase_drafted') >= 2, 'bulk chase skips what is already queued and is audited: ' || (select j::text from r where k = 'all'));

-- 5. removing an alternative needs a reason; locked down
select id as aid from flow.approved_alternatives where sku = 'AL-NAVY-M' \gset
update flow.approved_alternatives set is_active = true where id = :'aid';
select pg_temp.assert((flow.alt_remove(:'aid', 't', '')->>'needs_reason')::bool and (flow.alt_remove(:'aid', 't', 'no longer approved')->>'ok')::bool, 'withdrawing needs a reason');
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_po_chase_draft(uuid,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_alt_add(text,text,boolean,text,text)', 'execute')
  and has_function_privilege('service_role', 'public.flow_refresh_supplier_stats()', 'execute') and not has_function_privilege('anon', 'public.ui_shortage_advice(text)', 'execute') and has_function_privilege('authenticated', 'public.ui_shortage_advice(text)', 'execute'), 'wrappers locked down');
-- 6. supplier offers by hand
insert into r select 'o1', flow.offer_set(:'sb', 'AL-OTHER', 9.99, 4, 1, null, 'FLK-OTH', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'o1') and (select unit_cost = 9.99 and lead_time_days = 4 from flow.supplier_offers where supplier_id = :'sb' and sku = 'AL-OTHER'), 'offer saved');
insert into r select 'o2', flow.offer_set(:'sb', 'AL-OTHER', 8.5, 3, 1, 0, null, 'tester');
select pg_temp.assert((select count(*) from flow.supplier_offers where supplier_id = :'sb' and sku = 'AL-OTHER') = 1 and (select stock_available = 0 and unit_cost = 8.5 from flow.supplier_offers where supplier_id = :'sb' and sku = 'AL-OTHER'), 'offer upsert replaces, 0 = out of stock');
select pg_temp.assert(not (flow.offer_set(:'sb', 'NOPE', 1, 1, 1, null, null, 't')->>'ok')::bool and not (flow.offer_set(:'sb', 'AL-OTHER', -1, 1, 1, null, null, 't')->>'ok')::bool and not (flow.offer_set(:'sb', 'AL-OTHER', 1, 200, 1, null, null, 't')->>'ok')::bool, 'bad offers refused');
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_offer_set(uuid,text,numeric,numeric,int,int,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_offer_set(uuid,text,numeric,numeric,int,int,text,text)', 'execute'), 'offer wrapper locked down');
\echo supplier_test OK
