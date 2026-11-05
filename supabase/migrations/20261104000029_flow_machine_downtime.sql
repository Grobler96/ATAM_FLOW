-- Machine downtime: richer machine facts, downtime records (breakdown / maintenance / limited / offline, planned or not),
-- impact analysis with recovery options, a machine-down exception, and the scheduler stops planning onto a machine that is fully down.

alter table flow.machines add column if not exists location text;
alter table flow.machines add column if not exists machine_type text;
alter table flow.machines add column if not exists backup_machine_ids uuid[] not null default '{}';

create table flow.machine_downtime (
  id              uuid primary key default gen_random_uuid(),
  machine_id      uuid not null references flow.machines(id),
  kind            text not null check (kind in ('breakdown', 'maintenance', 'limited', 'offline')),
  planned         boolean not null default false,
  started_at      timestamptz not null default now(),
  expected_back_at timestamptz,
  ended_at        timestamptz,
  capacity_factor numeric(3,2) not null default 0 check (capacity_factor >= 0 and capacity_factor < 1),   -- 0 = fully down, 0.5 = half speed
  reason          text not null,
  reported_by     text,
  resolved_by     text,
  resolution_note text,
  created_at      timestamptz not null default now(),
  check (expected_back_at is null or expected_back_at > started_at),
  check (ended_at is null or ended_at >= started_at)
);
create index machine_downtime_open on flow.machine_downtime (machine_id, started_at) where ended_at is null;
alter table flow.machine_downtime enable row level security;
create policy machine_downtime_read on flow.machine_downtime for select to authenticated using (flow.is_member());

-- ---------------------------------------------------------------------------
-- Status per machine, derived from the downtime records that are in force right now
-- ---------------------------------------------------------------------------
create or replace view flow.v_machine_status with (security_invoker = true) as
select m.id as machine_id, m.code, m.name, m.method_code, m.location, m.machine_type, m.units_per_hour, m.is_active, m.notes,
       case when not m.is_active then 'retired'
            when c.n > 0 and c.min_factor = 0 then c.worst_kind
            when c.n > 0 then 'limited' else 'operational' end as status,
       coalesce(c.min_factor, 1) as capacity_factor, c.downtime_id, c.reason as status_reason, c.since, c.expected_back_at,
       (c.expected_back_at is not null and c.expected_back_at < now()) as back_overdue,
       n.next_planned_start, n.next_planned_reason,
       (select array_agg(b.code order by b.code) from flow.machines b where b.id = any (m.backup_machine_ids)) as backup_codes
from flow.machines m
left join lateral (
  select count(*) as n, min(d.capacity_factor) as min_factor,
         (array_agg(d.kind order by d.capacity_factor, d.started_at))[1] as worst_kind,
         (array_agg(d.id order by d.capacity_factor, d.started_at))[1] as downtime_id,
         (array_agg(d.reason order by d.capacity_factor, d.started_at))[1] as reason,
         min(d.started_at) as since, max(d.expected_back_at) as expected_back_at
  from flow.machine_downtime d where d.machine_id = m.id and d.ended_at is null and d.started_at <= now()) c on true
left join lateral (
  select min(d.started_at) as next_planned_start, (array_agg(d.reason order by d.started_at))[1] as next_planned_reason
  from flow.machine_downtime d where d.machine_id = m.id and d.ended_at is null and d.started_at > now()) n on true;

create or replace view flow.v_machine_downtime with (security_invoker = true) as
select d.id, d.machine_id, m.code as machine_code, m.name as machine_name, d.kind, d.planned, d.started_at, d.expected_back_at, d.ended_at, d.capacity_factor, d.reason, d.reported_by, d.resolved_by, d.resolution_note,
       (d.ended_at is null and d.started_at <= now()) as is_current, (d.ended_at is null and d.started_at > now()) as is_scheduled,
       extract(epoch from (coalesce(d.ended_at, now()) - d.started_at)) / 3600.0 as hours,
       (d.ended_at is null and d.expected_back_at is not null and d.expected_back_at < now()) as back_overdue
from flow.machine_downtime d join flow.machines m on m.id = d.machine_id;

create or replace view public.ui_machine_status with (security_invoker = true) as select * from flow.v_machine_status;
create or replace view public.ui_machine_downtime with (security_invoker = true) as select * from flow.v_machine_downtime;

-- ---------------------------------------------------------------------------
-- Impact analysis and recovery options for a downtime window
-- ---------------------------------------------------------------------------
create or replace function flow.mc_impact(p_machine uuid, p_from timestamptz default now(), p_until timestamptz default null, p_factor numeric default 0)
returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare m flow.machines; v_steps jsonb; v_alts jsonb; v_prod jsonb; v_orders jsonb; v_opts jsonb := '[]'::jsonb; v_units int; v_min numeric; v_risk int; v_horizon timestamptz;
begin
  select * into m from flow.machines where id = p_machine;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'machine not found'); end if;
  v_horizon := coalesce(p_until, p_from + interval '7 days');
  select coalesce(jsonb_agg(jsonb_build_object('step_id', js.id, 'order_id', o.id, 'order_ref', o.order_ref, 'customer', o.customer_name, 'due_date', o.due_date, 'priority', o.priority,
           'method', js.method_code, 'status', js.status, 'units', js.units, 'minutes', coalesce(js.est_minutes, 0) + coalesce(js.setup_minutes, 0), 'planned_start', js.planned_start, 'planned_end', js.planned_end,
           'already_late', js.is_late, 'at_risk', (js.is_late or o.due_date <= v_horizon + interval '1 day')) order by o.due_date nulls last, js.planned_start),
         '[]'::jsonb),
         coalesce(sum(js.units), 0)::int, coalesce(sum(coalesce(js.est_minutes, 0) + coalesce(js.setup_minutes, 0)), 0),
         count(*) filter (where js.is_late or o.due_date <= v_horizon + interval '1 day')::int
    into v_steps, v_units, v_min, v_risk
    from flow.job_steps js join flow.orders o on o.id = js.order_id
    where js.machine_id = p_machine and js.status not in ('complete')
      and (js.planned_end is null or js.planned_end >= p_from) and (js.planned_start is null or js.planned_start <= v_horizon);
  select coalesce(jsonb_agg(jsonb_build_object('machine_id', s.machine_id, 'code', s.code, 'queued_minutes', s.q, 'is_backup', s.machine_id = any (m.backup_machine_ids)) order by (s.machine_id = any (m.backup_machine_ids)) desc, s.q), '[]'::jsonb) into v_alts
    from (select ms.machine_id, ms.code, coalesce((select sum(coalesce(js.est_minutes, 0) + coalesce(js.setup_minutes, 0)) from flow.job_steps js where js.machine_id = ms.machine_id and js.status in ('pending', 'ready', 'in_progress')), 0) as q
          from flow.v_machine_status ms where ms.method_code = m.method_code and ms.machine_id <> p_machine and ms.status in ('operational', 'limited')) s;
  select coalesce(jsonb_agg(jsonb_build_object('producer_id', p.id, 'name', p.name, 'turnaround_days', p.turnaround_days, 'has_rate', exists (select 1 from flow.producer_rates r where r.producer_id = p.id and r.method = m.method_code)) order by p.turnaround_days), '[]'::jsonb) into v_prod
    from flow.producers p where p.is_active and m.method_code = any (p.capable_methods);
  select coalesce(jsonb_agg(distinct x->>'order_ref'), '[]'::jsonb) into v_orders from jsonb_array_elements(v_steps) x;

  if jsonb_array_length(v_steps) = 0 then
    v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'none', 'text', 'Nothing is planned on this machine in that window, so no jobs are affected.'));
  else
    if jsonb_array_length(v_alts) > 0 then
      v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'reroute', 'text', format('Re-plan production: %s other %s machine(s) can take the work (%s). The scheduler will move the jobs on its next run.', jsonb_array_length(v_alts), m.method_code, (select string_agg(a->>'code', ', ') from jsonb_array_elements(v_alts) a))));
    else
      v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'no_alternative', 'text', format('No other %s machine is available, so these jobs wait for this machine or go outside.', m.method_code)));
    end if;
    if jsonb_array_length(v_prod) > 0 then
      v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'outsource', 'text', format('Send work to a producer that does %s: %s.', m.method_code, (select string_agg(pr->>'name' || ' (' || (pr->>'turnaround_days') || ' day turnaround' || case when (pr->>'has_rate')::boolean then '' else ', no rate card yet' end || ')', '; ') from jsonb_array_elements(v_prod) pr))));
    end if;
    v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'resequence', 'text', 'Resequence: jobs for the nearest due dates and highest priority stay first when production is re-planned; pin a job from the Orders page if one must go first.'));
    if v_risk > 0 then
      v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'expedite', 'text', format('%s job(s) are already late or due within a day of the end of the downtime. Expedite them (overtime, another machine, or outsource) or warn the customers.', v_risk)));
    end if;
    if p_until is null then
      v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'estimate', 'text', 'No return time is known. Impact is shown for the next 7 days; add an expected return time to sharpen it.'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'machine_code', m.code, 'method', m.method_code, 'window_from', p_from, 'window_until', p_until, 'capacity_factor', p_factor,
    'steps', v_steps, 'orders', v_orders, 'units', v_units, 'minutes', round(coalesce(v_min, 0)), 'at_risk', v_risk, 'alternatives', v_alts, 'producers', v_prod, 'options', v_opts,
    'not_calculated', jsonb_build_array('cost and margin impact', 'customer message drafting'));
end $$;

-- ---------------------------------------------------------------------------
-- Report, change and end downtime
-- ---------------------------------------------------------------------------
create or replace function flow.mc_report_downtime(p_machine uuid, p_kind text, p_reason text, p_expected_back timestamptz default null, p_factor numeric default 0,
                                                    p_started timestamptz default null, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.machines; v_start timestamptz := coalesce(p_started, now()); v_factor numeric := coalesce(p_factor, 0); v_id uuid; v_current boolean; v_planned boolean; v_imp jsonb;
begin
  select * into m from flow.machines where id = p_machine;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Machine not found.'); end if;
  if not m.is_active then return jsonb_build_object('ok', false, 'error', m.code || ' is retired.'); end if;
  if p_kind not in ('breakdown', 'maintenance', 'limited', 'offline') then return jsonb_build_object('ok', false, 'error', 'Kind must be breakdown, maintenance, limited or offline.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what is wrong or what the maintenance is.'); end if;
  if p_kind = 'limited' then
    if v_factor < 0.1 or v_factor > 0.9 then return jsonb_build_object('ok', false, 'error', 'For reduced capacity give the share of normal speed between 10% and 90%.'); end if;
  else v_factor := 0; end if;
  if v_start > now() + interval '1 year' then return jsonb_build_object('ok', false, 'error', 'The start time is more than a year away.'); end if;
  if p_expected_back is not null and p_expected_back <= v_start then return jsonb_build_object('ok', false, 'error', 'The expected return must be after the start.'); end if;
  v_current := v_start <= now(); v_planned := p_kind = 'maintenance' or v_start > now();
  if v_current and exists (select 1 from flow.machine_downtime d where d.machine_id = p_machine and d.ended_at is null and d.started_at <= now()) then
    return jsonb_build_object('ok', false, 'error', m.code || ' already has an open downtime. Update it or mark it resolved first.');
  end if;
  insert into flow.machine_downtime (machine_id, kind, planned, started_at, expected_back_at, capacity_factor, reason, reported_by)
  values (p_machine, p_kind, v_planned, v_start, p_expected_back, v_factor, btrim(p_reason), p_actor) returning id into v_id;
  perform flow.wh_audit(p_actor, case when v_current then 'machine_downtime_started' else 'machine_downtime_scheduled' end, 'machine', m.code, null,
    jsonb_build_object('kind', p_kind, 'capacity_factor', v_factor, 'started_at', v_start, 'expected_back_at', p_expected_back), p_reason);
  v_imp := flow.mc_impact(p_machine, v_start, p_expected_back, v_factor);
  return jsonb_build_object('ok', true, 'downtime_id', v_id, 'machine_code', m.code, 'current', v_current, 'impact', v_imp, 'replan_needed', v_current and v_factor = 0);
end $$;

create or replace function flow.mc_update_downtime(p_id uuid, p_expected_back timestamptz, p_note text, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare d flow.machine_downtime; m flow.machines;
begin
  select * into d from flow.machine_downtime where id = p_id;
  if d.id is null then return jsonb_build_object('ok', false, 'error', 'Downtime record not found.'); end if;
  if d.ended_at is not null then return jsonb_build_object('ok', false, 'error', 'That downtime has already ended.'); end if;
  if p_expected_back is not null and p_expected_back <= d.started_at then return jsonb_build_object('ok', false, 'error', 'The expected return must be after the start.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the return time is changing.'); end if;
  select * into m from flow.machines where id = d.machine_id;
  update flow.machine_downtime set expected_back_at = p_expected_back where id = p_id;
  perform flow.wh_audit(p_actor, 'machine_downtime_updated', 'machine', m.code, jsonb_build_object('expected_back_at', d.expected_back_at), jsonb_build_object('expected_back_at', p_expected_back), p_note);
  return jsonb_build_object('ok', true, 'machine_code', m.code, 'impact', flow.mc_impact(d.machine_id, d.started_at, p_expected_back, d.capacity_factor));
end $$;

create or replace function flow.mc_resolve_downtime(p_id uuid, p_actor text, p_note text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare d flow.machine_downtime; m flow.machines; v_was_current boolean;
begin
  select * into d from flow.machine_downtime where id = p_id;
  if d.id is null then return jsonb_build_object('ok', false, 'error', 'Downtime record not found.'); end if;
  if d.ended_at is not null then return jsonb_build_object('ok', false, 'error', 'That downtime has already ended.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what was done (for example “repaired, test run OK”).'); end if;
  select * into m from flow.machines where id = d.machine_id;
  v_was_current := d.started_at <= now();
  update flow.machine_downtime set ended_at = greatest(now(), started_at), resolved_by = p_actor, resolution_note = btrim(p_note) where id = p_id;
  perform flow.wh_audit(p_actor, case when v_was_current then 'machine_downtime_ended' else 'machine_downtime_cancelled' end, 'machine', m.code, jsonb_build_object('kind', d.kind), null, p_note);
  return jsonb_build_object('ok', true, 'machine_code', m.code, 'was_current', v_was_current, 'replan_needed', v_was_current and d.capacity_factor = 0);
end $$;

-- ---------------------------------------------------------------------------
-- Machine records: create, edit, backups, retire
-- ---------------------------------------------------------------------------
create or replace function flow.mc_upsert_machine(p jsonb, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_code text := upper(btrim(coalesce(p->>'code', ''))); v_backups uuid[]; v_before jsonb; v_active boolean; v_cur flow.machines;
begin
  if p ? 'backup_codes' then
    select coalesce(array_agg(m.id), '{}') into v_backups from flow.machines m where m.code in (select upper(btrim(x)) from jsonb_array_elements_text(p->'backup_codes') x);
  end if;
  if p ? 'units_per_hour' and nullif(p->>'units_per_hour', '') is not null and (p->>'units_per_hour')::numeric <= 0 then return jsonb_build_object('ok', false, 'error', 'Units per hour must be above zero.'); end if;
  if v_id is null then
    if v_code !~ '^[A-Z0-9][A-Z0-9_-]{0,15}$' then return jsonb_build_object('ok', false, 'error', 'A machine needs a short code of letters, numbers, dash or underscore.'); end if;
    if btrim(coalesce(p->>'name', '')) = '' then return jsonb_build_object('ok', false, 'error', 'A machine needs a name.'); end if;
    if not exists (select 1 from flow.production_methods where code = p->>'method_code') then return jsonb_build_object('ok', false, 'error', 'Choose a decoration method the system knows.'); end if;
    if exists (select 1 from flow.machines where code = v_code) then return jsonb_build_object('ok', false, 'error', 'A machine with the code ' || v_code || ' already exists.'); end if;
    insert into flow.machines (code, name, method_code, units_per_hour, location, machine_type, notes, backup_machine_ids)
    values (v_code, btrim(p->>'name'), p->>'method_code', nullif(p->>'units_per_hour', '')::numeric, nullif(p->>'location', ''), nullif(p->>'machine_type', ''), nullif(p->>'notes', ''), coalesce(v_backups, '{}')) returning id into v_id;
    perform flow.wh_audit(p_actor, 'machine_created', 'machine', v_code, null, p, null);
    return jsonb_build_object('ok', true, 'machine_id', v_id, 'code', v_code, 'created', true);
  end if;
  select * into v_cur from flow.machines where id = v_id;
  if v_cur.id is null then return jsonb_build_object('ok', false, 'error', 'Machine not found.'); end if;
  v_active := coalesce((p->>'is_active')::boolean, v_cur.is_active);
  if v_cur.is_active and not v_active then
    if length(btrim(coalesce(p->>'reason', ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the machine is being retired.'); end if;
    if exists (select 1 from flow.job_steps where machine_id = v_id and status = 'in_progress') then return jsonb_build_object('ok', false, 'error', v_cur.code || ' has work in progress. Finish or move it first.'); end if;
    if exists (select 1 from flow.machine_downtime where machine_id = v_id and ended_at is null) then return jsonb_build_object('ok', false, 'error', v_cur.code || ' has open downtime. Resolve it first.'); end if;
  end if;
  v_before := to_jsonb(v_cur);
  update flow.machines set name = coalesce(nullif(btrim(p->>'name'), ''), name), location = case when p ? 'location' then nullif(p->>'location', '') else location end,
    machine_type = case when p ? 'machine_type' then nullif(p->>'machine_type', '') else machine_type end, notes = case when p ? 'notes' then nullif(p->>'notes', '') else notes end,
    units_per_hour = case when p ? 'units_per_hour' then nullif(p->>'units_per_hour', '')::numeric else units_per_hour end,
    backup_machine_ids = case when p ? 'backup_codes' then array_remove(coalesce(v_backups, '{}'), v_id) else backup_machine_ids end, is_active = v_active where id = v_id;
  perform flow.wh_audit(p_actor, case when v_cur.is_active and not v_active then 'machine_retired' else 'machine_updated' end, 'machine', v_cur.code, v_before, p, p->>'reason');
  return jsonb_build_object('ok', true, 'machine_id', v_id, 'code', v_cur.code, 'created', false, 'replan_needed', v_cur.is_active is distinct from v_active);
end $$;

-- ---------------------------------------------------------------------------
-- Scheduler: stop planning onto a machine that is fully down right now (reduced-capacity machines still plan at full speed: not modelled in the engine)
-- ---------------------------------------------------------------------------
create or replace function flow.scheduler_input() returns jsonb
language sql stable security definer set search_path = flow, public as $$
  with open_orders as (
    select o.* from flow.orders o
    where o.is_active and o.order_status not in ('dispatched','ready_for_dispatch')
      and exists (select 1 from flow.order_lines l where l.order_id = o.id and l.is_active
                  and l.qty_required - l.qty_produced > 0 and cardinality(l.decoration_methods) > 0)
  )
  select jsonb_build_object(
    'now', now(),
    'settings', jsonb_build_object(
      'weights', coalesce((select value from flow.flow_settings where key = 'scheduling.weights'), '{}'::jsonb),
      'horizon_days', coalesce((select value from flow.flow_settings where key = 'scheduling.horizon_days'), '14'::jsonb),
      'method_order', (select value from flow.flow_settings where key = 'scheduling.method_order'),
      'options', coalesce((select value from flow.flow_settings where key = 'scheduling.options'), '{}'::jsonb)
                 || jsonb_build_object('timezone', coalesce((select value from flow.flow_settings where key = 'app.timezone'), '"Europe/London"'::jsonb))),
    'machines', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'code', m.code, 'method_code', m.method_code,
                  'is_active', m.is_active and not exists (select 1 from flow.machine_downtime d where d.machine_id = m.id and d.ended_at is null and d.started_at <= now() and d.capacity_factor = 0),
                  'busy_until', (select max(js.planned_end) from flow.job_steps js where js.machine_id = m.id and js.status = 'in_progress')))
                from flow.machines m), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('machine_id', s.machine_id, 'weekday', s.weekday,
                  'start_time', s.start_time, 'end_time', s.end_time)) from flow.machine_shifts s), '[]'::jsonb),
    'methods', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'setup_minutes', setup_minutes,
                  'minutes_per_unit', minutes_per_unit)) from flow.production_methods where is_active), '[]'::jsonb),
    'changeover', coalesce((select jsonb_agg(jsonb_build_object('method_code', method_code, 'change_type', change_type,
                  'minutes', minutes)) from flow.changeover_rules), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'order_ref', o.order_ref,
                  'customer_name', o.customer_name, 'due_date', o.due_date, 'priority', o.priority, 'is_vip', o.is_vip,
                  'order_status', o.order_status, 'alloc_state', o.alloc_state, 'artwork_status', o.artwork_status,
                  'proof_status', o.proof_status, 'stock_secured', o.stock_secured,
                  'hold_reason', (select m.block_reason from flow.deco_status_map m where m.code = o.deco_status and m.blocks_production)))
                from open_orders o), '[]'::jsonb),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('order_id', s.order_id, 'method_code', s.method,
                  'units', s.units, 'run_min', s.run_min, 'colours', s.colours, 'garment_types', s.types))
                from (select l.order_id, mth.method,
                             sum(greatest(l.qty_required - l.qty_produced, 0))::int as units,
                             sum(flow.est_minutes(greatest(l.qty_required - l.qty_produced, 0), array[mth.method], l.stitches_per_piece)) as run_min,
                             coalesce(array_agg(distinct l.colour) filter (where l.colour is not null), '{}') as colours,
                             coalesce(array_agg(distinct l.garment_type) filter (where l.garment_type is not null), '{}') as types
                      from flow.order_lines l
                      join open_orders oo on oo.id = l.order_id
                      cross join lateral unnest(l.decoration_methods) as mth(method)
                      where l.is_active and l.qty_required - l.qty_produced > 0
                      group by l.order_id, mth.method) s), '[]'::jsonb),
    'fixed_steps', coalesce((select jsonb_agg(jsonb_build_object('order_id', order_id, 'method_code', method_code,
                  'status', status, 'machine_id', machine_id, 'planned_end', planned_end))
                from flow.job_steps where status in ('in_progress', 'complete')), '[]'::jsonb),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('order_id', order_id, 'method_code', method_code,
                  'pin_rank', pin_rank, 'note', note, 'set_by', set_by)) from flow.schedule_overrides), '[]'::jsonb)
  )
$$;

-- ---------------------------------------------------------------------------
-- Exception: a machine that is down raises a machine-down exception; it clears itself when the downtime ends
-- ---------------------------------------------------------------------------
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('machine_down', 'Machine down or limited', 'production', 'high', '{}', 'production', 'Check the impact, re-plan production onto other machines or outsource, and warn customers whose orders will be late.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_machine_downtime() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'type', 'machine_down', 'key', 'machdown:' || d.id,
    'description', format('%s %s: %s%s', d.machine_code, case when d.capacity_factor = 0 then 'is ' || d.kind else 'is running at ' || round(d.capacity_factor * 100) || '% speed' end, d.reason,
                          case when d.expected_back_at is not null then format(' (back %s)', to_char(d.expected_back_at at time zone 'Europe/London', 'DD Mon HH24:MI')) else ' (no return time given)' end),
    'links', jsonb_build_array(jsonb_build_object('type', 'machine', 'id', d.machine_id)),
    'opts', jsonb_build_object('severity', case when d.capacity_factor = 0 and not d.planned then 'high' when d.back_overdue then 'high' else 'medium' end,
      'root_cause', 'machine', 'detected_by', 'warehouse_user', 'blocks', '[]'::jsonb,
      'customer_impact', format('%s job(s) planned on this machine', (select count(*) from flow.job_steps js where js.machine_id = d.machine_id and js.status not in ('complete'))),
      'source_type', 'machine_downtime', 'source_id', d.id::text)) order by d.started_at), '[]'::jsonb)
  from flow.v_machine_downtime d where d.is_current and not (d.planned and d.kind = 'maintenance' and not d.back_overdue)
$$;

-- the detector run now includes machine downtime (same function as migration 22 plus one detector)
create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime'] loop
    begin
      execute format('select flow.exc_detect_%s()', d) into v_rows;
      v_res := v_res || jsonb_build_array(flow.exc_sync('detector:' || d, v_rows));
    exception when others then
      v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:' || d, 'error', sqlerrm));
      perform flow.notify('detector_failed', 'warning', 'Exception detector failed: ' || d, sqlerrm, null, null);
    end;
  end loop;
  begin
    v_res := v_res || jsonb_build_array(flow.exc_sync('detector:completed_open', flow.exc_detect_completed_open()));
  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:completed_open', 'error', sqlerrm));
  end;
  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? 'error');
  v_out := jsonb_build_object('ok', v_ok, 'at', now(), 'detectors', v_res,
    'open_now', (select count(*) from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')),
    'critical_open', (select count(*) from flow.exceptions where severity = 'critical' and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')));
  insert into flow.flow_runs (workflow, status, triggered_by, started_at, finished_at, summary, error)
  values ('exceptions', case when v_ok then 'success' else 'partial' end::flow.run_status, 'detector', v_start, clock_timestamp(),
          jsonb_build_object('open_now', v_out->'open_now', 'critical_open', v_out->'critical_open'),
          (select string_agg(x->>'detector' || ': ' || (x->>'error'), '; ') from jsonb_array_elements(v_res) x where x ? 'error'));
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Wrappers (service role) and read grants
-- ---------------------------------------------------------------------------
create or replace function public.flow_mc_report_downtime(p_machine uuid, p_kind text, p_reason text, p_expected_back timestamptz, p_factor numeric, p_started timestamptz, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.mc_report_downtime(p_machine, p_kind, p_reason, p_expected_back, p_factor, p_started, p_actor) $$;
create or replace function public.flow_mc_update_downtime(p_id uuid, p_expected_back timestamptz, p_note text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.mc_update_downtime(p_id, p_expected_back, p_note, p_actor) $$;
create or replace function public.flow_mc_resolve_downtime(p_id uuid, p_actor text, p_note text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.mc_resolve_downtime(p_id, p_actor, p_note) $$;
create or replace function public.flow_mc_upsert_machine(p jsonb, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.mc_upsert_machine(p, p_actor) $$;
-- the dashboard may read an impact analysis directly (it changes nothing)
create or replace function public.ui_mc_impact(p_machine uuid, p_from timestamptz default null, p_until timestamptz default null, p_factor numeric default 0) returns jsonb
language sql stable security definer set search_path = flow, public as $$ select case when flow.is_member() then flow.mc_impact(p_machine, coalesce(p_from, now()), p_until, coalesce(p_factor, 0)) else '{}'::jsonb end $$;

do $$
declare f text; v text;
begin
  foreach f in array array['public.flow_mc_report_downtime(uuid,text,text,timestamptz,numeric,timestamptz,text)', 'public.flow_mc_update_downtime(uuid,timestamptz,text,text)',
    'public.flow_mc_resolve_downtime(uuid,text,text)', 'public.flow_mc_upsert_machine(jsonb,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.mc_impact(uuid,timestamptz,timestamptz,numeric)', 'flow.mc_report_downtime(uuid,text,text,timestamptz,numeric,timestamptz,text)', 'flow.mc_update_downtime(uuid,timestamptz,text,text)',
    'flow.mc_resolve_downtime(uuid,text,text)', 'flow.mc_upsert_machine(jsonb,text)', 'flow.exc_detect_machine_downtime()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach v in array array['ui_machine_status', 'ui_machine_downtime'] loop
    execute format('revoke all on public.%I from public, anon', v); execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
revoke all on function public.ui_mc_impact(uuid, timestamptz, timestamptz, numeric) from public, anon;
grant execute on function public.ui_mc_impact(uuid, timestamptz, timestamptz, numeric) to authenticated;
