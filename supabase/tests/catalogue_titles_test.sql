-- Catalogue titles and the known item codes list.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000b1', 'manager') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);

insert into r select 's1', public.supplier_save(null, '{"name": "Titletest Supplies"}'::jsonb);
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand) values ('CT-KNOWN-1', 'Known polo', 'Navy', 'M', 0);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units, third_party_flag) values
  ('CT1', '#CT1', 'Alpha', '2026-12-01 12:00+00', 'awaiting_stock', 9, false, 5, false);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select 'CTW1', o.id, 'CT-ORDER-ONLY', 'Red', 'L', 'Order only item', 5, '{embroidery}' from flow.orders o where o.deco_order_id = 'CT1';

-- 1. titles are stored by the import
insert into r select 'i1', public.catalogue_import('[{"supplier":"Titletest Supplies","item_code":"CT-KNOWN-1","cost":"4.25","title":"  Polo shirt, navy  "},{"supplier":"Titletest Supplies","item_code":"CT-NOTITLE","cost":"1.10"}]'::jsonb);
select pg_temp.assert((select (j->>'ok')::bool and (j->>'rows')::int = 2 from r where k = 'i1'), 'import ok: ' || (select j::text from r where k = 'i1'));
select pg_temp.assert((select title = 'Polo shirt, navy' and cost = 4.25 from public.ui_catalogue where item_code = 'CT-KNOWN-1'), 'the title is stored, trimmed, and shown in ui_catalogue');
select pg_temp.assert((select title is null from public.ui_catalogue where item_code = 'CT-NOTITLE'), 'a row with no title has none');

-- 2. a later import with no title does not wipe the title; a new title replaces it; the cost still updates
insert into r select 'i2', public.catalogue_import('[{"supplier":"Titletest Supplies","item_code":"CT-KNOWN-1","cost":"4.50"}]'::jsonb);
select pg_temp.assert((select title = 'Polo shirt, navy' and cost = 4.50 from public.ui_catalogue where item_code = 'CT-KNOWN-1'), 'an import without a title keeps the old title and updates the cost');
insert into r select 'i3', public.catalogue_import('[{"supplier":"Titletest Supplies","item_code":"CT-KNOWN-1","cost":"4.50","title":"Polo shirt, navy (2027)"}]'::jsonb);
select pg_temp.assert((select title = 'Polo shirt, navy (2027)' from public.ui_catalogue where item_code = 'CT-KNOWN-1'), 'a new title replaces the old one');
insert into r select 'i4', public.catalogue_import(('[{"supplier":"Titletest Supplies","item_code":"CT-LONG","cost":"1","title":"' || repeat('x', 500) || '"}]')::jsonb);
select pg_temp.assert((select length(title) = 200 from public.ui_catalogue where item_code = 'CT-LONG'), 'a very long title is cut to 200 characters');

-- 3. a bad row still imports nothing, as before
insert into r select 'i5', public.catalogue_import('[{"supplier":"Titletest Supplies","item_code":"CT-OK","cost":"1","title":"fine"},{"supplier":"Nobody","item_code":"CT-BAD","cost":"1"}]'::jsonb);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'i5') and not exists (select 1 from public.ui_catalogue where item_code = 'CT-OK'), 'one bad row imports nothing');

-- 4. known item codes: stock items and order lines, for staff only
select pg_temp.assert((select count(*) = 1 from public.ui_known_skus where sku = 'CT-KNOWN-1') and (select count(*) = 1 from public.ui_known_skus where sku = 'CT-ORDER-ONLY'), 'item codes from stock records and from order lines are both known');
select pg_temp.assert(not exists (select 1 from public.ui_known_skus where sku = 'CT-NOTITLE'), 'an item only in the catalogue is not a known item');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c9', false);
select pg_temp.assert((select count(*) = 0 from public.ui_known_skus), 'someone who is not on the team sees no item codes');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);

select 'catalogue_titles_test OK' as result;
