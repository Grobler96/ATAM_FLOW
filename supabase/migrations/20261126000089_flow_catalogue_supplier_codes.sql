-- 26 Nov 2026: a supplier's own item code for an item DecoNetwork has given its own number (APPLIED to the live project 26 Nov 2026 as "flow_catalogue_supplier_codes").
-- Dan found order 636967 could not be bought: its item code was DecoNetwork's own number (264928361_194082258), not Ralawise's (WM118NATUXS). About
-- 350 active order lines are like this. flow.supplier_offers already has a supplier_sku column, and raising a PO and the electronic order to Ralawise already
-- use it, but nothing could fill it in. Two changes:
--  1. The catalogue import (flow.catalogue_import, used by Catalogue > Load a supplier's price file and the CSV upload) now also stores an optional "supplier_sku"
--     for each row. A row without one never clears a code already there.
--  2. public.ui_known_sku_lines lists the items that carry a DecoNetwork number, with the style code, colour and size DecoNetwork recorded for them, so the price file
--     loader can work out the supplier's own code for each one.
-- The function is patched in place from the live text and raises if an anchor is missing, so it can never silently do nothing.
do $patch$
declare v_def text := pg_get_functiondef('flow.catalogue_import(jsonb,text)'::regprocedure); v_new text;
begin
  v_new := replace(v_def,
    $a$insert into flow.supplier_offers (supplier_id, sku, unit_cost, title) values (v_sup, btrim(r->>'item_code'), (r->>'cost')::numeric, left(nullif(btrim(coalesce(r->>'title', '')), ''), 200))$a$,
    $b$insert into flow.supplier_offers (supplier_id, sku, unit_cost, title, supplier_sku) values (v_sup, btrim(r->>'item_code'), (r->>'cost')::numeric, left(nullif(btrim(coalesce(r->>'title', '')), ''), 200), left(nullif(btrim(coalesce(r->>'supplier_sku', '')), ''), 60))$b$);
  if v_new = v_def then raise exception 'catalogue_import: the insert statement was not found, nothing changed'; end if;
  v_def := v_new;
  v_new := replace(v_def,
    $a$title = coalesce(excluded.title, flow.supplier_offers.title), updated_at = now();$a$,
    $b$title = coalesce(excluded.title, flow.supplier_offers.title), supplier_sku = coalesce(excluded.supplier_sku, flow.supplier_offers.supplier_sku), updated_at = now();$b$);
  if v_new = v_def then raise exception 'catalogue_import: the conflict clause was not found, nothing changed'; end if;
  execute v_new;
end $patch$;

create or replace view public.ui_known_sku_lines with (security_invoker = true) as
  select distinct l.sku, btrim(l.product_code) as product_code, btrim(l.colour) as colour, btrim(l.size) as size, btrim(l.supplier) as supplier
  from flow.order_lines l
  where flow.is_member() and l.is_active and l.sku ~ '^[0-9]+_[0-9]+$' and nullif(btrim(coalesce(l.product_code, '')), '') is not null;

do $g$ begin
  revoke all on public.ui_known_sku_lines from public, anon;
  grant select on public.ui_known_sku_lines to authenticated;
end $g$;
