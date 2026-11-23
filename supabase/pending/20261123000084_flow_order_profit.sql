-- 23 Nov 2026: profit per order, and how old each supplier's prices are (NOT APPLIED to the live project).
--  1. flow.order_profit(): for every active order, the sale value of its lines (DecoNetwork's per-line price, ex VAT, from the order lines the
--     DecoNetwork sync already keeps in public.sales_order_lines) against the stock cost of the same lines (the preferred supplier's catalogue price).
--     "Margin over stock cost" = sale value - stock cost, before decoration, delivery and overheads. It is worked out only on lines that have BOTH a
--     sale price and a catalogue cost, and says how many lines are missing a cost, so an incomplete answer is never passed off as a full one.
--     Lines whose item code has an underscore (DecoNetwork's own items such as name badges, not stock) never count as "missing a cost".
--  2. public.ui_order_profit: the screen's view of it (team members only).
--  3. public.ui_supplier_price_age: when each supplier's prices were last loaded into the catalogue, to prompt the quarterly reload.

create or replace function flow.order_profit()
returns table (order_id uuid, order_ref text, sell_value numeric, stock_cost numeric, margin numeric, margin_pct numeric,
               lines int, costed_lines int, missing_cost_lines int, unpriced_sale_lines int, complete boolean)
language sql stable security definer set search_path = flow, public as $$
  with l as (
    select o.id as oid, o.order_ref as oref, ol.sku, greatest(coalesce(ol.qty_required, 0), 0) as q, s.unit_price, f.unit_cost
    from flow.orders o
    join flow.order_lines ol on ol.order_id = o.id and ol.is_active
    left join lateral (select x.unit_price from public.sales_order_lines x where x.workflow_item_id = ol.deco_workflow_item_id limit 1) s on true
    left join lateral (select y.unit_cost from flow.supplier_offers y where y.sku = ol.sku and y.is_preferred and y.unit_cost is not null limit 1) f on true
    where o.is_active and flow.is_member()
  )
  select l.oid, max(l.oref),
         round(sum(l.q * l.unit_price) filter (where l.unit_price is not null and l.unit_cost is not null), 2),
         round(sum(l.q * l.unit_cost) filter (where l.unit_price is not null and l.unit_cost is not null), 2),
         round(sum(l.q * (l.unit_price - l.unit_cost)) filter (where l.unit_price is not null and l.unit_cost is not null), 2),
         case when coalesce(sum(l.q * l.unit_price) filter (where l.unit_price is not null and l.unit_cost is not null), 0) > 0
              then round(100 * sum(l.q * (l.unit_price - l.unit_cost)) filter (where l.unit_price is not null and l.unit_cost is not null)
                         / sum(l.q * l.unit_price) filter (where l.unit_price is not null and l.unit_cost is not null), 1) end,
         count(*)::int,
         (count(*) filter (where l.unit_price is not null and l.unit_cost is not null))::int,
         (count(*) filter (where l.unit_cost is null and l.sku !~ '_'))::int,
         (count(*) filter (where l.unit_price is null))::int,
         (count(*) filter (where l.unit_cost is null and l.sku !~ '_') = 0 and count(*) filter (where l.unit_price is null) = 0)
  from l group by l.oid
$$;

create or replace view public.ui_order_profit with (security_invoker = true) as select * from flow.order_profit();

create or replace view public.ui_supplier_price_age with (security_invoker = true) as
select s.id as supplier_id, s.name as supplier, count(o.id)::int as priced_items, max(o.updated_at) as last_loaded,
       case when max(o.updated_at) is null then null else (current_date - max(o.updated_at)::date) end as days_old
from flow.suppliers s left join flow.supplier_offers o on o.supplier_id = s.id and o.unit_cost is not null
where s.is_active and flow.is_member()
group by s.id, s.name;

do $g$ begin
  revoke all on function flow.order_profit() from public, anon;
  grant execute on function flow.order_profit() to authenticated, service_role;
  revoke all on public.ui_order_profit, public.ui_supplier_price_age from public, anon;
  grant select on public.ui_order_profit, public.ui_supplier_price_age to authenticated;
end $g$;
