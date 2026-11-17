-- 14 Nov 2026: purchasing streamlined (written and tested locally, NOT yet applied to the live project).
--  1. Product catalogue: supplier + item code + cost, one preferred supplier per item (reuses flow.supplier_offers).
--  2. What each order still needs to buy, by line, with its preferred supplier and cost (for the IH / 3PD order lists and the Create PO screen).
--  3. A PO can go live straight away (option live = true): approved, and the supplier email queued (still waits for a click like every email).
--  4. Every third-party order has a decorator: DPS by default, changeable per order.

-- 1. Catalogue -----------------------------------------------------------------------------------------------------------
alter table flow.supplier_offers add column if not exists is_preferred boolean not null default false;
create unique index if not exists supplier_offers_one_preferred on flow.supplier_offers (sku) where is_preferred;

create or replace function flow.catalogue_actor() returns text language sql stable security definer set search_path = flow, public as $$
  select coalesce((select email from auth.users where id = auth.uid()), 'unknown') $$;

-- p_rows: [{supplier, item_code, cost, preferred?}]. All rows are checked first; if any is wrong nothing is imported.
-- A supplier is matched by name or code (ignoring case). Items with no preferred supplier get the cheapest one.
create or replace function flow.catalogue_import(p_rows jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r jsonb; i int := 0; v_sup uuid; v_cost numeric; v_code text; v_errs jsonb := '[]'::jsonb; v_n int := 0; v_pref int := 0; s record;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then return jsonb_build_object('ok', false, 'error', 'There are no rows to import.'); end if;
  if jsonb_array_length(p_rows) > 20000 then return jsonb_build_object('ok', false, 'error', 'Import at most 20,000 rows at a time.'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; v_code := btrim(coalesce(r->>'item_code', ''));
    select id into v_sup from flow.suppliers where is_active and (lower(name) = lower(btrim(coalesce(r->>'supplier', ''))) or lower(code) = lower(btrim(coalesce(r->>'supplier', '')))) limit 1;
    begin v_cost := nullif(btrim(coalesce(r->>'cost', '')), '')::numeric; exception when others then v_cost := -1; end;
    if v_sup is null then v_errs := v_errs || jsonb_build_array(format('Row %s: supplier "%s" is not one of our suppliers.', i, coalesce(r->>'supplier', '')));
    elsif v_code = '' then v_errs := v_errs || jsonb_build_array(format('Row %s: the item code is empty.', i));
    elsif v_cost is null or v_cost < 0 then v_errs := v_errs || jsonb_build_array(format('Row %s: the cost for %s is missing or not a number.', i, v_code));
    end if;
    exit when jsonb_array_length(v_errs) >= 25;
  end loop;
  if jsonb_array_length(v_errs) > 0 then return jsonb_build_object('ok', false, 'error', 'Nothing was imported. Fix these and try again.', 'problems', v_errs); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id into v_sup from flow.suppliers where is_active and (lower(name) = lower(btrim(r->>'supplier')) or lower(code) = lower(btrim(r->>'supplier'))) limit 1;
    insert into flow.supplier_offers (supplier_id, sku, unit_cost) values (v_sup, btrim(r->>'item_code'), (r->>'cost')::numeric)
      on conflict (supplier_id, sku) do update set unit_cost = excluded.unit_cost, updated_at = now();
    v_n := v_n + 1;
  end loop;
  -- an explicit preferred flag wins; otherwise any item without a preferred supplier gets its cheapest
  for r in select * from jsonb_array_elements(p_rows) where lower(coalesce(value->>'preferred', '')) in ('yes', 'y', 'true', '1') loop
    select id into v_sup from flow.suppliers where is_active and (lower(name) = lower(btrim(r->>'supplier')) or lower(code) = lower(btrim(r->>'supplier'))) limit 1;
    update flow.supplier_offers set is_preferred = false where sku = btrim(r->>'item_code') and is_preferred and supplier_id <> v_sup;
    update flow.supplier_offers set is_preferred = true where sku = btrim(r->>'item_code') and supplier_id = v_sup;
  end loop;
  for s in select distinct btrim(value->>'item_code') as sku from jsonb_array_elements(p_rows) loop
    if not exists (select 1 from flow.supplier_offers where sku = s.sku and is_preferred) then
      update flow.supplier_offers set is_preferred = true where id = (select id from flow.supplier_offers where sku = s.sku and unit_cost is not null order by unit_cost, updated_at limit 1);
      v_pref := v_pref + 1;
    end if;
  end loop;
  perform flow.wh_audit(p_actor, 'catalogue_import', 'catalogue', 'import', null, jsonb_build_object('rows', v_n), null);
  return jsonb_build_object('ok', true, 'rows', v_n, 'preferred_set', v_pref);
end $$;

create or replace function flow.catalogue_set_preferred(p_supplier uuid, p_sku text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if not exists (select 1 from flow.supplier_offers where supplier_id = p_supplier and sku = p_sku) then return jsonb_build_object('ok', false, 'error', 'That supplier does not have this item in the catalogue.'); end if;
  update flow.supplier_offers set is_preferred = false where sku = p_sku and is_preferred and supplier_id <> p_supplier;
  update flow.supplier_offers set is_preferred = true where sku = p_sku and supplier_id = p_supplier;
  perform flow.wh_audit(p_actor, 'catalogue_preferred', 'catalogue', p_sku, null, jsonb_build_object('supplier_id', p_supplier), null);
  return jsonb_build_object('ok', true);
end $$;

-- The screen calls these directly, signed in. The role check is inside, so they are safe to expose to signed-in users.
create or replace function public.catalogue_import(p_rows jsonb) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can change the product catalogue.'); end if;
  return flow.catalogue_import(p_rows, flow.catalogue_actor());
end $$;
create or replace function public.catalogue_set_preferred(p_supplier uuid, p_sku text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can change the product catalogue.'); end if;
  return flow.catalogue_set_preferred(p_supplier, p_sku, flow.catalogue_actor());
end $$;

create or replace view public.ui_catalogue with (security_invoker = true) as
select o.id, o.supplier_id, s.name as supplier, o.sku as item_code, o.unit_cost as cost, o.is_preferred, o.updated_at,
       (select si.product_name from flow.stock_items si where si.sku = o.sku limit 1) as product_name
from flow.supplier_offers o join flow.suppliers s on s.id = o.supplier_id;

-- 2. What each order still needs to buy -------------------------------------------------------------------------------------
-- One row per order line that still needs stock (after reservations and stock already on a PO), with the preferred supplier's cost.
create or replace view public.ui_order_buy_lines with (security_invoker = true) as
  select q.order_id, q.order_ref, q.order_line_id, q.sku, q.product_name, q.colour, q.size, q.qty_needed, o.supplier_id, s.name as supplier, o.unit_cost
  from flow.po_requirements(null) q
  left join flow.supplier_offers o on o.sku = q.sku and o.is_preferred
  left join flow.suppliers s on s.id = o.supplier_id and s.is_active
  where flow.is_member() and q.qty_needed > 0;

-- 3. Live POs ---------------------------------------------------------------------------------------------------------------
-- Approves a draft PO straight away (no approval rules) and queues the email to the supplier. The email still waits for a click unless
-- comms.settings.review_required.po_send is switched off.
create or replace function flow.po_go_live(p_po uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_a jsonb; v_e jsonb;
begin
  v_a := flow.approve_purchase_order(p_po, p_actor);
  if not coalesce((v_a->>'ok')::boolean, false) then return jsonb_build_object('live', false, 'live_error', v_a->>'error'); end if;
  v_e := flow.send_purchase_order(p_po, p_actor);
  return jsonb_build_object('live', true, 'email_queued', coalesce((v_e->>'ok')::boolean, false), 'email_note', coalesce(v_e->>'error', v_e->>'note'));
end $$;

create or replace function flow.create_po_for_orders(p_supplier uuid, p_order_ids uuid[], p_actor text, p_opts jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_lines jsonb; v_res jsonb;
begin
  select jsonb_agg(jsonb_build_object('sku', r.sku, 'qty', r.q, 'product_name', r.pn, 'garment_type', r.gt, 'brand', r.br, 'colour', r.col, 'size', r.sz, 'sources', r.src) order by r.sku)
    into v_lines
  from (select q.sku, sum(q.qty_needed)::int q, max(q.product_name) pn, max(q.garment_type) gt, max(q.brand) br, max(q.colour) col, max(q.size) sz,
               jsonb_agg(jsonb_build_object('order_line_id', q.order_line_id, 'qty', q.qty_needed)) src
        from flow.po_requirements(p_order_ids) q
        where q.qty_needed > 0 and (p_opts->'skus' is null or q.sku in (select jsonb_array_elements_text(p_opts->'skus')))
        group by q.sku) r;
  if v_lines is null then return jsonb_build_object('ok', false, 'error', 'nothing left to order for these orders (already allocated or already on a purchase order)'); end if;
  v_res := flow.create_purchase_order(p_supplier, v_lines, p_actor, p_opts);
  if coalesce((v_res->>'ok')::boolean, false) and lower(coalesce(p_opts->>'live', '')) in ('true', 't', '1', 'yes') then
    v_res := v_res || flow.po_go_live((v_res->>'po_id')::uuid, p_actor);
    if coalesce((v_res->>'live')::boolean, false) then v_res := v_res || jsonb_build_object('status', 'approved'); end if;
  end if;
  return v_res;
end $$;

-- 4. Decorator for every third-party order ----------------------------------------------------------------------------------
alter table flow.orders add column if not exists producer_id uuid references flow.producers(id);

insert into flow.flow_settings (key, value, description)
select 'third_party.default_producer', jsonb_build_object('producer_id', p.id), 'The decorator every third-party order goes to unless it is changed on the order.'
from (select id from flow.producers where upper(code) = 'DPS' or upper(name) like 'DPS%' order by (upper(code) = 'DPS') desc limit 1) p
on conflict (key) do nothing;

create or replace view public.ui_order_decorator with (security_invoker = true) as
select o.id as order_id, flow.order_scope(o) as scope, o.producer_id as chosen_producer_id,
       coalesce(o.producer_id, case when flow.order_scope(o) = 'third_party' then nullif(flow.setting('third_party.default_producer')->>'producer_id', '')::uuid end) as producer_id,
       (o.producer_id is null) as is_default
from flow.orders o where o.is_active;
create or replace view public.ui_order_decorator_named with (security_invoker = true) as
select d.*, p.name as producer_name, p.can_direct_dispatch from public.ui_order_decorator d left join flow.producers p on p.id = d.producer_id;

-- p_producer null = back to the default
create or replace function public.set_order_decorator(p_order uuid, p_producer uuid) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; pr flow.producers;
begin
  if not flow.has_role('admin', 'manager', 'production') then return jsonb_build_object('ok', false, 'error', 'Your role cannot change an order''s decorator.'); end if;
  select * into o from flow.orders where id = p_order and is_active;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if p_producer is not null then
    select * into pr from flow.producers where id = p_producer and is_active;
    if pr.id is null then return jsonb_build_object('ok', false, 'error', 'That decorator is not active.'); end if;
  end if;
  update flow.orders set producer_id = p_producer where id = p_order;
  perform flow.wh_audit(flow.catalogue_actor(), 'order_decorator', 'order', o.order_ref, jsonb_build_object('producer_id', o.producer_id), jsonb_build_object('producer_id', p_producer), null);
  return jsonb_build_object('ok', true);
end $$;

-- Permissions ---------------------------------------------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['flow.catalogue_import(jsonb,text)', 'flow.catalogue_set_preferred(uuid,text,text)', 'flow.po_go_live(uuid,text)', 'flow.catalogue_actor()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['public.catalogue_import(jsonb)', 'public.catalogue_set_preferred(uuid,text)', 'public.set_order_decorator(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  revoke all on public.ui_catalogue, public.ui_order_decorator, public.ui_order_decorator_named, public.ui_order_buy_lines from public, anon;
  grant select on public.ui_catalogue, public.ui_order_decorator, public.ui_order_decorator_named, public.ui_order_buy_lines to authenticated;
end $$;
