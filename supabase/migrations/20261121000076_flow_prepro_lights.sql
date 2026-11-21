-- 21 Nov 2026: pre-production, phase D: sharper Embroidery and Stock lights (APPLIED to the live project on 21 Nov 2026).
-- Found by looking at the live data (read-only):
--   * Embroidery was red on most orders only because Flow holds no readable file for them (543 of 599 embroidery files failed to store; 93 orders have
--     none recorded), not because the embroidery was not ready. A person can now say "embroidery checked" for an order. Decided by the owner: the light is
--     green when a person has checked it OR every embroidery area is approved and stored. Checking records who and when, is audited, and can be undone.
--   * Stock was red on an order Flow had FULLY allocated (it only counted DecoNetwork's "stock secured" status). Decided by the owner: green when
--     DecoNetwork says secured OR every garment is allocated in Flow; partly allocated stays amber; nothing allocated stays red.
-- Nothing is sent and no order changes status. The check is one more fact about the order, shown on the lights.

alter table flow.orders add column embroidery_checked_by text;
alter table flow.orders add column embroidery_checked_at timestamptz;

create or replace function flow.embroidery_check(p_order uuid, p_checked boolean, p_actor text, p_note text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_actor text := coalesce(nullif(btrim(p_actor), ''), 'dashboard'); v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if p_order is null or p_checked is null then return jsonb_build_object('ok', false, 'error', 'Choose an order.'); end if;
  select * into o from flow.orders where id = p_order for update;
  if not found or not o.is_active then return jsonb_build_object('ok', false, 'error', 'That order is not active.'); end if;
  if not ('embroidery' = any (o.decoration_methods)) then return jsonb_build_object('ok', false, 'error', 'This order has no embroidery.'); end if;
  if p_checked and o.embroidery_checked_at is not null then return jsonb_build_object('ok', false, 'error', 'Embroidery is already marked as checked on this order.'); end if;
  if not p_checked and o.embroidery_checked_at is null then return jsonb_build_object('ok', false, 'error', 'Embroidery is not marked as checked on this order.'); end if;
  update flow.orders set embroidery_checked_by = case when p_checked then v_actor end, embroidery_checked_at = case when p_checked then now() end where id = p_order;
  insert into flow.audit_log (actor, action, entity, entity_id, after)
    values (v_actor, case when p_checked then 'embroidery_checked' else 'embroidery_unchecked' end, 'orders', p_order::text, jsonb_build_object('note', v_note));
  return jsonb_build_object('ok', true, 'checked', p_checked);
end $$;
create or replace function public.flow_embroidery_check(p_order uuid, p_checked boolean, p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.embroidery_check(p_order, p_checked, p_actor, p_note) $$;

create or replace view public.ui_preproduction with (security_invoker = true) as
  select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.order_status::text as order_status, flow.order_scope(o) as scope, o.total_units, o.decoration_methods,
         case when di.n = 0 and not ('dtf' = any (o.decoration_methods)) then 'none' when di.n = 0 then 'red' when di.done = di.n then 'green' when di.done = 0 and di.started = 0 then 'red' else 'amber' end as prints,
         di.n as prints_items, di.units as prints_units, di.done as prints_done,
         case when not ('embroidery' = any (o.decoration_methods)) then 'none' when o.embroidery_checked_at is not null then 'green' when em.n = 0 then 'red'
              when em.approved = em.n and em.stored = em.n then 'green' when em.approved > 0 or em.stored > 0 then 'amber' else 'red' end as embroidery,
         em.n as embroidery_areas, em.approved as embroidery_approved, em.stored as embroidery_stored,
         case when o.stock_secured or o.alloc_state::text = 'full' then 'green' when o.alloc_state::text = 'partial' then 'amber' else 'red' end as stock,
         o.embroidery_checked_by, o.embroidery_checked_at
  from flow.orders o
  cross join lateral (select count(*)::int as n, coalesce(sum(i.qty), 0)::int as units, count(*) filter (where i.status = 'done')::int as done, count(*) filter (where i.status = 'in_progress')::int as started
                      from flow.dtf_items i where i.order_id = o.id and i.is_current) di
  cross join lateral (select count(*)::int as n, count(*) filter (where a.approval_status = 'approved')::int as approved, count(*) filter (where a.storage_status in ('stored', 'manual'))::int as stored
                      from flow.artwork_files a where a.order_id = o.id and a.is_current and lower(coalesce(a.process, '')) = 'embroidery') em
  where o.is_active;

do $$
declare f text;
begin
  foreach f in array array['flow.embroidery_check(uuid,boolean,text,text)', 'public.flow_embroidery_check(uuid,boolean,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_embroidery_check(uuid, boolean, text, text) to service_role;
  revoke all on public.ui_preproduction from public, anon;
  grant select on public.ui_preproduction to authenticated;
end $$;
