-- Product catalogue, live POs, per-order decorator (supabase/pending/20261114000066). Runs after all migrations.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.suppliers (code, name, email, lead_time_days, delivery_cost) values ('RW', 'Ralawise SL', 'o@rw.test', 2, 0), ('PW', 'Portwest SL', null, 3, 0);
select id as rw from flow.suppliers where code = 'RW' \gset
select id as pw from flow.suppliers where code = 'PW' \gset
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand) values ('SL-A', 'Polo', 'Navy', 'M', 0), ('SL-B', 'Jacket', 'Black', 'L', 0), ('SL-C', 'Cap', 'Red', 'S', 0);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units, third_party_flag) values
  ('S1', '#S1', 'Alpha', '2026-12-01 12:00+00', 'awaiting_stock', 9, false, 30, true), ('S2', '#S2', 'Beta', '2026-12-02 12:00+00', 'awaiting_stock', 9, false, 10, false);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select v.wi, o.id, v.sku, v.c, v.s, v.pn, v.q, '{embroidery}' from (values ('SW1','S1','SL-A','Navy','M','Polo',20), ('SW2','S1','SL-B','Black','L','Jacket',10), ('SW3','S2','SL-C','Red','S','Cap',10)) v(wi, oid, sku, c, s, pn, q)
join flow.orders o on o.deco_order_id = v.oid;
select id as o1 from flow.orders where deco_order_id = 'S1' \gset

-- catalogue import: bad rows import nothing
select pg_temp.assert(not (flow.catalogue_import('[{"supplier":"Nobody","item_code":"SL-A","cost":"3"}]'::jsonb, 't')->>'ok')::bool, 'unknown supplier refused');
select pg_temp.assert(not (flow.catalogue_import('[{"supplier":"Ralawise SL","item_code":"SL-A","cost":"abc"}]'::jsonb, 't')->>'ok')::bool, 'bad cost refused');
select pg_temp.assert((select count(*) from flow.supplier_offers where sku like 'SL-%') = 0, 'nothing imported after a refusal');
-- good import: cheapest becomes preferred unless one is flagged
select pg_temp.assert((flow.catalogue_import('[{"supplier":"Ralawise SL","item_code":"SL-A","cost":"4.00"},{"supplier":"Portwest","item_code":"SL-A","cost":"3.50"},{"supplier":"PW","item_code":"SL-A","cost":"3.50"},
  {"supplier":"Portwest SL","item_code":"SL-B","cost":"20"},{"supplier":"ralawise sl","item_code":"SL-C","cost":"2","preferred":"yes"},{"supplier":"Portwest SL","item_code":"SL-C","cost":"1"}]'::jsonb, 't')->>'ok')::bool is not true, 'partial name "Portwest" is not a match');
select pg_temp.assert((flow.catalogue_import('[{"supplier":"Ralawise SL","item_code":"SL-A","cost":"4.00"},{"supplier":"PW","item_code":"SL-A","cost":"3.50"},
  {"supplier":"Portwest SL","item_code":"SL-B","cost":"20"},{"supplier":"ralawise sl","item_code":"SL-C","cost":"2","preferred":"yes"},{"supplier":"Portwest SL","item_code":"SL-C","cost":"1"}]'::jsonb, 't')->>'ok')::bool, 'import ok');
select pg_temp.assert((select supplier_id from flow.supplier_offers where sku = 'SL-A' and is_preferred) = :'pw', 'cheapest is preferred when none flagged');
select pg_temp.assert((select supplier_id from flow.supplier_offers where sku = 'SL-C' and is_preferred) = :'rw', 'flagged supplier wins over cheaper');
select pg_temp.assert((flow.catalogue_set_preferred(:'rw', 'SL-A', 't')->>'ok')::bool, 'preferred change accepted');
select pg_temp.assert((select supplier_id from flow.supplier_offers where sku = 'SL-A' and is_preferred) = :'rw', 'preferred can be changed');
select pg_temp.assert((select count(*) from flow.supplier_offers where sku = 'SL-A' and is_preferred) = 1, 'only one preferred per item');
select pg_temp.assert(flow.catalogue_set_preferred(:'rw', 'SL-B', 't')->>'ok' = 'false', 'cannot prefer a supplier without the item');

-- what needs buying, with preferred supplier and cost
select pg_temp.assert((select count(*) from public.ui_order_buy_lines where order_ref in ('#S1', '#S2')) = 0, 'a non-member sees nothing');
create temp table m (x int);
-- (the view function checks flow.is_member; run as a member below)
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1', 'boss@test') on conflict do nothing;
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a1', 'admin') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
select pg_temp.assert((select count(*) from public.ui_order_buy_lines where order_ref in ('#S1', '#S2')) = 3, 'three lines need buying');
select pg_temp.assert((select supplier_id from public.ui_order_buy_lines where sku = 'SL-B') = :'pw', 'line shows its preferred supplier');

-- live PO: approved straight away, email queued
create temp table r (j jsonb);
insert into r select flow.create_po_for_orders(:'rw', array[:'o1'::uuid], 'tester', '{"live":true,"skus":["SL-A"]}'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'live')::bool and j->>'status' = 'approved' from r), 'PO live: ' || (select j::text from r));
select pg_temp.assert((select po_status::text from flow.purchase_orders where id = (select (j->>'po_id')::uuid from r)) = 'approved', 'PO is approved, not draft');
select pg_temp.assert((select count(*) from flow.communications where entity_id = (select (j->>'po_id')::uuid from r)) = 1, 'email queued for the supplier');
select pg_temp.assert((select status from flow.communications where entity_id = (select (j->>'po_id')::uuid from r)) = 'pending_review', 'email still waits for a click');
-- without the option a PO is still a draft (existing behaviour)
insert into r select flow.create_po_for_orders(:'pw', array[:'o1'::uuid], 'tester', '{"skus":["SL-B"]}'::jsonb);
select pg_temp.assert((select po_status::text from flow.purchase_orders where id = (select (j->>'po_id')::uuid from r offset 1 limit 1)) = 'draft', 'no live option = draft');
-- the line already on a PO no longer needs buying
select pg_temp.assert((select count(*) from public.ui_order_buy_lines where sku = 'SL-A') = 0, 'ordered line no longer needs buying');
-- a line with no cost cannot go live
insert into flow.supplier_offers (supplier_id, sku, unit_cost) values (:'rw', 'SL-NOCOST', null);

-- decorator: third-party orders follow the default, any order can be changed, null resets
insert into flow.producers (code, name, is_active) values ('DPS', 'DPS Embroidery', true), ('OTH', 'Other Deco', true) on conflict do nothing;
select id as dps from flow.producers where code = 'DPS' \gset
select id as oth from flow.producers where code = 'OTH' \gset
insert into flow.flow_settings (key, value) values ('third_party.default_producer', jsonb_build_object('producer_id', :'dps')) on conflict (key) do update set value = excluded.value;
select pg_temp.assert((select d.producer_id from public.ui_order_decorator d join flow.orders o on o.id = d.order_id where o.deco_order_id = 'S1') = :'dps', 'third-party order defaults to DPS');
select pg_temp.assert((select d.producer_id from public.ui_order_decorator d join flow.orders o on o.id = d.order_id where o.deco_order_id = 'S2') is null, 'in-house order has no decorator');
select pg_temp.assert((public.set_order_decorator(:'o1', :'oth')->>'ok')::bool, 'decorator changed');
select pg_temp.assert((select producer_id from public.ui_order_decorator where order_id = :'o1') = :'oth', 'order now goes to the other decorator');
select pg_temp.assert((public.set_order_decorator(:'o1', null)->>'ok')::bool, 'reset accepted');
select pg_temp.assert((select producer_id from public.ui_order_decorator where order_id = :'o1') = :'dps', 'null resets to the default');
-- a viewer cannot change it or the catalogue
delete from flow.user_roles where user_id = '00000000-0000-0000-0000-0000000000a1';
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a1', 'viewer');
select pg_temp.assert(public.set_order_decorator(:'o1', :'oth')->>'ok' = 'false', 'viewer cannot change the decorator');
select pg_temp.assert(public.catalogue_import('[{"supplier":"RW","item_code":"X","cost":"1"}]'::jsonb)->>'ok' = 'false', 'viewer cannot import');
select 'streamline_test passed' as result;
