-- The catalogue import stores a supplier's own item code, and never clears one.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000a5c01', 'manager') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000a5c01', false);
insert into flow.suppliers (code, name, is_active) values ('SCODES', 'Supplier Codes Test', true);
create temp table r (k text primary key, j jsonb);
insert into r select 'i1', public.catalogue_import('[{"supplier":"Supplier Codes Test","item_code":"900000001_111","cost":"0.67","supplier_sku":"  WM118NATUXS "},{"supplier":"Supplier Codes Test","item_code":"PLAIN-1","cost":"2"}]'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'i1'), 'imported');
select pg_temp.assert((select supplier_sku from flow.supplier_offers where sku = '900000001_111') = 'WM118NATUXS', 'the supplier code is stored, trimmed');
select pg_temp.assert((select supplier_sku from flow.supplier_offers where sku = 'PLAIN-1') is null, 'a row with no supplier code has none');
insert into r select 'i2', public.catalogue_import('[{"supplier":"Supplier Codes Test","item_code":"900000001_111","cost":"0.70"}]'::jsonb);
select pg_temp.assert((select supplier_sku from flow.supplier_offers where sku = '900000001_111') = 'WM118NATUXS' and (select unit_cost from flow.supplier_offers where sku = '900000001_111') = 0.70, 'a later import without a code keeps the code and still updates the price');
insert into r select 'i3', public.catalogue_import('[{"supplier":"Supplier Codes Test","item_code":"900000001_111","cost":"0.70","supplier_sku":"WM118NATUS"}]'::jsonb);
select pg_temp.assert((select supplier_sku from flow.supplier_offers where sku = '900000001_111') = 'WM118NATUS', 'a new code replaces the old one');
-- the list of DecoNetwork-numbered items
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values ('SC1', '#SC1', 'Codes', now() + interval '9 days', 'awaiting_stock', false, 9, 2);
select id as o1 from flow.orders where deco_order_id = 'SC1' \gset
insert into flow.order_lines (deco_workflow_item_id, order_id, deco_line_id, sku, product_code, colour, size, supplier, qty_required, is_active) values
 ('SCW1', :'o1', 'SCL1', '900000002_222', 'WM118', 'Natural', 'XS', 'Ralawise', 1, true),
 ('SCW2', :'o1', 'SCL2', 'PLAINSKU', 'WM118', 'Natural', 'XS', 'Ralawise', 1, true);
select pg_temp.assert((select count(*) from public.ui_known_sku_lines where sku = '900000002_222' and product_code = 'WM118' and colour = 'Natural' and size = 'XS' and supplier = 'Ralawise') = 1, 'staff see the DecoNetwork-numbered item with its style code, colour and size');
select pg_temp.assert((select count(*) from public.ui_known_sku_lines where sku = 'PLAINSKU') = 0, 'an ordinary item code is not listed');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000a5c02', false);
select pg_temp.assert((select count(*) from public.ui_known_sku_lines) = 0, 'a user who is not staff sees nothing');
select 'catalogue_supplier_codes_test OK' as result;
