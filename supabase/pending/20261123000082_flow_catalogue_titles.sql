-- 23 Nov 2026: catalogue titles and a list of the item codes Flow already knows (NOT APPLIED to the live project).
--  1. Each supplier price can carry a title (the supplier's own description of the item), set by the catalogue import.
--  2. public.ui_catalogue shows it.
--  3. public.ui_known_skus lists every item code Flow has seen on a stock record or an order line, so a supplier price file can be
--     narrowed to the items we actually use (a supplier file can hold 100,000 lines; Flow holds about 2,000 items).

alter table flow.supplier_offers add column if not exists title text;

-- The import already stores supplier, item code and cost; patch it in place to store the title too. An empty title never clears one
-- that is already there. The function is changed by text replacement, and fails loudly if its text is not what is expected.
do $patch$
declare v_def text := pg_get_functiondef('flow.catalogue_import(jsonb,text)'::regprocedure); v_new text;
begin
  v_new := replace(v_def,
    $a$insert into flow.supplier_offers (supplier_id, sku, unit_cost) values (v_sup, btrim(r->>'item_code'), (r->>'cost')::numeric)$a$,
    $b$insert into flow.supplier_offers (supplier_id, sku, unit_cost, title) values (v_sup, btrim(r->>'item_code'), (r->>'cost')::numeric, left(nullif(btrim(coalesce(r->>'title', '')), ''), 200))$b$);
  if v_new = v_def then raise exception 'catalogue_import: the insert statement was not found, nothing changed'; end if;
  v_def := v_new;
  v_new := replace(v_def,
    $a$on conflict (supplier_id, sku) do update set unit_cost = excluded.unit_cost, updated_at = now();$a$,
    $b$on conflict (supplier_id, sku) do update set unit_cost = excluded.unit_cost, title = coalesce(excluded.title, flow.supplier_offers.title), updated_at = now();$b$);
  if v_new = v_def then raise exception 'catalogue_import: the conflict clause was not found, nothing changed'; end if;
  execute v_new;
end $patch$;

create or replace view public.ui_catalogue with (security_invoker = true) as
select o.id, o.supplier_id, s.name as supplier, o.sku as item_code, o.unit_cost as cost, o.is_preferred, o.updated_at,
       (select si.product_name from flow.stock_items si where si.sku = o.sku limit 1) as product_name,
       o.title
from flow.supplier_offers o join flow.suppliers s on s.id = o.supplier_id;

create or replace view public.ui_known_skus with (security_invoker = true) as
  select sku from flow.stock_items where flow.is_member() and sku is not null and btrim(sku) <> ''
  union
  select sku from flow.order_lines where flow.is_member() and sku is not null and btrim(sku) <> '';

do $g$ begin
  revoke all on public.ui_known_skus from public, anon;
  grant select on public.ui_known_skus to authenticated;
end $g$;
