-- 21 Nov 2026: embroidery, step 1: a register of embroidery designs (per customer), swatch statuses, and the embroidery areas on each order.
-- (APPLIED to the live project on 21 Nov 2026)
-- Before production an embroidered logo has to match its visual. A NEW logo needs a physical swatch, sent to the customer for sign-off; a logo we have
-- already done does not. This is the same for in-house and third-party orders (the screens have a tab for each).
--   * flow.emb_designs:  one row per logo per customer, with a status: known (done before), swatch_required, swatch_in_progress, swatch_sent,
--                        swatch_approved, changes_needed. A rejected swatch starts a new round.
--   * flow.emb_links:    which order area uses which design. Links are switched off, never removed, so the history stays.
--   * flow.emb_events:   every status change, who and when, and the round.
--   * public.ui_emb_areas: every embroidery area on every active order, with its design status, or a SUGGESTION when it looks like a logo we already
--                        hold for the same customer (same artwork, or same stitch count and size within 2 mm). A suggestion is only a suggestion: a person
--                        confirms it. Flow's history starts in September 2026, so older logos look new until someone marks them as done before.
--   * The Embroidery light (public.ui_preproduction) is green when a person has checked the order, when every area's design is known or swatch
--     approved, or (as before) every area is approved and stored; amber while a swatch is under way or some areas are done; red otherwise.
-- Nothing is sent and no order changes status. Staff write through the n8n "Pre-production actions" workflow (flow_emb_* functions, service role only).

create table flow.emb_designs (
  id            uuid primary key default gen_random_uuid(),
  customer_id   text not null,
  customer_name text,
  name          text not null,
  status        text not null default 'swatch_required' check (status in ('known', 'swatch_required', 'swatch_in_progress', 'swatch_sent', 'swatch_approved', 'changes_needed')),
  round         int not null default 1 check (round >= 1),
  status_by     text,
  status_at     timestamptz,
  note          text,
  created_by    text,
  created_at    timestamptz not null default now()
);
create table flow.emb_links (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references flow.orders(id) on delete cascade,
  deco_line_id text not null,
  area        text not null,
  design_id   uuid not null references flow.emb_designs(id),
  is_active   boolean not null default true,
  linked_by   text,
  linked_at   timestamptz not null default now(),
  unlinked_by text,
  unlinked_at timestamptz
);
create unique index emb_links_one_active on flow.emb_links (order_id, deco_line_id, area) where is_active;
create index emb_links_design on flow.emb_links (design_id) where is_active;
create table flow.emb_events (
  id          bigint generated always as identity primary key,
  design_id   uuid not null references flow.emb_designs(id),
  event       text not null,
  from_status text,
  to_status   text,
  round       int,
  actor       text,
  note        text,
  order_ref   text,
  at          timestamptz not null default now()
);
create index emb_events_design on flow.emb_events (design_id, at);

alter table flow.emb_designs enable row level security;
alter table flow.emb_links enable row level security;
alter table flow.emb_events enable row level security;
create policy emb_designs_read on flow.emb_designs for select to authenticated using (flow.is_member());
create policy emb_links_read on flow.emb_links for select to authenticated using (flow.is_member());
create policy emb_events_read on flow.emb_events for select to authenticated using (flow.is_member());

-- 1. Writes ---------------------------------------------------------------------------------------------------------------------------------
create or replace function flow.emb_actor(p text) returns text language sql immutable as $$ select coalesce(nullif(btrim(p), ''), 'dashboard') $$;

-- a new logo: make a design from this area (swatch required) and link the area to it
create or replace function flow.emb_create_design(p_order uuid, p_deco_line text, p_area text, p_name text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_id uuid; v_actor text := flow.emb_actor(p_actor); v_name text;
begin
  select * into o from flow.orders where id = p_order;
  if not found or not o.is_active then return jsonb_build_object('ok', false, 'error', 'That order is not active.'); end if;
  if o.customer_id is null then return jsonb_build_object('ok', false, 'error', 'This order has no customer number, so a design cannot be kept for the customer.'); end if;
  if not exists (select 1 from flow.artwork_files a where a.order_id = p_order and coalesce(a.deco_line_id, '') = coalesce(p_deco_line, '') and a.area = p_area and a.is_current and lower(coalesce(a.process, '')) = 'embroidery') then
    return jsonb_build_object('ok', false, 'error', 'That embroidery area is not on this order.'); end if;
  if exists (select 1 from flow.emb_links l where l.order_id = p_order and l.deco_line_id = coalesce(p_deco_line, '') and l.area = p_area and l.is_active) then
    return jsonb_build_object('ok', false, 'error', 'This area is already linked to a design. Unlink it first.'); end if;
  v_name := coalesce(nullif(btrim(p_name), ''), coalesce(o.customer_name, 'Customer') || ' · ' || p_area || ' · ' || o.order_ref);
  insert into flow.emb_designs (customer_id, customer_name, name, status, round, status_by, status_at, created_by) values (o.customer_id, o.customer_name, v_name, 'swatch_required', 1, v_actor, now(), v_actor) returning id into v_id;
  insert into flow.emb_links (order_id, deco_line_id, area, design_id, linked_by) values (p_order, coalesce(p_deco_line, ''), p_area, v_id, v_actor);
  insert into flow.emb_events (design_id, event, to_status, round, actor, order_ref) values (v_id, 'created', 'swatch_required', 1, v_actor, o.order_ref);
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_design_created', 'emb_designs', v_id::text, jsonb_build_object('order', o.order_ref, 'area', p_area, 'name', v_name));
  return jsonb_build_object('ok', true, 'design_id', v_id, 'status', 'swatch_required');
end $$;

-- the same logo as one we already hold: link the area to it
create or replace function flow.emb_link(p_order uuid, p_deco_line text, p_area text, p_design uuid, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; d flow.emb_designs; v_actor text := flow.emb_actor(p_actor);
begin
  select * into o from flow.orders where id = p_order;
  if not found or not o.is_active then return jsonb_build_object('ok', false, 'error', 'That order is not active.'); end if;
  select * into d from flow.emb_designs where id = p_design;
  if not found then return jsonb_build_object('ok', false, 'error', 'That design does not exist.'); end if;
  if d.customer_id is distinct from o.customer_id then return jsonb_build_object('ok', false, 'error', 'That design belongs to a different customer.'); end if;
  if not exists (select 1 from flow.artwork_files a where a.order_id = p_order and coalesce(a.deco_line_id, '') = coalesce(p_deco_line, '') and a.area = p_area and a.is_current and lower(coalesce(a.process, '')) = 'embroidery') then
    return jsonb_build_object('ok', false, 'error', 'That embroidery area is not on this order.'); end if;
  if exists (select 1 from flow.emb_links l where l.order_id = p_order and l.deco_line_id = coalesce(p_deco_line, '') and l.area = p_area and l.is_active) then
    return jsonb_build_object('ok', false, 'error', 'This area is already linked to a design. Unlink it first.'); end if;
  insert into flow.emb_links (order_id, deco_line_id, area, design_id, linked_by) values (p_order, coalesce(p_deco_line, ''), p_area, p_design, v_actor);
  insert into flow.emb_events (design_id, event, round, actor, order_ref, note) values (p_design, 'linked', d.round, v_actor, o.order_ref, p_area);
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_design_linked', 'emb_designs', p_design::text, jsonb_build_object('order', o.order_ref, 'area', p_area));
  return jsonb_build_object('ok', true, 'design_id', p_design, 'status', d.status);
end $$;

create or replace function flow.emb_unlink(p_order uuid, p_deco_line text, p_area text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare l flow.emb_links; v_actor text := flow.emb_actor(p_actor); v_ref text;
begin
  select * into l from flow.emb_links where order_id = p_order and deco_line_id = coalesce(p_deco_line, '') and area = p_area and is_active for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'This area is not linked to a design.'); end if;
  select order_ref into v_ref from flow.orders where id = p_order;
  update flow.emb_links set is_active = false, unlinked_by = v_actor, unlinked_at = now() where id = l.id;
  insert into flow.emb_events (design_id, event, actor, order_ref, note) values (l.design_id, 'unlinked', v_actor, v_ref, p_area);
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_design_unlinked', 'emb_designs', l.design_id::text, jsonb_build_object('order', v_ref, 'area', p_area));
  return jsonb_build_object('ok', true);
end $$;

-- moving a design along. A rejected swatch (changes needed) starts a new round when work starts again.
create or replace function flow.emb_set_status(p_design uuid, p_to text, p_actor text, p_note text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d flow.emb_designs; v_actor text := flow.emb_actor(p_actor); v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_round int; v_ok boolean;
begin
  select * into d from flow.emb_designs where id = p_design for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'That design does not exist.'); end if;
  if p_to not in ('known', 'swatch_required', 'swatch_in_progress', 'swatch_sent', 'swatch_approved', 'changes_needed') then return jsonb_build_object('ok', false, 'error', 'That is not a status.'); end if;
  v_ok := (d.status = 'swatch_required' and p_to in ('swatch_in_progress', 'known'))
       or (d.status = 'swatch_in_progress' and p_to in ('swatch_sent', 'swatch_approved', 'changes_needed'))
       or (d.status = 'swatch_sent' and p_to in ('swatch_approved', 'changes_needed'))
       or (d.status = 'changes_needed' and p_to = 'swatch_in_progress')
       or (d.status in ('known', 'swatch_approved') and p_to in ('swatch_required', 'changes_needed'));
  if not v_ok then return jsonb_build_object('ok', false, 'error', 'This design cannot go from "' || replace(d.status, '_', ' ') || '" to "' || replace(p_to, '_', ' ') || '".'); end if;
  if p_to in ('changes_needed', 'swatch_required') and d.status in ('known', 'swatch_approved', 'swatch_in_progress', 'swatch_sent') and v_note is null then
    return jsonb_build_object('ok', false, 'error', 'Say what needs to change.'); end if;
  v_round := case when (d.status = 'changes_needed' and p_to = 'swatch_in_progress') or (d.status in ('known', 'swatch_approved') and p_to = 'swatch_required') then d.round + 1 else d.round end;
  update flow.emb_designs set status = p_to, round = v_round, status_by = v_actor, status_at = now() where id = p_design;
  insert into flow.emb_events (design_id, event, from_status, to_status, round, actor, note) values (p_design, 'status', d.status, p_to, v_round, v_actor, v_note);
  insert into flow.audit_log (actor, action, entity, entity_id, before, after) values (v_actor, 'emb_design_status', 'emb_designs', p_design::text, jsonb_build_object('status', d.status, 'round', d.round), jsonb_build_object('status', p_to, 'round', v_round, 'note', v_note));
  return jsonb_build_object('ok', true, 'status', p_to, 'round', v_round);
end $$;

create or replace function public.flow_emb_create_design(p_order uuid, p_deco_line text, p_area text, p_name text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_create_design(p_order, p_deco_line, p_area, p_name, p_actor) $$;
create or replace function public.flow_emb_link(p_order uuid, p_deco_line text, p_area text, p_design uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_link(p_order, p_deco_line, p_area, p_design, p_actor) $$;
create or replace function public.flow_emb_unlink(p_order uuid, p_deco_line text, p_area text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_unlink(p_order, p_deco_line, p_area, p_actor) $$;
create or replace function public.flow_emb_set_status(p_design uuid, p_to text, p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_set_status(p_design, p_to, p_actor, p_note) $$;

-- 2. Reading --------------------------------------------------------------------------------------------------------------------------------
create or replace view public.ui_emb_areas with (security_invoker = true) as
  select a.id as artwork_id, o.id as order_id, o.order_ref, o.customer_id, o.customer_name, o.due_date, flow.order_scope(o) as scope, o.order_status::text as order_status,
         coalesce(a.deco_line_id, '') as deco_line_id, a.area, a.thumbnail_url, a.stitch_count, a.width_mm, a.height_mm, a.file_format, a.storage_status, a.approval_status, a.version,
         d.id as design_id, d.name as design_name, d.status as design_status, d.round as design_round, d.status_by, d.status_at,
         coalesce(d.status, 'to_review') as area_status,
         case when d.id is null then s.id end as suggested_design_id, case when d.id is null then s.name end as suggested_design_name,
         case when d.id is null then s.status end as suggested_status, case when d.id is null then s.why end as suggested_why
  from flow.artwork_files a
  join flow.orders o on o.id = a.order_id and o.is_active
  left join flow.emb_links l on l.order_id = a.order_id and l.deco_line_id = coalesce(a.deco_line_id, '') and l.area = a.area and l.is_active
  left join flow.emb_designs d on d.id = l.design_id
  left join lateral (
    select x.id, x.name, x.status, case when b.signature = a.signature then 'Same artwork' else 'Same stitch count and size' end as why
    from flow.emb_designs x
    join flow.emb_links xl on xl.design_id = x.id and xl.is_active
    join flow.artwork_files b on b.order_id = xl.order_id and coalesce(b.deco_line_id, '') = xl.deco_line_id and b.area = xl.area and b.is_current
    where l.id is null and x.customer_id = o.customer_id
      and (b.signature = a.signature or (coalesce(a.stitch_count, 0) > 0 and b.stitch_count = a.stitch_count and abs(coalesce(b.width_mm, 0) - coalesce(a.width_mm, 0)) <= 2 and abs(coalesce(b.height_mm, 0) - coalesce(a.height_mm, 0)) <= 2))
    order by (b.signature = a.signature) desc, x.created_at limit 1) s on true
  where a.is_current and lower(coalesce(a.process, '')) = 'embroidery';

create or replace view public.ui_emb_designs with (security_invoker = true) as
  select d.id, d.customer_id, d.customer_name, d.name, d.status, d.round, d.status_by, d.status_at, d.note, d.created_at,
         (select count(*)::int from flow.emb_links l where l.design_id = d.id and l.is_active) as orders_using
  from flow.emb_designs d;
create or replace view public.ui_emb_events with (security_invoker = true) as
  select e.id, e.design_id, e.event, e.from_status, e.to_status, e.round, e.actor, e.note, e.order_ref, e.at from flow.emb_events e;

-- the Embroidery light now knows about designs
create or replace view public.ui_preproduction with (security_invoker = true) as
  select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.order_status::text as order_status, flow.order_scope(o) as scope, o.total_units, o.decoration_methods,
         case when di.n = 0 and not ('dtf' = any (o.decoration_methods)) then 'none' when di.n = 0 then 'red' when di.done = di.n then 'green' when di.done = 0 and di.started = 0 then 'red' else 'amber' end as prints,
         di.n as prints_items, di.units as prints_units, di.done as prints_done,
         case when not ('embroidery' = any (o.decoration_methods)) then 'none' when o.embroidery_checked_at is not null then 'green' when em.n = 0 then 'red'
              when em.designs_ok = em.n then 'green'
              when em.approved = em.n and em.stored = em.n then 'green' when em.approved > 0 or em.stored > 0 or em.designs_ok > 0 or em.designs_busy > 0 then 'amber' else 'red' end as embroidery,
         em.n as embroidery_areas, em.approved as embroidery_approved, em.stored as embroidery_stored,
         case when o.stock_secured or o.alloc_state::text = 'full' then 'green' when o.alloc_state::text = 'partial' then 'amber' else 'red' end as stock,
         o.embroidery_checked_by, o.embroidery_checked_at
  from flow.orders o
  cross join lateral (select count(*)::int as n, coalesce(sum(i.qty), 0)::int as units, count(*) filter (where i.status = 'done')::int as done, count(*) filter (where i.status = 'in_progress')::int as started
                      from flow.dtf_items i where i.order_id = o.id and i.is_current) di
  cross join lateral (select count(*)::int as n, count(*) filter (where a.approval_status = 'approved')::int as approved, count(*) filter (where a.storage_status in ('stored', 'manual'))::int as stored,
                             count(*) filter (where d.status in ('known', 'swatch_approved'))::int as designs_ok, count(*) filter (where d.status in ('swatch_in_progress', 'swatch_sent', 'changes_needed'))::int as designs_busy
                      from flow.artwork_files a
                      left join flow.emb_links l on l.order_id = a.order_id and l.deco_line_id = coalesce(a.deco_line_id, '') and l.area = a.area and l.is_active
                      left join flow.emb_designs d on d.id = l.design_id
                      where a.order_id = o.id and a.is_current and lower(coalesce(a.process, '')) = 'embroidery') em
  where o.is_active;

do $$
declare f text;
begin
  revoke all on flow.emb_designs, flow.emb_links, flow.emb_events from public, anon, authenticated;
  grant select on flow.emb_designs, flow.emb_links, flow.emb_events to authenticated;
  revoke all on public.ui_emb_areas, public.ui_emb_designs, public.ui_emb_events from public, anon;
  grant select on public.ui_emb_areas, public.ui_emb_designs, public.ui_emb_events to authenticated;
  revoke all on public.ui_preproduction from public, anon;
  grant select on public.ui_preproduction to authenticated;
  foreach f in array array['flow.emb_actor(text)', 'flow.emb_create_design(uuid,text,text,text,text)', 'flow.emb_link(uuid,text,text,uuid,text)', 'flow.emb_unlink(uuid,text,text,text)', 'flow.emb_set_status(uuid,text,text,text)',
                           'public.flow_emb_create_design(uuid,text,text,text,text)', 'public.flow_emb_link(uuid,text,text,uuid,text)', 'public.flow_emb_unlink(uuid,text,text,text)', 'public.flow_emb_set_status(uuid,text,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_emb_create_design(uuid, text, text, text, text), public.flow_emb_link(uuid, text, text, uuid, text), public.flow_emb_unlink(uuid, text, text, text), public.flow_emb_set_status(uuid, text, text, text) to service_role;
end $$;
