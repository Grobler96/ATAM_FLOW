-- Profit per order and supplier price age.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000b1', 'manager') on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);

insert into flow.suppliers (code, name, is_active) values ('PROFSUP', 'Profit Test Supplier', true) on conflict (code) do nothing;
select id as sup from flow.suppliers where code = 'PROFSUP' \gset
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units, third_party_flag) values
  ('OPF1', '#OPF1', 'Alpha', '2026-12-01 12:00+00', 'awaiting_stock', 9, false, 30, false), ('OPF2', '#OPF2', 'Beta', '2026-12-02 12:00+00', 'awaiting_stock', 9, false, 5, false);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select v.wi, o.id, v.sku, 'Navy', 'M', 'Polo', v.q, '{embroidery}' from (values
  ('OPW1', 'OPF1', 'PF-A', 10), ('OPW2', 'OPF1', 'PF-B', 20), ('OPW3', 'OPF1', 'PF-NOCOST', 4), ('OPW4', 'OPF1', '999_888', 2), ('OPW5', 'OPF2', 'PF-A', 5), ('OPW6', 'OPF2', 'PF-NOPRICE', 3)) v(wi, oid, sku, q)
join flow.orders o on o.deco_order_id = v.oid;
-- DecoNetwork's per-line sale price (ex VAT)
insert into public.sales_order_lines (order_id, line_id, workflow_item_id, sku, qty_required, unit_price) values
  ('OPF1', 'l1', 'OPW1', 'PF-A', 10, 8.00), ('OPF1', 'l2', 'OPW2', 'PF-B', 20, 5.50), ('OPF1', 'l3', 'OPW3', 'PF-NOCOST', 4, 9.00), ('OPF1', 'l4', 'OPW4', '999_888', 2, 11.40), ('OPF2', 'l5', 'OPW5', 'PF-A', 5, 8.00);
-- catalogue costs (the preferred supplier's)
insert into flow.supplier_offers (supplier_id, sku, unit_cost, is_preferred) values (:'sup', 'PF-A', 3.00, true), (:'sup', 'PF-B', 4.00, true), (:'sup', 'PF-NOPRICE', 2.00, true);

-- 1. order OPF1: costed lines are PF-A and PF-B only
select pg_temp.assert((select sell_value = 190.00 and stock_cost = 110.00 and margin = 80.00 and margin_pct = 42.1 and lines = 4 and costed_lines = 2 from public.ui_order_profit where order_ref = '#OPF1'), 'OPF1 margin works out on the costed lines: ' || (select row_to_json(p)::text from public.ui_order_profit p where order_ref = '#OPF1'));
select pg_temp.assert((select missing_cost_lines = 1 and unpriced_sale_lines = 0 and not complete from public.ui_order_profit where order_ref = '#OPF1'), 'a stock line with no catalogue cost is counted as missing, and the order is not complete; the DecoNetwork own item (underscore code) is not counted as missing');
-- 2. order OPF2: one line has no sale price
select pg_temp.assert((select sell_value = 40.00 and stock_cost = 15.00 and margin = 25.00 and unpriced_sale_lines = 1 and costed_lines = 1 and not complete from public.ui_order_profit where order_ref = '#OPF2'), 'OPF2: a line with no sale price is left out of the margin and counted');
-- 3. a fully costed order is complete
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, deco_status, stock_secured, total_units, third_party_flag) values ('OPF3', '#OPF3', 'Gamma', '2026-12-03 12:00+00', 'awaiting_stock', 9, false, 2, false);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods) select 'OPW7', o.id, 'PF-B', 'Navy', 'M', 'Polo', 2, '{embroidery}' from flow.orders o where o.deco_order_id = 'OPF3';
insert into public.sales_order_lines (order_id, line_id, workflow_item_id, sku, qty_required, unit_price) values ('OPF3', 'l7', 'OPW7', 'PF-B', 2, 6.00);
select pg_temp.assert((select complete and margin = 4.00 and margin_pct = 33.3 from public.ui_order_profit where order_ref = '#OPF3'), 'an order whose lines all have a sale price and a cost is complete');
-- 4. only the preferred supplier's cost is used; an inactive order drops out
insert into flow.supplier_offers (supplier_id, sku, unit_cost, is_preferred) select s.id, 'PF-B', 1.00, false from flow.suppliers s where s.code <> 'PROFSUP' limit 1;
select pg_temp.assert((select margin = 4.00 from public.ui_order_profit where order_ref = '#OPF3'), 'a cheaper non-preferred offer does not change the margin');
update flow.orders set is_active = false where deco_order_id = 'OPF3';
select pg_temp.assert(not exists (select 1 from public.ui_order_profit where order_ref = '#OPF3'), 'a closed order is not in the view');
-- 5. team only
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c9', false);
select pg_temp.assert((select count(*) = 0 from public.ui_order_profit), 'someone who is not on the team sees no margins');
select pg_temp.assert(not has_function_privilege('anon', 'flow.order_profit()', 'execute') and not has_table_privilege('anon', 'public.ui_order_profit', 'select'), 'anonymous visitors cannot read margins');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b1', false);

-- 6. supplier price age
update flow.supplier_offers set updated_at = now() - interval '100 days' where supplier_id = :'sup' and sku = 'PF-A';
select pg_temp.assert((select priced_items = 3 and days_old = 0 from public.ui_supplier_price_age where supplier = 'Profit Test Supplier'), 'the age is the most recent load (the other two prices are new): ' || (select row_to_json(p)::text from public.ui_supplier_price_age p where supplier = 'Profit Test Supplier'));
update flow.supplier_offers set updated_at = now() - interval '100 days' where supplier_id = :'sup';
select pg_temp.assert((select days_old = 100 from public.ui_supplier_price_age where supplier = 'Profit Test Supplier'), 'prices last loaded 100 days ago show 100 days');
insert into flow.suppliers (code, name, is_active) values ('PROFEMPTY', 'Profit Test Empty Supplier', true);
select pg_temp.assert((select days_old is null and priced_items = 0 from public.ui_supplier_price_age p where p.supplier = 'Profit Test Empty Supplier'), 'a supplier with no prices has no age');

select 'order_profit_test OK' as result;
