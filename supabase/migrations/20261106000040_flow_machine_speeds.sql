-- Machine speeds. A multi-head embroidery machine sews one piece per head at the same time, so a run of up to about
-- 7,500 stitches takes roughly 10 minutes whatever the number of heads (business rule of thumb, an average).
-- 6 heads = 6 pieces per 10 minutes = 36 pieces an hour; the single head Toyota does 6 an hour.
alter table flow.machines add column if not exists heads int not null default 1 check (heads >= 1);
update flow.machines set heads = 6, units_per_hour = 36, notes = 'Embroidery, 6 heads: about 6 pieces per 10 minute run (36 an hour) for designs up to ~7,500 stitches. Average, not exact.' where code = 'HAPPY-6';
update flow.machines set heads = 1, units_per_hour = 6, notes = 'Embroidery, 1 head: about 1 piece per 10 minute run (6 an hour) for designs up to ~7,500 stitches. Average, not exact.' where code = 'TOYOTA-1';
insert into flow.flow_settings (key, value) values ('embroidery.run_model', '{"base_stitches": 7500, "base_minutes": 10}'::jsonb) on conflict (key) do nothing;

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

do $$ begin
  revoke all on function flow.scheduler_input() from public, anon, authenticated;
  grant execute on function flow.scheduler_input() to service_role;
end $$;
