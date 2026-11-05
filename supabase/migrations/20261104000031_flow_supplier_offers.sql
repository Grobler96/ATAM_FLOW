-- Supplier offers by hand: what a supplier can supply, at what cost and lead time. Feeds shortage advice and the selection engine.
create or replace function flow.offer_set(p_supplier uuid, p_sku text, p_unit_cost numeric, p_lead_days numeric, p_min_qty int default 1, p_stock int default null, p_supplier_sku text default null, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare su flow.suppliers;
begin
  select * into su from flow.suppliers where id = p_supplier and is_active;
  if su.id is null then return jsonb_build_object('ok', false, 'error', 'Supplier not found or inactive.'); end if;
  if coalesce(btrim(p_sku), '') = '' then return jsonb_build_object('ok', false, 'error', 'A SKU is required.'); end if;
  if not exists (select 1 from flow.stock_items where sku = btrim(p_sku)) then return jsonb_build_object('ok', false, 'error', btrim(p_sku) || ' is not a known stock item.'); end if;
  if p_unit_cost is not null and p_unit_cost < 0 then return jsonb_build_object('ok', false, 'error', 'The cost cannot be negative.'); end if;
  if p_lead_days is not null and (p_lead_days < 0 or p_lead_days > 99) then return jsonb_build_object('ok', false, 'error', 'Lead time must be between 0 and 99 days.'); end if;
  if coalesce(p_min_qty, 1) < 1 then return jsonb_build_object('ok', false, 'error', 'Minimum quantity must be at least 1.'); end if;
  if p_stock is not null and p_stock < 0 then return jsonb_build_object('ok', false, 'error', 'Stock available cannot be negative (use 0 for out of stock).'); end if;
  insert into flow.supplier_offers (supplier_id, sku, supplier_sku, unit_cost, min_qty, stock_available, lead_time_days) values (p_supplier, btrim(p_sku), nullif(btrim(coalesce(p_supplier_sku, '')), ''), p_unit_cost, coalesce(p_min_qty, 1), p_stock, p_lead_days)
  on conflict (supplier_id, sku) do update set supplier_sku = excluded.supplier_sku, unit_cost = excluded.unit_cost, min_qty = excluded.min_qty, stock_available = excluded.stock_available, lead_time_days = excluded.lead_time_days, updated_at = now();
  perform flow.wh_audit(p_actor, 'supplier_offer_set', 'supplier', su.code, null, jsonb_build_object('sku', btrim(p_sku), 'unit_cost', p_unit_cost, 'lead_days', p_lead_days, 'stock', p_stock), null);
  return jsonb_build_object('ok', true, 'supplier', su.name, 'sku', btrim(p_sku));
end $$;

create or replace view public.ui_supplier_offers with (security_invoker = true) as
select o.id, o.supplier_id, s.name as supplier, o.sku, o.supplier_sku, o.unit_cost, o.min_qty, o.stock_available, coalesce(o.lead_time_days, s.lead_time_days) as lead_days, o.updated_at
from flow.supplier_offers o join flow.suppliers s on s.id = o.supplier_id;

create or replace function public.flow_offer_set(p_supplier uuid, p_sku text, p_unit_cost numeric, p_lead_days numeric, p_min_qty int, p_stock int, p_supplier_sku text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.offer_set(p_supplier, p_sku, p_unit_cost, p_lead_days, p_min_qty, p_stock, p_supplier_sku, p_actor) $$;

do $$
begin
  revoke all on function public.flow_offer_set(uuid,text,numeric,numeric,int,int,text,text) from public, anon, authenticated;
  grant execute on function public.flow_offer_set(uuid,text,numeric,numeric,int,int,text,text) to service_role;
  revoke all on function flow.offer_set(uuid,text,numeric,numeric,int,int,text,text) from public, anon, authenticated;
  revoke all on public.ui_supplier_offers from public, anon;
  grant select on public.ui_supplier_offers to authenticated;
end $$;
