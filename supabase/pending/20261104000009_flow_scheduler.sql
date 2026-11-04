-- Production scheduler: plan storage, manual overrides, input assembly, idempotent apply, dashboard view.
-- The scheduling logic itself lives in packages/engine/scheduler.js (run by n8n); Postgres supplies input and stores the plan.

alter table flow.job_steps
  add column machine_id uuid references flow.machines(id),
  add column units int,
  add column est_minutes numeric(8,1),
  add column setup_minutes numeric(8,1),
  add column planned_start timestamptz,
  add column planned_end timestamptz,
  add column score numeric(8,2),
  add column score_breakdown jsonb,
  add column reason text,
  add column sequence_position int,
  add column recommended_position int,      -- what the scheduler would do with no manual pins
  add column is_late boolean not null default false,
  add column blocked_reason text,
  add column planned_at timestamptz;
create index job_steps_queue on flow.job_steps (sequence_position) where status in ('pending','ready');
create index job_steps_machine on flow.job_steps (machine_id, planned_start);

-- Manual overrides: pin an order (or one of its processes) to the front. Never deletes the system recommendation.
create table flow.schedule_overrides (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references flow.orders(id) on delete cascade,
  method_code text references flow.production_methods(code),     -- null = every process of the order
  pin_rank    int not null default 1 check (pin_rank >= 1),        -- 1 = highest
  note        text,
  set_by      text,
  set_at      timestamptz not null default now()
);
create unique index schedule_overrides_one on flow.schedule_overrides (order_id, (coalesce(method_code, '')));
alter table flow.schedule_overrides enable row level security;
create policy schedule_overrides_read on flow.schedule_overrides for select to authenticated using (flow.is_member());
grant select on flow.schedule_overrides to authenticated;
grant all on flow.schedule_overrides to service_role;

insert into flow.flow_settings (key, value, description) values
 ('scheduling.method_order',
  '["screen_print","dtg","vinyl","dtf","uv","heat_press","embroidery","packing"]'::jsonb,
  'Physical order of processes on a multi-process order (earlier = done first). ASSUMPTION: transfers/prints before embroidery.'),
 ('scheduling.options',
  '{"stock_gate":"ignore","batch_max_changeover_min":5,"bottleneck_utilisation":0.85,
    "blocked_statuses":["missing","pending","awaiting","rejected","awaiting_approval"]}'::jsonb,
  'stock_gate: ignore | require_allocation. Batches group consecutive jobs whose changeover is at most batch_max_changeover_min.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Scheduler input (everything the engine needs, as one JSON document)
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
                  'is_active', m.is_active,
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
                  'proof_status', o.proof_status)) from open_orders o), '[]'::jsonb),
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
-- Apply a plan produced by the engine. Re-applying an identical plan changes nothing.
-- Started/finished work (in_progress, paused, complete batches/steps) is never touched.
-- ---------------------------------------------------------------------------
create or replace function flow.apply_schedule(p_plan jsonb, p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  v_run uuid; v_planned timestamptz := coalesce((p_plan->>'generated_at')::timestamptz, now());
  v_b int := 0; v_s int := 0; v_o int := 0; v_stale_b int := 0; v_stale_s int := 0;
begin
  if p_plan is null or p_plan->>'version' is null then
    return jsonb_build_object('ok', false, 'error', 'not a scheduler plan');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('flow.apply_schedule')) then
    return jsonb_build_object('ok', true, 'skipped', 'another schedule run is in progress');
  end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('scheduler', p_triggered_by) returning id into v_run;

  begin
    -- batches
    with src as (
      select * from jsonb_to_recordset(coalesce(p_plan->'batches', '[]'::jsonb)) as x(
        batch_code text, method_code text, machine_id uuid, status text, total_units int, garment_types jsonb,
        colours jsonb, est_setup_min numeric, est_run_min numeric, priority_score numeric, scheduled_start timestamptz,
        scheduled_end timestamptz, is_bottleneck boolean, sequence_position int, sequence_reason text)),
    up as (
      insert into flow.batches as b (batch_code, method_code, machine_id, status, total_units, garment_types, colours,
          est_setup_min, est_run_min, priority_score, scheduled_start, scheduled_end, is_bottleneck, sequence_position, sequence_reason)
      select batch_code, method_code, machine_id, status::flow.batch_status, total_units,
             array(select jsonb_array_elements_text(coalesce(garment_types, '[]'::jsonb))),
             array(select jsonb_array_elements_text(coalesce(colours, '[]'::jsonb))),
             est_setup_min, est_run_min, priority_score, scheduled_start, scheduled_end, is_bottleneck, sequence_position, sequence_reason
      from src
      on conflict (batch_code) do update set
        method_code = excluded.method_code, machine_id = excluded.machine_id, status = excluded.status,
        total_units = excluded.total_units, garment_types = excluded.garment_types, colours = excluded.colours,
        est_setup_min = excluded.est_setup_min, est_run_min = excluded.est_run_min, priority_score = excluded.priority_score,
        scheduled_start = excluded.scheduled_start, scheduled_end = excluded.scheduled_end,
        is_bottleneck = excluded.is_bottleneck, sequence_position = excluded.sequence_position,
        sequence_reason = excluded.sequence_reason
      where b.status in ('queued','ready','blocked')
        and (b.method_code, b.machine_id, b.status, b.total_units, b.garment_types, b.colours, b.est_setup_min, b.est_run_min,
             b.priority_score, b.scheduled_start, b.scheduled_end, b.is_bottleneck, b.sequence_position, b.sequence_reason)
          is distinct from
            (excluded.method_code, excluded.machine_id, excluded.status, excluded.total_units, excluded.garment_types,
             excluded.colours, excluded.est_setup_min, excluded.est_run_min, excluded.priority_score, excluded.scheduled_start,
             excluded.scheduled_end, excluded.is_bottleneck, excluded.sequence_position, excluded.sequence_reason)
      returning 1)
    select count(*) into v_b from up;

    -- batch membership (rebuilt for planned batches only)
    delete from flow.batch_orders bo using flow.batches b
      where bo.batch_id = b.id and b.status in ('queued','ready','blocked');
    insert into flow.batch_orders (batch_id, order_id, units)
    select b.id, (u.key)::uuid, (u.value)::int
    from jsonb_array_elements(coalesce(p_plan->'batches', '[]'::jsonb)) pb
    join flow.batches b on b.batch_code = pb->>'batch_code' and b.status in ('queued','ready','blocked')
    cross join lateral jsonb_each_text(coalesce(pb->'units_by_order', '{}'::jsonb)) u(key, value)
    on conflict do nothing;

    delete from flow.batches b where b.status in ('queued','ready','blocked')
      and not exists (select 1 from jsonb_array_elements(coalesce(p_plan->'batches', '[]'::jsonb)) pb where pb->>'batch_code' = b.batch_code);
    get diagnostics v_stale_b = row_count;

    -- steps
    with src as (
      select * from jsonb_to_recordset(coalesce(p_plan->'steps', '[]'::jsonb)) as x(
        order_id uuid, method_code text, step_no int, units int, est_minutes numeric, setup_minutes numeric, machine_id uuid,
        planned_start timestamptz, planned_end timestamptz, score numeric, score_breakdown jsonb, reason text,
        sequence_position int, recommended_position int, is_late boolean, blocked_reason text, status text, batch_code text)),
    up as (
      insert into flow.job_steps as js (order_id, method_code, step_no, status, batch_id, machine_id, units, est_minutes,
          setup_minutes, planned_start, planned_end, score, score_breakdown, reason, sequence_position, recommended_position,
          is_late, blocked_reason, planned_at)
      select s.order_id, s.method_code, s.step_no, s.status, b.id, s.machine_id, s.units, s.est_minutes, s.setup_minutes,
             s.planned_start, s.planned_end, s.score, s.score_breakdown, s.reason, s.sequence_position,
             s.recommended_position, coalesce(s.is_late, false), s.blocked_reason, v_planned
      from src s left join flow.batches b on b.batch_code = s.batch_code and b.status in ('queued','ready','blocked')
      on conflict (order_id, method_code) do update set
        step_no = excluded.step_no, status = excluded.status, batch_id = excluded.batch_id, machine_id = excluded.machine_id,
        units = excluded.units, est_minutes = excluded.est_minutes, setup_minutes = excluded.setup_minutes,
        planned_start = excluded.planned_start, planned_end = excluded.planned_end, score = excluded.score,
        score_breakdown = excluded.score_breakdown, reason = excluded.reason, sequence_position = excluded.sequence_position,
        recommended_position = excluded.recommended_position, is_late = excluded.is_late,
        blocked_reason = excluded.blocked_reason, planned_at = excluded.planned_at
      where js.status in ('pending','ready','blocked')
        and (js.step_no, js.status, js.batch_id, js.machine_id, js.units, js.est_minutes, js.setup_minutes, js.planned_start,
             js.planned_end, js.score, js.reason, js.sequence_position, js.recommended_position, js.is_late, js.blocked_reason)
          is distinct from
            (excluded.step_no, excluded.status, excluded.batch_id, excluded.machine_id, excluded.units, excluded.est_minutes,
             excluded.setup_minutes, excluded.planned_start, excluded.planned_end, excluded.score, excluded.reason,
             excluded.sequence_position, excluded.recommended_position, excluded.is_late, excluded.blocked_reason)
      returning 1)
    select count(*) into v_s from up;

    delete from flow.job_steps js where js.status in ('pending','ready','blocked')
      and not exists (select 1 from jsonb_to_recordset(coalesce(p_plan->'steps', '[]'::jsonb)) as x(order_id uuid, method_code text)
                      where x.order_id = js.order_id and x.method_code = js.method_code);
    get diagnostics v_stale_s = row_count;

    -- orders: sequence, risk and current stage are system-owned
    with src as (
      select * from jsonb_to_recordset(coalesce(p_plan->'orders', '[]'::jsonb)) as x(
        order_id uuid, sequence_position int, risk_score numeric, production_stage text)),
    up as (
      update flow.orders o set sequence_position = s.sequence_position, risk_score = s.risk_score, production_stage = s.production_stage
      from src s where o.id = s.order_id
        and (o.sequence_position, o.risk_score, o.production_stage) is distinct from (s.sequence_position, s.risk_score, s.production_stage)
      returning 1)
    select count(*) into v_o from up;
    update flow.orders o set sequence_position = null, risk_score = null, production_stage = null
      where (o.sequence_position is not null or o.risk_score is not null or o.production_stage is not null)
        and not exists (select 1 from jsonb_to_recordset(coalesce(p_plan->'orders', '[]'::jsonb)) as x(order_id uuid) where x.order_id = o.id);

    update flow.flow_runs set status = 'success', finished_at = now(),
      summary = coalesce(p_plan->'summary', '{}'::jsonb) || jsonb_build_object('batches_changed', v_b, 'steps_changed', v_s,
                'orders_changed', v_o, 'stale_batches_removed', v_stale_b, 'stale_steps_removed', v_stale_s,
                'bottleneck', p_plan->'bottleneck')
    where id = v_run;
    return jsonb_build_object('ok', true, 'run_id', v_run, 'summary', p_plan->'summary', 'bottleneck', p_plan->'bottleneck',
      'batches_changed', v_b, 'steps_changed', v_s, 'orders_changed', v_o,
      'stale_batches_removed', v_stale_b, 'stale_steps_removed', v_stale_s);
  exception when others then
    update flow.flow_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'error', sqlerrm);
  end;
end $$;

-- Manual overrides (called by the dashboard through n8n, service role only)
create or replace function flow.set_schedule_override(p_order uuid, p_method text, p_rank int, p_note text, p_by text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  insert into flow.schedule_overrides (order_id, method_code, pin_rank, note, set_by)
  values (p_order, nullif(p_method, ''), coalesce(p_rank, 1), p_note, p_by)
  on conflict (order_id, (coalesce(method_code, ''))) do update set pin_rank = excluded.pin_rank, note = excluded.note,
    set_by = excluded.set_by, set_at = now();
  insert into flow.audit_log (actor, action, entity, entity_id, after, reason)
  values (p_by, 'pin', 'schedule_override', p_order::text, jsonb_build_object('method', p_method, 'rank', p_rank), p_note);
  return jsonb_build_object('ok', true);
end $$;
create or replace function flow.clear_schedule_override(p_order uuid, p_method text, p_by text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  delete from flow.schedule_overrides where order_id = p_order and coalesce(method_code, '') = coalesce(p_method, '');
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_by, 'unpin', 'schedule_override', p_order::text, jsonb_build_object('method', p_method));
  return jsonb_build_object('ok', true);
end $$;

-- Dashboard read model: the production queue with reasons
create or replace view flow.v_production_queue with (security_invoker = true) as
select js.id as step_id, js.order_id, o.order_ref, o.customer_name, o.due_date, o.priority, o.is_vip, o.order_status,
       o.risk_score, js.method_code, js.step_no, js.status, js.units, js.est_minutes, js.setup_minutes,
       js.machine_id, m.code as machine_code, js.planned_start, js.planned_end, js.sequence_position, js.recommended_position,
       (js.sequence_position is distinct from js.recommended_position) as is_overridden,
       js.is_late, js.blocked_reason, js.reason, js.score, js.score_breakdown, b.batch_code, coalesce(b.is_bottleneck, false) as is_bottleneck
from flow.job_steps js
join flow.orders o on o.id = js.order_id
left join flow.machines m on m.id = js.machine_id
left join flow.batches b on b.id = js.batch_id;

-- Entry points for n8n (service role only; same pattern as the sync wrappers)
create or replace function public.flow_scheduler_input() returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.scheduler_input() $$;
create or replace function public.flow_apply_schedule(p_plan jsonb, p_triggered_by text default 'n8n') returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.apply_schedule(p_plan, p_triggered_by) $$;
create or replace function public.flow_set_schedule_override(p_order uuid, p_method text, p_rank int, p_note text, p_by text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.set_schedule_override(p_order, p_method, p_rank, p_note, p_by) $$;
create or replace function public.flow_clear_schedule_override(p_order uuid, p_method text, p_by text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.clear_schedule_override(p_order, p_method, p_by) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'flow.scheduler_input()', 'flow.apply_schedule(jsonb,text)', 'flow.set_schedule_override(uuid,text,int,text,text)',
    'flow.clear_schedule_override(uuid,text,text)', 'public.flow_scheduler_input()', 'public.flow_apply_schedule(jsonb,text)',
    'public.flow_set_schedule_override(uuid,text,int,text,text)', 'public.flow_clear_schedule_override(uuid,text,text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
