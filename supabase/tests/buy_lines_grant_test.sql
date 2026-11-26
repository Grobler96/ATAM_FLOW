-- A logged-in team member (not a superuser) can read the list of what needs buying.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000b1001', 'manager') on conflict do nothing;
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values ('BL1', '#BL1', 'Buy lines', now() + interval '9 days', 'awaiting_stock', false, 9, 2);
select id as o1 from flow.orders where deco_order_id = 'BL1' \gset
insert into flow.order_lines (deco_workflow_item_id, order_id, deco_line_id, sku, product_code, colour, size, supplier, qty_required, is_active) values ('BLW1', :'o1', 'BLL1', 'BL-SKU-1', 'BL1', 'Navy', 'M', 'Anyone', 3, true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000b1001', false);
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_order_buy_lines where order_ref = '#BL1') = 1, 'a team member logged in sees what an order still needs to buy');
select pg_temp.assert((select qty_needed from public.ui_order_buy_lines where order_ref = '#BL1') = 3, 'with the right quantity');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000b1002', false);
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_order_buy_lines) = 0, 'someone with no team role sees nothing through the view');
select pg_temp.assert((select count(*) from flow.po_requirements(null)) = 0, 'and nothing by calling the function directly');
reset role;
select 'buy_lines_grant_test OK' as result;
