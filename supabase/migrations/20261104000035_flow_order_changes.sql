-- Order changes after the fact (R8) and manual overrides (R10, the safe subset: hold / release / priority).
-- Every change DecoNetwork makes to an order we are already working on is logged with the effect it has,
-- and must be reviewed before the order can ship. Holds and priority changes are audited with the previous value and a reason.

alter table flow.orders add column if not exists status_before_hold text;

create table flow.order_changes (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references flow.orders(id),
  order_ref     text,
  field         text not null,
  label         text not null,
  old_value     text,
  new_value     text,
  detected_at   timestamptz not null default now(),
  status_at_change text,
  severity      text not null check (severity in ('info', 'warning', 'high')),
  status        text not null default 'new' check (status in ('new', 'reviewed', 'accepted', 'dismissed')),
  reviewed_by   text,
  reviewed_at   timestamptz,
  review_note   text
);
create index order_changes_order on flow.order_changes (order_id, detected_at desc);
create index order_changes_new on flow.order_changes (order_id) where status = 'new';
alter table flow.order_changes enable row level security;
create policy order_changes_read on flow.order_changes for select to authenticated using (flow.is_member());

-- Is real work already tied to this order? (reserved stock, a consignment, a bin, a started job)
create or replace function flow.oc_is_protected(p_order uuid) returns boolean language sql stable set search_path = flow, public as $$
  select exists (select 1 from flow.orders o where o.id = p_order and o.order_status in ('stock_allocated', 'ready_for_production', 'in_production', 'quality_check', 'ready_for_dispatch'))
      or exists (select 1 from flow.allocations a where a.order_id = p_order and a.status = 'active')
      or exists (select 1 from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where i.order_id = p_order and m.status not in ('cancelled', 'closed'))
      or exists (select 1 from flow.bin_assignments b where b.order_id = p_order and b.released_at is null)
$$;

create or replace function flow.log_order_change() returns trigger language plpgsql security definer set search_path = flow, public as $$
declare v_prot boolean; v_n int := 0;
begin
  if tg_op <> 'UPDATE' then return new; end if;
  v_prot := flow.oc_is_protected(new.id);
  if new.due_date is distinct from old.due_date and old.due_date is not null and (new.due_date at time zone 'Europe/London')::date is distinct from (old.due_date at time zone 'Europe/London')::date then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'due_date', 'Dispatch date', to_char(old.due_date at time zone 'Europe/London', 'DD Mon YYYY'), to_char(new.due_date at time zone 'Europe/London', 'DD Mon YYYY'), old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if new.total_units is distinct from old.total_units and old.total_units > 0 then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'total_units', 'Total units', old.total_units::text, new.total_units::text, old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if new.deco_status is distinct from old.deco_status and new.deco_status in (4, 6, 7) then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'deco_status', 'DecoNetwork status', coalesce((select label from flow.deco_status_map where code = old.deco_status), old.deco_status::text), coalesce((select label from flow.deco_status_map where code = new.deco_status), new.deco_status::text), old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if old.is_active and not new.is_active and new.shipped_at is null then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'is_active', 'Order no longer open in DecoNetwork', 'open', 'closed or removed', old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if new.shipping_method is distinct from old.shipping_method and old.shipping_method is not null then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'shipping_method', 'Shipping method', old.shipping_method, new.shipping_method, old.order_status::text, 'info'); v_n := v_n + 1;
  end if;
  if v_n > 0 and new.label_status = 'printed' and (new.due_date is distinct from old.due_date or new.total_units is distinct from old.total_units or new.shipping_method is distinct from old.shipping_method) then
    new.label_status := 'reprint_needed';
  end if;
  return new;
end $$;
create trigger orders_log_change before update on flow.orders for each row execute function flow.log_order_change();

create or replace function flow.log_order_line_change() returns trigger language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_prot boolean;
begin
  select * into o from flow.orders where id = new.order_id;
  if o.id is null or o.created_at > now() - interval '15 minutes' then return new; end if;
  v_prot := flow.oc_is_protected(o.id);
  if tg_op = 'INSERT' then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (o.id, o.order_ref, 'line_added', 'Line added', null, format('%s x %s', new.qty_required, coalesce(new.sku, new.product_name)), o.order_status::text, case when v_prot then 'high' else 'warning' end);
  elsif new.qty_required is distinct from old.qty_required and old.qty_required > 0 then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (o.id, o.order_ref, 'line_qty', 'Line quantity: ' || coalesce(new.sku, new.product_name), old.qty_required::text, new.qty_required::text, o.order_status::text, case when v_prot then 'high' else 'warning' end);
  elsif new.sku is distinct from old.sku and old.sku is not null then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (o.id, o.order_ref, 'line_sku', 'Line changed SKU', old.sku, new.sku, o.order_status::text, case when v_prot then 'high' else 'warning' end);
  elsif old.is_active and not new.is_active then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (o.id, o.order_ref, 'line_removed', 'Line removed', format('%s x %s', old.qty_required, coalesce(old.sku, old.product_name)), null, o.order_status::text, case when v_prot then 'high' else 'warning' end);
  end if;
  return new;
end $$;
create trigger order_lines_log_change after insert or update on flow.order_lines for each row execute function flow.log_order_line_change();

-- What a change touches, and what to do about it
create or replace function flow.oc_impact(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare o flow.orders; v_alloc int; v_movs jsonb; v_bins jsonb; v_labels int; v_steps int; v_started int; v_packs int; v_rework int; v_acts jsonb := '[]'::jsonb; c record; v_fields text[] := '{}';
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  select coalesce(sum(qty), 0)::int into v_alloc from flow.allocations where order_id = p_order and status = 'active';
  select coalesce(jsonb_agg(distinct m.movement_code), '[]'::jsonb) into v_movs from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where i.order_id = p_order and m.status not in ('cancelled', 'closed');
  select coalesce(jsonb_agg(b.bin_code), '[]'::jsonb) into v_bins from flow.bin_assignments a join flow.bins b on b.id = a.bin_id where a.order_id = p_order and a.released_at is null;
  select count(*)::int into v_labels from flow.labels where order_id = p_order and print_status = 'printed';
  select count(*) filter (where status in ('pending', 'ready'))::int, count(*) filter (where status = 'in_progress')::int into v_steps, v_started from flow.job_steps where order_id = p_order;
  select count(*)::int into v_packs from flow.v_job_packs where order_ref = o.order_ref and is_stale;
  select count(*)::int into v_rework from flow.rework_jobs where order_id = p_order and status in ('open', 'in_progress');
  for c in select field, old_value, new_value from flow.order_changes where order_id = p_order and status = 'new' loop v_fields := v_fields || c.field; end loop;
  if 'due_date' = any (v_fields) then v_acts := v_acts || jsonb_build_array('Re-plan production to check the new dispatch date still fits, and tell the customer if it has moved.'); end if;
  if v_fields && array['total_units', 'line_qty', 'line_added'] then v_acts := v_acts || jsonb_build_array(format('Quantities changed: %s unit(s) are reserved. Re-run allocation; reduce or add to purchase orders and any consignment if the amount changed.', v_alloc)); end if;
  if v_fields && array['line_removed', 'is_active'] or (o.deco_status in (4, 6)) then v_acts := v_acts || jsonb_build_array('Stop work on the removed items: release reserved stock, cancel consignments not yet dispatched, free the bins and withdraw the labels. Anything already with a producer or decorated has to be recovered or written off by a person.'); end if;
  if o.deco_status = 7 or 'deco_status' = any (v_fields) and o.deco_status = 7 then v_acts := v_acts || jsonb_build_array('The order is on hold in DecoNetwork: pause production and any consignment, and find out why before restarting.'); end if;
  if v_fields && array['line_sku'] then v_acts := v_acts || jsonb_build_array('A SKU changed: stock reserved against the old SKU is now wrong. Re-run allocation and check purchase orders and the producer job sheet.'); end if;
  if v_labels > 0 and v_fields && array['due_date', 'total_units', 'shipping_method', 'line_qty', 'line_added'] then v_acts := v_acts || jsonb_build_array(format('%s printed label(s) are now out of date: generate and reprint them.', v_labels)); end if;
  if v_packs > 0 then v_acts := v_acts || jsonb_build_array('A producer job pack is out of date: rebuild it and send the new version.'); end if;
  if v_started > 0 then v_acts := v_acts || jsonb_build_array(format('%s job step(s) are already in progress. The planner will not move them: speak to the floor before anything changes.', v_started)); end if;
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'status', o.order_status, 'allocated_units', v_alloc, 'consignments', v_movs, 'bins', v_bins, 'printed_labels', v_labels, 'steps_waiting', v_steps, 'steps_in_progress', v_started, 'stale_job_packs', v_packs, 'open_rework', v_rework, 'actions', v_acts);
end $$;

create or replace function flow.oc_review(p_id uuid, p_status text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.order_changes;
begin
  select * into c from flow.order_changes where id = p_id;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'Change not found.'); end if;
  if p_status not in ('reviewed', 'accepted', 'dismissed') then return jsonb_build_object('ok', false, 'error', 'Status must be reviewed, accepted or dismissed.'); end if;
  if c.status <> 'new' then return jsonb_build_object('ok', false, 'error', 'That change has already been dealt with.'); end if;
  if c.severity = 'high' and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'This change hit work that was already under way. Say what you did about it (at least a few words).'); end if;
  update flow.order_changes set status = p_status, reviewed_by = p_actor, reviewed_at = now(), review_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_id;
  perform flow.wh_audit(p_actor, 'order_change_' || p_status, 'order', c.order_ref, jsonb_build_object('field', c.field, 'old', c.old_value, 'new', c.new_value), null, p_note);
  return jsonb_build_object('ok', true, 'remaining', (select count(*) from flow.order_changes where order_id = c.order_id and status = 'new'));
end $$;

-- review every open change on one order at once (same rules)
create or replace function flow.oc_review_order(p_order uuid, p_status text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r record; v_res jsonb; v_n int := 0;
begin
  if not exists (select 1 from flow.order_changes where order_id = p_order and status = 'new') then return jsonb_build_object('ok', false, 'error', 'Nothing to review on that order.'); end if;
  if exists (select 1 from flow.order_changes where order_id = p_order and status = 'new' and severity = 'high') and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what you did about the changes (at least a few words).'); end if;
  for r in select id from flow.order_changes where order_id = p_order and status = 'new' loop v_res := flow.oc_review(r.id, p_status, p_note, p_actor); if (v_res->>'ok')::boolean then v_n := v_n + 1; end if; end loop;
  return jsonb_build_object('ok', true, 'reviewed', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- Manual overrides: hold, release, priority (previous value kept, reason required, audited)
-- ---------------------------------------------------------------------------
create or replace function flow.ov_hold_order(p_order uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if o.order_status = 'dispatched' or o.shipped_at is not null then return jsonb_build_object('ok', false, 'error', 'That order has already shipped.'); end if;
  if o.order_status = 'on_hold' then return jsonb_build_object('ok', false, 'error', o.order_ref || ' is already on hold.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the order is being held (at least a few words).'); end if;
  if exists (select 1 from flow.job_steps where order_id = p_order and status = 'in_progress') then
    return jsonb_build_object('ok', false, 'error', o.order_ref || ' has a job in progress on the floor. Stop or finish that job first, then hold the order.');
  end if;
  update flow.orders set status_before_hold = o.order_status::text, order_status = 'on_hold', status_reason = btrim(p_reason) where id = p_order;
  perform flow.wh_audit(p_actor, 'order_held', 'order', o.order_ref, jsonb_build_object('status', o.order_status, 'reason', o.status_reason), jsonb_build_object('status', 'on_hold'), p_reason);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'was', o.order_status, 'replan_needed', true);
end $$;

create or replace function flow.ov_release_order(p_order uuid, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_back text;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if o.order_status <> 'on_hold' then return jsonb_build_object('ok', false, 'error', o.order_ref || ' is not on hold.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the hold is being lifted.'); end if;
  v_back := coalesce(nullif(o.status_before_hold, ''), 'awaiting_stock');
  update flow.orders set order_status = v_back::flow.order_status, status_before_hold = null, status_reason = null where id = p_order;
  perform flow.wh_audit(p_actor, 'order_released', 'order', o.order_ref, jsonb_build_object('status', 'on_hold', 'reason', o.status_reason), jsonb_build_object('status', v_back), p_note);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'restored', v_back, 'replan_needed', true);
end $$;

create or replace function flow.ov_set_priority(p_order uuid, p_priority int, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if p_priority is null or p_priority not between 0 and 3 then return jsonb_build_object('ok', false, 'error', 'Priority must be 0 (normal), 1 (high), 2 (rush) or 3 (critical).'); end if;
  if p_priority = o.priority then return jsonb_build_object('ok', false, 'error', 'It is already at that priority.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the priority is changing (at least a few words).'); end if;
  update flow.orders set priority = p_priority, priority_note = btrim(p_reason) where id = p_order;
  perform flow.wh_audit(p_actor, 'order_priority', 'order', o.order_ref, jsonb_build_object('priority', o.priority, 'note', o.priority_note), jsonb_build_object('priority', p_priority), p_reason);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'from', o.priority, 'to', p_priority, 'replan_needed', true);
end $$;

-- ---------------------------------------------------------------------------
-- Exception: an unreviewed change to work already under way blocks dispatch until someone has looked at it
-- ---------------------------------------------------------------------------
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('order_changed', 'Order changed after work began', 'order', 'high', '{completion,dispatch}', 'manager', 'Look at what changed and what it touches (reserved stock, purchase orders, consignments, bins, labels, job packs), act on it, and record what you did.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_order_changes() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', 'order_changed', 'key', 'ochg:' || g.order_id,
    'description', format('%s changed after work began: %s', g.order_ref, g.summary),
    'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', g.order_id)),
    'opts', jsonb_build_object('severity', case when g.due_soon then 'critical' else 'high' end, 'root_cause', 'customer', 'detected_by', 'automation', 'blocks', jsonb_build_array('completion', 'dispatch'), 'source_type', 'order_change', 'source_id', g.order_id::text))), '[]'::jsonb)
  from (select c.order_id, c.order_ref, string_agg(c.label || ': ' || coalesce(c.old_value, '(none)') || ' → ' || coalesce(c.new_value, '(none)'), '; ' order by c.detected_at) as summary,
               bool_or(o.due_date < now() + interval '3 days') as due_soon
        from flow.order_changes c join flow.orders o on o.id = c.order_id where c.status = 'new' and c.severity = 'high' and o.shipped_at is null group by c.order_id, c.order_ref) g
$$;

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
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('order_id', order_id, 'method_code', method_code,
                  'pin_rank', pin_rank, 'note', note, 'set_by', set_by)) from flow.schedule_overrides), '[]'::jsonb)
  )
$$;
create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime','quality','producer_risk','order_changes'] loop
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
-- Read models, wrappers, grants
-- ---------------------------------------------------------------------------
create or replace view public.ui_order_changes with (security_invoker = true) as
select c.id, c.order_id, c.order_ref, o.customer_name, o.due_date, o.order_status, c.field, c.label, c.old_value, c.new_value, c.detected_at, c.status_at_change, c.severity, c.status, c.reviewed_by, c.reviewed_at, c.review_note
from flow.order_changes c join flow.orders o on o.id = c.order_id;
create or replace function public.ui_oc_impact(p_order uuid) returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when flow.is_member() then flow.oc_impact(p_order) else '{}'::jsonb end $$;
create or replace function public.flow_oc_review(p_id uuid, p_status text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.oc_review(p_id, p_status, p_note, p_actor) $$;
create or replace function public.flow_oc_review_order(p_order uuid, p_status text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.oc_review_order(p_order, p_status, p_note, p_actor) $$;
create or replace function public.flow_ov_hold_order(p_order uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.ov_hold_order(p_order, p_reason, p_actor) $$;
create or replace function public.flow_ov_release_order(p_order uuid, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.ov_release_order(p_order, p_note, p_actor) $$;
create or replace function public.flow_ov_set_priority(p_order uuid, p_priority int, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.ov_set_priority(p_order, p_priority, p_reason, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_oc_review(uuid,text,text,text)', 'public.flow_oc_review_order(uuid,text,text,text)', 'public.flow_ov_hold_order(uuid,text,text)', 'public.flow_ov_release_order(uuid,text,text)', 'public.flow_ov_set_priority(uuid,int,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.oc_review(uuid,text,text,text)', 'flow.oc_review_order(uuid,text,text,text)', 'flow.oc_impact(uuid)', 'flow.oc_is_protected(uuid)', 'flow.ov_hold_order(uuid,text,text)', 'flow.ov_release_order(uuid,text,text)', 'flow.ov_set_priority(uuid,int,text,text)', 'flow.exc_detect_order_changes()', 'flow.log_order_change()', 'flow.log_order_line_change()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  revoke all on public.ui_order_changes from public, anon; grant select on public.ui_order_changes to authenticated;
  revoke all on function public.ui_oc_impact(uuid) from public, anon; grant execute on function public.ui_oc_impact(uuid) to authenticated;
end $$;
