-- Assign each job (order x method step) to an operator and, optionally, to a specific machine.
-- A chosen machine is a fixed instruction to the planner; the operator is recorded for the floor (the planner does not
-- plan people's hours). Both are audited; choosing a machine other than the planner's pick needs a reason.
alter table flow.job_steps
  add column if not exists operator_id uuid references flow.operators(id),
  add column if not exists assigned_machine_id uuid references flow.machines(id),
  add column if not exists assignment_reason text,
  add column if not exists assigned_by text,
  add column if not exists assigned_at timestamptz;

create or replace function flow.js_set_machine(p_order uuid, p_method text, p_machine uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare js flow.job_steps; m flow.machines; o flow.orders;
begin
  select * into js from flow.job_steps where order_id = p_order and method_code = p_method;
  if js.id is null then return jsonb_build_object('ok', false, 'error', 'That job has not been planned yet. Re-plan production first.'); end if;
  select * into o from flow.orders where id = p_order;
  if js.status in ('in_progress', 'complete') then return jsonb_build_object('ok', false, 'error', 'The job is ' || replace(js.status, '_', ' ') || ', so its machine cannot be changed.'); end if;
  if p_machine is null then
    if js.assigned_machine_id is null then return jsonb_build_object('ok', false, 'error', 'No machine was chosen for this job.'); end if;
    update flow.job_steps set assigned_machine_id = null, assignment_reason = null, assigned_by = p_actor, assigned_at = now() where id = js.id;
    perform flow.wh_audit(p_actor, 'job_machine_cleared', 'order', o.order_ref, jsonb_build_object('method', p_method, 'machine', js.assigned_machine_id), null, p_reason);
    return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'replan_needed', true);
  end if;
  select * into m from flow.machines where id = p_machine;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Machine not found.'); end if;
  if m.method_code <> p_method then return jsonb_build_object('ok', false, 'error', m.name || ' does ' || replace(m.method_code, '_', ' ') || ', not ' || replace(p_method, '_', ' ') || '.'); end if;
  if not m.is_active then return jsonb_build_object('ok', false, 'error', m.name || ' is switched off.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why this job goes on ' || m.name || ' (at least a few words).'); end if;
  update flow.job_steps set assigned_machine_id = m.id, assignment_reason = btrim(p_reason), assigned_by = p_actor, assigned_at = now() where id = js.id;
  perform flow.wh_audit(p_actor, 'job_machine_set', 'order', o.order_ref, jsonb_build_object('method', p_method, 'machine', js.assigned_machine_id, 'planned', js.machine_id), jsonb_build_object('machine', m.id, 'code', m.code), p_reason);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'machine', m.name, 'replan_needed', true);
end $$;

create or replace function flow.js_set_operator(p_order uuid, p_method text, p_operator uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare js flow.job_steps; op flow.operators; o flow.orders;
begin
  select * into js from flow.job_steps where order_id = p_order and method_code = p_method;
  if js.id is null then return jsonb_build_object('ok', false, 'error', 'That job has not been planned yet. Re-plan production first.'); end if;
  if js.status = 'complete' then return jsonb_build_object('ok', false, 'error', 'The job is complete.'); end if;
  select * into o from flow.orders where id = p_order;
  if p_operator is not null then
    select * into op from flow.operators where id = p_operator;
    if op.id is null or not op.is_active then return jsonb_build_object('ok', false, 'error', 'Operator not found or no longer active.'); end if;
  end if;
  update flow.job_steps set operator_id = p_operator, assigned_by = p_actor, assigned_at = now() where id = js.id;
  perform flow.wh_audit(p_actor, case when p_operator is null then 'job_operator_cleared' else 'job_operator_set' end, 'order', o.order_ref, jsonb_build_object('method', p_method, 'operator', js.operator_id), jsonb_build_object('operator', p_operator, 'name', op.name), null);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'operator', op.name);
end $$;

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
                  'hold_reason', coalesce((select m.block_reason from flow.deco_status_map m where m.code = o.deco_status and m.blocks_production), case when o.order_status = 'on_hold' then 'Held in ATAM_FLOW: ' || coalesce(nullif(btrim(o.status_reason), ''), 'no reason recorded') end)))
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
    'assignments', coalesce((select jsonb_agg(jsonb_build_object('order_id', order_id, 'method_code', method_code, 'machine_id', assigned_machine_id))
                from flow.job_steps where assigned_machine_id is not null and status in ('pending', 'ready', 'blocked')), '[]'::jsonb),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('order_id', order_id, 'method_code', method_code,
                  'pin_rank', pin_rank, 'note', note, 'set_by', set_by)) from flow.schedule_overrides), '[]'::jsonb)
  )
$$;

create or replace view flow.v_production_queue with (security_invoker = true) as
select js.id as step_id, js.order_id, o.order_ref, o.customer_name, o.due_date, o.priority, o.is_vip, o.order_status,
       o.risk_score, js.method_code, js.step_no, js.status, js.units, js.est_minutes, js.setup_minutes,
       js.machine_id, m.code as machine_code, js.planned_start, js.planned_end, js.sequence_position, js.recommended_position,
       (js.sequence_position is distinct from js.recommended_position) as is_overridden,
       js.is_late, js.blocked_reason, js.reason, js.score, js.score_breakdown, b.batch_code, coalesce(b.is_bottleneck, false) as is_bottleneck,
       js.operator_id, op.name as operator_name, js.assigned_machine_id, (js.assigned_machine_id is not null) as machine_chosen, js.assignment_reason
from flow.job_steps js
join flow.orders o on o.id = js.order_id
left join flow.machines m on m.id = js.machine_id
left join flow.batches b on b.id = js.batch_id
left join flow.operators op on op.id = js.operator_id;
create or replace view public.ui_production_queue with (security_invoker = true) as select * from flow.v_production_queue;

create or replace function public.flow_js_set_machine(p_order uuid, p_method text, p_machine uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.js_set_machine(p_order, p_method, p_machine, p_reason, p_actor) $$;
create or replace function public.flow_js_set_operator(p_order uuid, p_method text, p_operator uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.js_set_operator(p_order, p_method, p_operator, p_actor) $$;

do $$
begin
  revoke all on function public.flow_js_set_machine(uuid,text,uuid,text,text) from public, anon, authenticated;
  revoke all on function public.flow_js_set_operator(uuid,text,uuid,text) from public, anon, authenticated;
  grant execute on function public.flow_js_set_machine(uuid,text,uuid,text,text) to service_role;
  grant execute on function public.flow_js_set_operator(uuid,text,uuid,text) to service_role;
  revoke all on function flow.js_set_machine(uuid,text,uuid,text,text) from public, anon, authenticated;
  revoke all on function flow.js_set_operator(uuid,text,uuid,text) from public, anon, authenticated;
  revoke all on function flow.scheduler_input() from public, anon, authenticated;
  grant execute on function flow.scheduler_input() to service_role;
  revoke all on public.ui_production_queue from public, anon;
  grant select on public.ui_production_queue to authenticated;
end $$;
