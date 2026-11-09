-- Scope control: what ATAM_FLOW looks after.
--  * In-house production can be switched off as a whole or per process (embroidery, heat press...). Off means the planner leaves
--    that work alone and machine problems are not raised; nothing is deleted and it can be switched back on.
--  * Every order has a scope: third_party, in_house or out_of_scope. The DecoNetwork "priority order" shield will set it once that
--    field is imported (third_party_flag); a person can always override it with a reason, and the override wins.
-- Every change is audited, needs a reason, and (for switches) previews its effect first.

create table flow.scope_switches (
  key        text primary key,
  label      text not null,
  enabled    boolean not null default true,
  sort_order int not null default 100,
  changed_by text,
  changed_at timestamptz,
  reason     text
);
insert into flow.scope_switches (key, label, sort_order) values ('inhouse.master', 'In-house production', 0);
insert into flow.scope_switches (key, label, sort_order) select 'inhouse.method.' || code, name, sort_order from flow.production_methods;
create table flow.scope_log (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  kind   text not null check (kind in ('switch', 'order')),
  target text not null,
  was    text,
  now    text,
  actor  text,
  reason text,
  preview jsonb
);
alter table flow.scope_switches enable row level security;
alter table flow.scope_log enable row level security;
create policy scope_switches_read on flow.scope_switches for select to authenticated using (flow.is_member());
create policy scope_log_read on flow.scope_log for select to authenticated using (flow.is_member());

alter table flow.orders
  add column if not exists third_party_flag boolean,
  add column if not exists scope_override text check (scope_override in ('third_party', 'in_house', 'out_of_scope')),
  add column if not exists scope_reason text,
  add column if not exists scope_by text,
  add column if not exists scope_at timestamptz;

create or replace function flow.order_scope(o flow.orders) returns text language sql stable set search_path = flow, public as $$
  select coalesce(o.scope_override, case when o.third_party_flag then 'third_party' end, 'unclassified') $$;

create or replace function flow.inhouse_on(p_method text default null) returns boolean language sql stable set search_path = flow, public as $$
  select coalesce((select enabled from flow.scope_switches where key = 'inhouse.master'), true)
     and (p_method is null or coalesce((select enabled from flow.scope_switches where key = 'inhouse.method.' || p_method), true)) $$;

-- What would flipping this switch touch? Read-only.
create or replace function flow.sc_preview(p_key text, p_enabled boolean) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare s flow.scope_switches; v_method text; v_planned int; v_orders int; v_running int; v_muted int := 0;
begin
  select * into s from flow.scope_switches where key = p_key;
  if s.key is null then return jsonb_build_object('ok', false, 'error', 'Unknown switch.'); end if;
  v_method := case when p_key like 'inhouse.method.%' then substr(p_key, length('inhouse.method.') + 1) end;
  select count(*) filter (where js.status in ('pending', 'ready', 'blocked')), count(distinct js.order_id) filter (where js.status in ('pending', 'ready', 'blocked')), count(*) filter (where js.status = 'in_progress')
    into v_planned, v_orders, v_running from flow.job_steps js where v_method is null or js.method_code = v_method;
  if p_key = 'inhouse.master' then
    select count(*) into v_muted from flow.exceptions e
      where e.status in ('open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer') and e.detector = 'detector:machine_downtime';
  end if;
  return jsonb_build_object('ok', true, 'key', p_key, 'label', s.label, 'currently', s.enabled, 'to', p_enabled, 'planned_steps', v_planned, 'orders', v_orders,
    'running_steps', v_running, 'exceptions_cleared', case when p_enabled then 0 else v_muted end,
    'blocked_by_running', (not p_enabled) and v_running > 0);
end $$;

create or replace function flow.sc_set_switch(p_key text, p_enabled boolean, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare s flow.scope_switches; pv jsonb;
begin
  select * into s from flow.scope_switches where key = p_key;
  if s.key is null then return jsonb_build_object('ok', false, 'error', 'Unknown switch.'); end if;
  if p_enabled is null then return jsonb_build_object('ok', false, 'error', 'Choose on or off.'); end if;
  if s.enabled = p_enabled then return jsonb_build_object('ok', false, 'error', s.label || ' is already ' || case when p_enabled then 'on' else 'off' end || '.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why (at least a few words). It is recorded.'); end if;
  pv := flow.sc_preview(p_key, p_enabled);
  if (pv->>'blocked_by_running')::boolean then
    return jsonb_build_object('ok', false, 'error', (pv->>'running_steps') || ' in-house job(s) are running on the floor. Finish or stop them first, then switch ' || lower(s.label) || ' off.');
  end if;
  update flow.scope_switches set enabled = p_enabled, changed_by = p_actor, changed_at = now(), reason = btrim(p_reason) where key = p_key;
  insert into flow.scope_log (kind, target, was, now, actor, reason, preview) values ('switch', p_key, case when s.enabled then 'on' else 'off' end, case when p_enabled then 'on' else 'off' end, p_actor, btrim(p_reason), pv);
  perform flow.wh_audit(p_actor, 'scope_switch', 'switch', p_key, jsonb_build_object('enabled', s.enabled), jsonb_build_object('enabled', p_enabled), p_reason);
  return jsonb_build_object('ok', true, 'label', s.label, 'enabled', p_enabled, 'preview', pv, 'replan_needed', true);
end $$;

create or replace function flow.sc_set_order_scope(p_order uuid, p_scope text, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_was text; v_open text;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if p_scope is not null and p_scope not in ('third_party', 'in_house', 'out_of_scope') then return jsonb_build_object('ok', false, 'error', 'Scope must be third_party, in_house, out_of_scope, or empty to follow DecoNetwork.'); end if;
  if p_scope is not distinct from o.scope_override then return jsonb_build_object('ok', false, 'error', 'That is already the setting.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why (at least a few words). It is recorded.'); end if;
  if o.shipped_at is not null or o.order_status = 'dispatched' then return jsonb_build_object('ok', false, 'error', 'That order has already shipped.'); end if;
  if coalesce(p_scope, case when o.third_party_flag then 'third_party' end, 'unclassified') in ('in_house', 'out_of_scope') then
    select string_agg(distinct m.movement_code, ', ') into v_open from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id
      where i.order_id = o.id and m.status not in ('cancelled', 'closed');
    if v_open is not null then return jsonb_build_object('ok', false, 'error', o.order_ref || ' has an open producer consignment (' || v_open || '). Cancel or finish it first.'); end if;
  end if;
  v_was := flow.order_scope(o);
  update flow.orders set scope_override = p_scope, scope_reason = btrim(p_reason), scope_by = p_actor, scope_at = now() where id = o.id;
  insert into flow.scope_log (kind, target, was, now, actor, reason) values ('order', o.order_ref, v_was, coalesce(p_scope, 'follow DecoNetwork'), p_actor, btrim(p_reason));
  perform flow.wh_audit(p_actor, 'order_scope', 'order', o.order_ref, jsonb_build_object('scope', v_was), jsonb_build_object('scope_override', p_scope), p_reason);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'scope', coalesce(p_scope, 'follow DecoNetwork'), 'replan_needed', true);
end $$;

create or replace function flow.scheduler_input() returns jsonb
language sql stable security definer set search_path = flow, public as $$
  with open_orders as (
    select o.* from flow.orders o
    where o.is_active and o.order_status not in ('dispatched','ready_for_dispatch')
      and flow.order_scope(o) not in ('third_party', 'out_of_scope')
      and exists (select 1 from flow.order_lines l where l.order_id = o.id and l.is_active
                  and l.qty_required - l.qty_produced > 0 and cardinality(l.decoration_methods) > 0)
  )
  select jsonb_build_object(
    'now', now(),
    'settings', jsonb_build_object(
      'weights', coalesce((select value from flow.flow_settings where key = 'scheduling.weights'), '{}'::jsonb),
      'horizon_days', coalesce((select value from flow.flow_settings where key = 'scheduling.horizon_days'), '14'::jsonb),
      'method_order', (select value from flow.flow_settings where key = 'scheduling.method_order'),
      'run_model', coalesce((select value from flow.flow_settings where key = 'embroidery.run_model'), '{"base_stitches": 7500, "base_minutes": 10}'::jsonb),
      'options', coalesce((select value from flow.flow_settings where key = 'scheduling.options'), '{}'::jsonb)
                 || jsonb_build_object('timezone', coalesce((select value from flow.flow_settings where key = 'app.timezone'), '"Europe/London"'::jsonb))),
    'machines', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'code', m.code, 'method_code', m.method_code, 'heads', m.heads,
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
                  'units', s.units, 'run_min', s.run_min, 'stitches', s.stitches, 'colours', s.colours, 'garment_types', s.types))
                from (select l.order_id, mth.method,
                             sum(greatest(l.qty_required - l.qty_produced, 0))::int as units,
                             sum(flow.est_minutes(greatest(l.qty_required - l.qty_produced, 0), array[mth.method], l.stitches_per_piece)) as run_min,
                             (sum(l.stitches_per_piece::numeric * greatest(l.qty_required - l.qty_produced, 0)) filter (where l.stitches_per_piece is not null)
                                / nullif(sum(greatest(l.qty_required - l.qty_produced, 0)) filter (where l.stitches_per_piece is not null), 0))::int as stitches,
                             coalesce(array_agg(distinct l.colour) filter (where l.colour is not null), '{}') as colours,
                             coalesce(array_agg(distinct l.garment_type) filter (where l.garment_type is not null), '{}') as types
                      from flow.order_lines l
                      join open_orders oo on oo.id = l.order_id
                      cross join lateral unnest(l.decoration_methods) as mth(method)
                      where l.is_active and l.qty_required - l.qty_produced > 0 and flow.inhouse_on(mth.method)
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

create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime','quality','producer_risk','order_changes','courier'] loop
    begin
      execute format('select flow.exc_detect_%s()', d) into v_rows;
      if d = 'machine_downtime' and not flow.inhouse_on() then v_rows := '[]'::jsonb; end if;       -- in-house production is switched off: machine problems are not our business
      v_rows := coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) e
                          where not exists (select 1 from jsonb_array_elements(coalesce(e->'links', '[]'::jsonb)) l join flow.orders o on o.id::text = l->>'id'
                                            where l->>'type' = 'order' and flow.order_scope(o) = 'out_of_scope')), '[]'::jsonb);
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

create or replace view public.ui_scope_switches with (security_invoker = true) as
  select key, label, enabled, sort_order, changed_by, changed_at, reason from flow.scope_switches;
create or replace view public.ui_scope_log with (security_invoker = true) as
  select id, at, kind, target, was, now, actor, reason from flow.scope_log;
create or replace view public.ui_order_scope with (security_invoker = true) as
  select o.id as order_id, o.order_ref, flow.order_scope(o) as scope,
         case when o.scope_override is not null then 'override' when o.third_party_flag then 'deco_flag' else 'none' end as source,
         o.third_party_flag, o.scope_override, o.scope_reason, o.scope_by, o.scope_at
  from flow.orders o;
create or replace function public.ui_sc_preview(p_key text, p_enabled boolean) returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when flow.is_member() then flow.sc_preview(p_key, p_enabled) else '{}'::jsonb end $$;
create or replace function public.flow_sc_set_switch(p_key text, p_enabled boolean, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.sc_set_switch(p_key, p_enabled, p_reason, p_actor) $$;
create or replace function public.flow_sc_set_order_scope(p_order uuid, p_scope text, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.sc_set_order_scope(p_order, p_scope, p_reason, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_sc_set_switch(text,boolean,text,text)', 'public.flow_sc_set_order_scope(uuid,text,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.sc_set_switch(text,boolean,text,text)', 'flow.sc_set_order_scope(uuid,text,text,text)', 'flow.sc_preview(text,boolean)', 'flow.scheduler_input()', 'flow.exceptions_detect_all()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  grant execute on function flow.scheduler_input() to service_role;
  -- plain read-only helpers used inside the ui_ views, so browser roles need them
  grant execute on function flow.order_scope(flow.orders), flow.inhouse_on(text) to authenticated, service_role;
  revoke all on public.ui_scope_switches, public.ui_scope_log, public.ui_order_scope from public, anon;
  grant select on public.ui_scope_switches, public.ui_scope_log, public.ui_order_scope to authenticated;
  revoke all on function public.ui_sc_preview(text,boolean) from public, anon;
  grant execute on function public.ui_sc_preview(text,boolean) to authenticated;
end $$;
