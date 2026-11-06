-- Holding pen and pipeline. Orders with something wrong (no delivery address, no due date, no lines, unrecognised decoration, artwork not ready,
-- no shipping method, or not in ATAM_FLOW at all) are put in a pen for a person to review, fix and put back into the flow, so nothing slips through.
--   * The pen is computed from the data, not a new order status. When the problem is fixed (in DecoNetwork, then the next sync) the order leaves by itself.
--   * While an order is in the pen the planner leaves it out and it cannot be dispatched or completed. The DecoNetwork status is never changed.
--   * Artwork not ready is listed on a case but does not put an order in the pen on its own (59 of ~200 live orders have it; it is the normal artwork queue).
--   * A manager/admin can "waive" one problem on one order with a reason (for example a collection with no address). Audited, reversible.
--   * pen_refresh() is the only thing that decides membership. It runs with every exception detection and before every planning run.
-- Also adds ui_pipeline: every order, one row, one stage, so the whole pipeline can be seen.

create table flow.pen_cases (
  case_key       text primary key,                 -- 'o:' || order id for orders in ATAM_FLOW, 's:' || DecoNetwork order id for orders that are not
  order_id       uuid references flow.orders(id) on delete cascade,
  deco_order_id  text not null,
  order_ref      text not null,
  customer_name  text,
  due_date       timestamptz,
  units          int,
  order_value    numeric(12,2),
  source_status  int,
  ship_address   text,                             -- snapshot of the DecoNetwork address, for the person fixing it
  shipping_method text,
  defects        jsonb not null default '[]'::jsonb,   -- [{code, severity, detail}] still open (waived ones left out)
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  cleared_at     timestamptz,                      -- set when the order no longer has an open problem (it is back in the flow)
  owner          text,
  note           text,
  note_by        text,
  note_at        timestamptz
);
create index pen_cases_open on flow.pen_cases (order_id) where cleared_at is null;

create table flow.pen_waivers (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references flow.orders(id) on delete cascade,
  defect      text not null,
  reason      text not null,
  waived_by   text not null,
  waived_at   timestamptz not null default now(),
  revoked_at  timestamptz,
  revoked_by  text,
  revoke_reason text
);
create unique index pen_waivers_active on flow.pen_waivers (order_id, defect) where revoked_at is null;

create table flow.pen_log (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  case_key  text not null,
  order_ref text not null,
  kind      text not null check (kind in ('entered','released','assigned','waived','unwaived','changed')),
  actor     text,
  detail    text
);
create index pen_log_at on flow.pen_log (at desc);

alter table flow.pen_cases enable row level security;
alter table flow.pen_waivers enable row level security;
alter table flow.pen_log enable row level security;
create policy pen_cases_read on flow.pen_cases for select to authenticated using (flow.is_member());
create policy pen_waivers_read on flow.pen_waivers for select to authenticated using (flow.is_member());
create policy pen_log_read on flow.pen_log for select to authenticated using (flow.is_member());

-- Short text for each problem: what it is, and where it is fixed.
create or replace function flow.pen_defect_label(p_code text) returns text language sql immutable set search_path = flow, public as $$
  select case p_code
    when 'no_address' then 'No delivery address'
    when 'no_due_date' then 'No due date'
    when 'no_shipping_method' then 'No shipping method'
    when 'no_lines' then 'No order lines or units'
    when 'no_decoration' then 'Decoration process not recognised'
    when 'artwork' then 'Artwork not ready'
    when 'unknown_status' then 'Unknown DecoNetwork status'
    when 'not_synced' then 'Not in ATAM_FLOW yet'
    else p_code end
$$;

-- A case needs at least one real data problem. Artwork not ready is shown on a case but never puts an order in the pen by itself:
-- it is the normal artwork queue (Artwork page, and it already blocks production).
create or replace function flow.pen_is_member(p_defects jsonb) returns boolean language sql immutable set search_path = flow, public as $$
  select exists (select 1 from jsonb_array_elements(p_defects) d where d->>'code' <> 'artwork')
$$;

-- ---------------------------------------------------------------------------
-- The one place that decides who is in the pen.
-- ---------------------------------------------------------------------------
create or replace function flow.pen_refresh() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_new int := 0; v_cleared int := 0; v_open int; r record;
begin
  if not pg_try_advisory_xact_lock(hashtext('flow.pen_refresh')) then
    return jsonb_build_object('ok', true, 'skipped', 'another refresh is running');
  end if;

  create temp table if not exists pen_cand (case_key text primary key, order_id uuid, deco_order_id text, order_ref text, customer_name text, due_date timestamptz,
    units int, order_value numeric, source_status int, ship_address text, shipping_method text, defects jsonb) on commit delete rows;
  truncate pen_cand;

  -- orders in ATAM_FLOW
  insert into pen_cand
  select 'o:' || o.id, o.id, o.deco_order_id, o.order_ref, o.customer_name, o.due_date, o.total_units, o.order_value, u.order_status, u.shipping_address, u.shipping_method,
         coalesce((select jsonb_agg(jsonb_build_object('code', d.code, 'severity', d.sev, 'detail', d.detail) order by d.rank)
                   from (values
                     (1, 'no_address', 'high', 'The delivery address is missing or too short to deliver to.',
                        u.order_id is not null and (u.shipping_method is null or u.shipping_method not ilike '%collect%')
                        and length(regexp_replace(coalesce(u.shipping_address, ''), '[,\s]', '', 'g')) < 12),
                     (2, 'no_due_date', 'high', 'There is no due or ship-by date, so it cannot be planned.', o.due_date is null),
                     (3, 'no_lines', 'high', 'The order has no lines or no units, so there is nothing to make or ship.',
                        o.total_units = 0 or not exists (select 1 from flow.order_lines l where l.order_id = o.id and l.is_active)),
                     (4, 'no_decoration', 'high', 'DecoNetwork lists decoration but none of it matches a process we know. Check the process names.',
                        cardinality(coalesce(u.processes, '{}')) > 0 and cardinality(o.decoration_methods) = 0),
                     (5, 'artwork', 'medium', coalesce((select e.description from flow.exceptions e join flow.exception_links el on el.exception_id = e.id and el.link_type = 'order' and el.ref_id = o.id
                        where e.type_code = 'artwork_blocked' and e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') limit 1), 'Artwork is not ready.'),
                        exists (select 1 from flow.exceptions e join flow.exception_links el on el.exception_id = e.id and el.link_type = 'order' and el.ref_id = o.id
                                where e.type_code = 'artwork_blocked' and e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer'))),
                     (6, 'no_shipping_method', 'medium', 'No shipping method is set, so a courier cannot be booked.', u.order_id is not null and coalesce(btrim(u.shipping_method), '') = '')
                   ) d(rank, code, sev, detail, hit)
                   where d.hit and not exists (select 1 from flow.pen_waivers w where w.order_id = o.id and w.defect = d.code and w.revoked_at is null)), '[]'::jsonb)
  from flow.orders o left join public.upcoming_orders u on u.order_id = o.deco_order_id
  where o.is_active and o.order_status <> 'dispatched';

  -- orders DecoNetwork has that ATAM_FLOW does not: a status the sync does not recognise, or open orders the sync has not picked up
  insert into pen_cand
  select 's:' || u.order_id, null, u.order_id, '#' || u.order_id, u.customer_name, u.date_due, u.total_quantity, u.billable_amount, u.order_status, u.shipping_address, u.shipping_method,
         jsonb_build_array(jsonb_build_object('code', case when m.code is null then 'unknown_status' else 'not_synced' end, 'severity', 'critical',
           'detail', case when m.code is null then 'DecoNetwork status ' || coalesce(u.order_status::text, 'blank') || ' is not in the status map, so the sync skips this order. Add the status in Settings.'
                          else 'Open in DecoNetwork (' || m.label || ') but not in ATAM_FLOW. Run the order sync; if it stays here, tell Oliver.' end))
  from public.upcoming_orders u left join flow.deco_status_map m on m.code = u.order_status
  where u.date_shipped is null and u.dismissed_at is null and (m.code is null or m.is_open)
    and not exists (select 1 from flow.orders o where o.deco_order_id = u.order_id)
    and (m.code is null or u.synced_at < now() - interval '2 hours');

  -- open or update a case for everything with an open problem
  for r in select * from pen_cand where flow.pen_is_member(defects) loop
    insert into flow.pen_cases as c (case_key, order_id, deco_order_id, order_ref, customer_name, due_date, units, order_value, source_status, ship_address, shipping_method, defects)
    values (r.case_key, r.order_id, r.deco_order_id, r.order_ref, r.customer_name, r.due_date, r.units, r.order_value, r.source_status, r.ship_address, r.shipping_method, r.defects)
    on conflict (case_key) do update set
      order_id = excluded.order_id, order_ref = excluded.order_ref, customer_name = excluded.customer_name, due_date = excluded.due_date, units = excluded.units,
      order_value = excluded.order_value, source_status = excluded.source_status, ship_address = excluded.ship_address, shipping_method = excluded.shipping_method,
      last_seen_at = now(),
      first_seen_at = case when c.cleared_at is not null then now() else c.first_seen_at end,
      owner = case when c.cleared_at is not null then null else c.owner end,
      note = case when c.cleared_at is not null then null else c.note end,
      cleared_at = null,
      defects = excluded.defects;
  end loop;

  -- log entries and releases (compare with what was open before this run)
  insert into flow.pen_log (case_key, order_ref, kind, actor, detail)
  select c.case_key, c.order_ref, 'entered', 'system', (select string_agg(flow.pen_defect_label(d->>'code'), ', ') from jsonb_array_elements(c.defects) d)
  from flow.pen_cases c where c.cleared_at is null and c.first_seen_at = now()
    and not exists (select 1 from flow.pen_log l where l.case_key = c.case_key and l.kind = 'entered' and l.at >= c.first_seen_at);
  get diagnostics v_new = row_count;

  with gone as (
    update flow.pen_cases c set cleared_at = now()
    where c.cleared_at is null and not exists (select 1 from pen_cand k where k.case_key = c.case_key and flow.pen_is_member(k.defects))
    returning c.case_key, c.order_ref)
  insert into flow.pen_log (case_key, order_ref, kind, actor, detail) select case_key, order_ref, 'released', 'system', 'No open problems left: back in the flow' from gone;
  get diagnostics v_cleared = row_count;

  select count(*) into v_open from flow.pen_cases where cleared_at is null;
  return jsonb_build_object('ok', true, 'in_pen', v_open, 'entered', v_new, 'released', v_cleared);
end $$;

-- ---------------------------------------------------------------------------
-- Actions (service role, called by the Operations actions workflow)
-- ---------------------------------------------------------------------------
create or replace function flow.pen_assign(p_case text, p_owner text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.pen_cases;
begin
  select * into c from flow.pen_cases where case_key = p_case and cleared_at is null;
  if c.case_key is null then return jsonb_build_object('ok', false, 'error', 'That order is not in the holding pen (it may already have been released).'); end if;
  if coalesce(btrim(p_owner), '') = '' and coalesce(btrim(p_note), '') = '' then return jsonb_build_object('ok', false, 'error', 'Give an owner or a note.'); end if;
  update flow.pen_cases set owner = nullif(btrim(coalesce(p_owner, '')), ''), note = nullif(btrim(coalesce(p_note, '')), ''), note_by = p_actor, note_at = now() where case_key = p_case;
  insert into flow.pen_log (case_key, order_ref, kind, actor, detail) values (c.case_key, c.order_ref, 'assigned', p_actor, concat_ws(' · ', nullif(btrim(coalesce(p_owner, '')), ''), nullif(btrim(coalesce(p_note, '')), '')));
  return jsonb_build_object('ok', true, 'order_ref', c.order_ref);
end $$;

create or replace function flow.pen_waive(p_order uuid, p_defect text, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_res jsonb;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if p_defect not in ('no_address','no_due_date','no_shipping_method','no_lines','no_decoration','artwork') then return jsonb_build_object('ok', false, 'error', 'That problem cannot be waived.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why this is fine to ignore (at least a few words).'); end if;
  if exists (select 1 from flow.pen_waivers where order_id = p_order and defect = p_defect and revoked_at is null) then return jsonb_build_object('ok', false, 'error', 'That problem is already waived for this order.'); end if;
  insert into flow.pen_waivers (order_id, defect, reason, waived_by) values (p_order, p_defect, btrim(p_reason), p_actor);
  insert into flow.pen_log (case_key, order_ref, kind, actor, detail) values ('o:' || o.id, o.order_ref, 'waived', p_actor, flow.pen_defect_label(p_defect) || ': ' || btrim(p_reason));
  perform flow.wh_audit(p_actor, 'pen_waive', 'order', o.order_ref, null, jsonb_build_object('defect', p_defect), p_reason);
  v_res := flow.pen_refresh();
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'refresh', v_res, 'still_in_pen', exists (select 1 from flow.pen_cases where case_key = 'o:' || o.id and cleared_at is null));
end $$;

create or replace function flow.pen_unwaive(p_order uuid, p_defect text, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_res jsonb;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why (at least a few words).'); end if;
  update flow.pen_waivers set revoked_at = now(), revoked_by = p_actor, revoke_reason = btrim(p_reason) where order_id = p_order and defect = p_defect and revoked_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'That problem is not waived.'); end if;
  insert into flow.pen_log (case_key, order_ref, kind, actor, detail) values ('o:' || o.id, o.order_ref, 'unwaived', p_actor, flow.pen_defect_label(p_defect) || ': ' || btrim(p_reason));
  perform flow.wh_audit(p_actor, 'pen_unwaive', 'order', o.order_ref, jsonb_build_object('defect', p_defect), null, p_reason);
  v_res := flow.pen_refresh();
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'refresh', v_res);
end $$;

-- "Put it back": re-check now (after a sync or a waiver) and say what is still wrong. Releasing itself is automatic once nothing is wrong.
create or replace function flow.pen_recheck(p_case text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.pen_cases; v_res jsonb;
begin
  v_res := flow.pen_refresh();
  select * into c from flow.pen_cases where case_key = p_case;
  if c.case_key is null then return jsonb_build_object('ok', false, 'error', 'That order was never in the holding pen.'); end if;
  return jsonb_build_object('ok', true, 'order_ref', c.order_ref, 'released', c.cleared_at is not null, 'remaining', case when c.cleared_at is null then c.defects else '[]'::jsonb end, 'refresh', v_res);
end $$;

-- ---------------------------------------------------------------------------
-- Blocking: planner, dispatch and completion
-- ---------------------------------------------------------------------------
create or replace function flow.in_pen(p_order uuid) returns boolean language sql stable set search_path = flow, public as $$
  select exists (select 1 from flow.pen_cases where order_id = p_order and cleared_at is null)
$$;

-- order_blocking_exceptions already feeds order_completion_check (completion and dispatch); the pen is added as one more blocker.
create or replace function flow.order_blocking_exceptions(p_order uuid, p_block text default 'completion') returns jsonb
language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x.j order by x.rank, x.at), '[]'::jsonb) from (
    select jsonb_build_object('id', e.id, 'exc_ref', e.exc_ref, 'type', e.type_code, 'severity', e.severity, 'status', e.status, 'description', e.description) as j,
           flow.exc_sev_rank(e.severity) as rank, e.detected_at as at
    from flow.exceptions e join flow.exception_links el on el.exception_id = e.id and el.link_type = 'order' and el.ref_id = p_order
    where e.status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer') and p_block = any (e.blocks)
    union all
    select jsonb_build_object('id', null, 'exc_ref', 'HOLDING-PEN', 'type', 'order_in_pen', 'severity', 'high', 'status', 'open',
             'description', 'In the holding pen: ' || (select string_agg(flow.pen_defect_label(d->>'code'), ', ') from jsonb_array_elements(c.defects) d) || '. Fix it, then it is released.'),
           flow.exc_sev_rank('high'), c.first_seen_at
    from flow.pen_cases c where c.order_id = p_order and c.cleared_at is null and p_block in ('completion', 'dispatch', 'production')
  ) x
$$;

-- Planner: leave pen orders out, and refresh the pen first so a brand-new bad order is caught in the same run. Rebased on the live definitions.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.scheduler_input()'::regprocedure) into v_def;
  if v_def not like '%pen_cases%' then
    v_def := replace(v_def, 'and flow.order_scope(o) not in (''third_party'', ''out_of_scope'')',
                            'and flow.order_scope(o) not in (''third_party'', ''out_of_scope'') and not flow.in_pen(o.id)');
    if v_def not like '%pen_cases%' and v_def not like '%in_pen%' then raise exception 'scheduler_input scope line not found; update migration'; end if;
    execute v_def;
  end if;
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%pen_refresh%' then
    v_def := replace(v_def, '  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? ''error'');',
      E'  begin\n    v_res := v_res || jsonb_build_array(jsonb_build_object(''detector'', ''detector:pen'', ''result'', flow.pen_refresh()));\n  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object(''detector'', ''detector:pen'', ''error'', sqlerrm));\n  end;\n  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? ''error'');');
    if v_def not like '%pen_refresh%' then raise exception 'exceptions_detect_all anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

create or replace function public.flow_scheduler_input() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  perform flow.pen_refresh();
  return flow.scheduler_input();
end $$;

-- ---------------------------------------------------------------------------
-- Dashboard read models
-- ---------------------------------------------------------------------------
create or replace view public.ui_pen with (security_invoker = true) as
select c.case_key, c.order_id, c.order_ref, c.deco_order_id, c.customer_name, c.due_date, c.units, c.order_value, c.source_status, c.ship_address, c.shipping_method,
       c.defects, jsonb_array_length(c.defects) as problem_count,
       (select max(case d->>'severity' when 'critical' then 4 when 'high' then 3 when 'medium' then 2 else 1 end) from jsonb_array_elements(c.defects) d) as severity_rank,
       (select string_agg(d->>'code', ',') from jsonb_array_elements(c.defects) d) as codes,
       (c.order_id is not null) as in_flow, c.first_seen_at, round(extract(epoch from (now() - c.first_seen_at)) / 3600, 1) as age_hours,
       c.owner, c.note, c.note_by, c.note_at,
       (c.due_date is not null and c.due_date < now()) as is_overdue,
       coalesce((select jsonb_agg(jsonb_build_object('defect', w.defect, 'reason', w.reason, 'by', w.waived_by, 'at', w.waived_at)) from flow.pen_waivers w where w.order_id = c.order_id and w.revoked_at is null), '[]'::jsonb) as waived
from flow.pen_cases c where c.cleared_at is null;

create or replace view public.ui_pen_log with (security_invoker = true) as
select id, at, case_key, order_ref, kind, actor, detail from flow.pen_log;

-- One row per order, one stage each. The pen wins, then on hold / blocked, then where the work actually is.
create or replace view flow.v_pipeline with (security_invoker = true) as
with base as (
  select o.id as order_id, o.deco_order_id, o.order_ref, o.customer_name, o.due_date, o.total_units as units, o.order_value, o.order_status::text as order_status,
         o.priority, o.is_vip, o.shipped_at, flow.order_scope(o) as scope,
         r.tp_status::text as tp_status, pr.name as producer, o.status_reason
  from flow.orders o
  left join lateral (select r2.tp_status, r2.producer_id from flow.production_routes r2 where r2.order_id = o.id and r2.kind = 'third_party' and r2.route_status = 'confirmed' order by r2.created_at desc limit 1) r on true
  left join flow.producers pr on pr.id = r.producer_id
  where (o.is_active and o.order_status <> 'dispatched') or (o.shipped_at is not null and o.shipped_at >= now() - interval '7 days')
), staged as (
  select b.*,
         case when b.shipped_at is not null or b.order_status = 'dispatched' then 'shipped'
              when b.order_status = 'on_hold' then 'on_hold'
              when b.order_status = 'blocked' then 'blocked'
              when b.tp_status in ('dispatched_to_producer','received_by_producer','in_production_at_producer','production_complete_at_producer','awaiting_return','in_transit_back') then 'with_producer'
              when b.tp_status in ('ready_to_send','picked_for_producer','packed_for_producer') then 'to_producer'
              when b.tp_status in ('returned_to_warehouse','return_checked','ready_for_dispatch','dispatched_to_customer','completed') then 'ready_for_dispatch'
              when b.order_status = 'awaiting_stock' then 'awaiting_stock'
              when b.order_status = 'stock_allocated' then 'stock_secured'
              when b.order_status = 'ready_for_production' then 'ready_for_production'
              when b.order_status = 'in_production' then 'in_production'
              when b.order_status = 'quality_check' then 'quality_check'
              when b.order_status = 'ready_for_dispatch' then 'ready_for_dispatch'
              else 'awaiting_stock' end as real_stage
  from base b
)
select s.order_id::text as row_key, s.order_id, s.order_ref, s.customer_name, s.due_date, s.units, s.order_value, s.priority, s.is_vip, s.scope, s.tp_status, s.producer,
       case when p.case_key is not null and s.real_stage <> 'shipped' then 'pen' else s.real_stage end as stage,
       s.real_stage, (p.case_key is not null) as in_pen, coalesce(jsonb_array_length(p.defects), 0) as pen_problems,
       (s.due_date is not null and s.due_date < date_trunc('day', now()) and s.real_stage <> 'shipped') as is_overdue,
       case when s.due_date is null then null else (s.due_date::date - (now() at time zone 'Europe/London')::date) end as days_to_due,
       s.status_reason as reason, true as in_flow
from staged s left join flow.pen_cases p on p.order_id = s.order_id and p.cleared_at is null
union all
select c.case_key, null, c.order_ref, c.customer_name, c.due_date, c.units, c.order_value, 0, false, 'unclassified', null, null,
       'pen', 'pen', true, jsonb_array_length(c.defects), (c.due_date is not null and c.due_date < date_trunc('day', now())),
       case when c.due_date is null then null else (c.due_date::date - (now() at time zone 'Europe/London')::date) end, 'Not in ATAM_FLOW', false
from flow.pen_cases c where c.cleared_at is null and c.order_id is null;
create or replace view public.ui_pipeline with (security_invoker = true) as select * from flow.v_pipeline;

-- Wrappers for n8n
create or replace function public.flow_pen_refresh() returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pen_refresh() $$;
create or replace function public.flow_pen_assign(p_case text, p_owner text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pen_assign(p_case, p_owner, p_note, p_actor) $$;
create or replace function public.flow_pen_waive(p_order uuid, p_defect text, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pen_waive(p_order, p_defect, p_reason, p_actor) $$;
create or replace function public.flow_pen_unwaive(p_order uuid, p_defect text, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pen_unwaive(p_order, p_defect, p_reason, p_actor) $$;
create or replace function public.flow_pen_recheck(p_case text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pen_recheck(p_case, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_pen_refresh()', 'public.flow_pen_assign(text,text,text,text)', 'public.flow_pen_waive(uuid,text,text,text)', 'public.flow_pen_unwaive(uuid,text,text,text)', 'public.flow_pen_recheck(text,text)',
      'flow.pen_refresh()', 'flow.pen_assign(text,text,text,text)', 'flow.pen_waive(uuid,text,text,text)', 'flow.pen_unwaive(uuid,text,text,text)', 'flow.pen_recheck(text,text)', 'flow.scheduler_input()', 'flow.exceptions_detect_all()', 'public.flow_scheduler_input()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach f in array array['public.flow_pen_refresh()', 'public.flow_pen_assign(text,text,text,text)', 'public.flow_pen_waive(uuid,text,text,text)', 'public.flow_pen_unwaive(uuid,text,text,text)', 'public.flow_pen_recheck(text,text)', 'public.flow_scheduler_input()']
  loop execute format('grant execute on function %s to service_role', f); end loop;
  revoke all on function flow.in_pen(uuid), flow.pen_defect_label(text), flow.pen_is_member(jsonb) from public, anon;
  grant execute on function flow.in_pen(uuid), flow.pen_defect_label(text), flow.pen_is_member(jsonb) to authenticated, service_role;
  revoke all on flow.pen_cases, flow.pen_waivers, flow.pen_log from public, anon;
  grant select on flow.pen_cases, flow.pen_waivers, flow.pen_log, flow.v_pipeline to authenticated;
  revoke all on public.ui_pen, public.ui_pen_log, public.ui_pipeline from public, anon;
  grant select on public.ui_pen, public.ui_pen_log, public.ui_pipeline to authenticated;
end $$;
