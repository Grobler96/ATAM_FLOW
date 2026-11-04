-- Stock allocation: input assembly, idempotent apply, manual allocate/release, board and shortage views.
-- Logic lives in packages/engine/allocator.js (run by n8n). Postgres supplies the input and stores the result.
-- Demand = orders whose DecoNetwork status maps to 'awaiting_stock' (awaiting stock / awaiting PO) and that are not stock_secured.
-- When DecoNetwork moves an order on (e.g. to Ready for production) its reservations here are released automatically,
-- because DecoNetwork then takes the stock itself.

update flow.flow_settings set value = value || '{"fully_coverable_bonus": {"weight": 12, "note": "bonus when stock on hand plus incoming POs cover every line"}}'::jsonb
  where key = 'allocation.weights' and not (value ? 'fully_coverable_bonus');
update flow.flow_settings set value = value || '{"overdue_po_assume_days": 3}'::jsonb
  where key = 'allocation.thresholds' and not (value ? 'overdue_po_assume_days');

create or replace function flow.allocation_input() returns jsonb
language sql stable security definer set search_path = flow, public as $$
  with demand as (
    select o.* from flow.orders o
    join flow.deco_status_map m on m.code = o.deco_status and m.maps_to = 'awaiting_stock'
    where o.is_active and not o.stock_secured and o.order_status in ('awaiting_stock','stock_allocated')
  ), dl as (
    select l.*, greatest(l.qty_required - l.qty_produced, 0) as need from flow.order_lines l
    join demand d on d.id = l.order_id
    where l.is_active and l.sku is not null and l.qty_required - l.qty_produced > 0
  ), skus as (select distinct sku from dl)
  select jsonb_build_object(
    'now', now(), 'today', (now() at time zone 'Europe/London')::date,
    'settings', jsonb_build_object(
      'weights', coalesce((select value from flow.flow_settings where key = 'allocation.weights'), '{}'::jsonb),
      'thresholds', coalesce((select value from flow.flow_settings where key = 'allocation.thresholds'), '{}'::jsonb)),
    'active_methods', coalesce((select jsonb_agg(distinct method_code) from flow.machines where is_active), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'order_ref', d.order_ref, 'customer', d.customer_name,
        'due_date', (d.due_date at time zone 'Europe/London')::date, 'order_date', d.order_date, 'priority', d.priority, 'is_vip', d.is_vip,
        'order_value', d.order_value, 'methods', d.decoration_methods, 'deco_status', d.deco_status,
        'lines', (select jsonb_agg(jsonb_build_object('id', x.id, 'sku', x.sku, 'need', x.need, 'product_name', x.product_name, 'colour', x.colour,
                  'size', x.size, 'stitches_per_piece', x.stitches_per_piece) order by x.sku, x.size) from dl x where x.order_id = d.id))
        order by d.order_ref) from demand d where exists (select 1 from dl where dl.order_id = d.id)), '[]'::jsonb),
    'stock', coalesce((select jsonb_agg(jsonb_build_object('sku', s.sku, 'on_hand', greatest(s.qty_on_hand, 0))) from flow.stock_items s where s.sku in (select sku from skus)), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(jsonb_build_object('po_line_id', pl.id, 'po_number', p.po_number, 'supplier', p.supplier, 'sku', pl.sku,
        'outstanding', pl.qty_outstanding, 'expected_date', (p.expected_date at time zone 'Europe/London')::date))
        from flow.po_lines pl join flow.purchase_orders p on p.id = pl.po_id and p.is_active where pl.qty_outstanding > 0 and pl.sku in (select sku from skus)), '[]'::jsonb),
    'fixed_allocations', coalesce((select jsonb_agg(jsonb_build_object('order_line_id', a.order_line_id, 'sku', s.sku, 'source', a.source,
        'po_line_id', a.po_line_id, 'qty', a.qty)) from flow.allocations a join flow.stock_items s on s.id = a.stock_item_id
        where a.is_manual and a.status = 'active'), '[]'::jsonb)
  )
$$;

create or replace function flow.apply_allocation(p_plan jsonb, p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  v_run uuid; v_rel int := 0; v_new int := 0; v_dec int := 0; v_released_orders int := 0; v_state int := 0;
  c_zero constant uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_plan is null or p_plan->>'version' is distinct from 'alloc-1' then
    return jsonb_build_object('ok', false, 'error', 'not an allocation plan');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('flow.apply_allocation')) then
    return jsonb_build_object('ok', true, 'skipped', 'another allocation run is in progress');
  end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('allocation', p_triggered_by) returning id into v_run;

  begin
    -- SKUs on an order but unknown to inventory get a zero-quantity placeholder so reservations have somewhere to point
    insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand, is_placeholder, last_synced_at)
    select distinct on (x.sku) x.sku, x.product_name, x.colour, x.size, 0, true, now()
    from jsonb_array_elements(coalesce(p_plan->'orders', '[]'::jsonb)) o,
         jsonb_to_recordset(o->'lines') as x(sku text, product_name text, colour text, size text)
    where x.sku is not null
    on conflict (sku) do nothing;

    -- 1. release reservations that are no longer what the engine wants (manual ones are never touched)
    with tgt as (
      select t.order_line_id, si.id as stock_item_id, t.source::flow.alloc_source as source, t.po_line_id, t.qty
      from jsonb_to_recordset(coalesce(p_plan->'allocations', '[]'::jsonb)) as t(order_line_id uuid, sku text, source text, po_line_id uuid, qty int)
      join flow.stock_items si on si.sku = t.sku),
    rel as (
      update flow.allocations a set status = 'released', released_at = now(),
             reason = coalesce(a.reason, '') || ' [superseded by run ' || v_run || ']'
      where a.status = 'active' and not a.is_manual and not exists (
        select 1 from tgt where tgt.order_line_id = a.order_line_id and tgt.stock_item_id = a.stock_item_id and tgt.source = a.source
          and coalesce(tgt.po_line_id, c_zero) = coalesce(a.po_line_id, c_zero) and tgt.qty = a.qty)
      returning a.id, a.stock_item_id, a.source, a.qty),
    led as (
      insert into flow.stock_movements (stock_item_id, movement_type, qty, ref_type, ref_id, run_id, note)
      select stock_item_id, 'released', -qty, 'allocation', id::text, v_run, 'reservation released' from rel where source = 'on_hand' returning 1)
    select count(*) into v_rel from rel;

    -- 2. reserve what is new or changed
    with tgt as (
      select o.order_id, t.order_line_id, si.id as stock_item_id, t.source::flow.alloc_source as source, t.po_line_id, t.qty,
             o.reason, o.score, o.score_breakdown
      from jsonb_to_recordset(coalesce(p_plan->'allocations', '[]'::jsonb)) as t(order_id uuid, order_line_id uuid, sku text, source text, po_line_id uuid, qty int)
      join flow.stock_items si on si.sku = t.sku
      join jsonb_to_recordset(coalesce(p_plan->'orders', '[]'::jsonb)) as o(order_id uuid, reason text, score numeric, score_breakdown jsonb) on o.order_id = t.order_id),
    ins as (
      insert into flow.allocations (order_id, order_line_id, stock_item_id, source, po_line_id, qty, status, reason, score, score_breakdown, run_id, created_by)
      select t.order_id, t.order_line_id, t.stock_item_id, t.source, t.po_line_id, t.qty, 'active', t.reason, t.score, t.score_breakdown, v_run, p_triggered_by
      from tgt t
      where not exists (select 1 from flow.allocations a where a.status = 'active' and not a.is_manual and a.order_line_id = t.order_line_id
          and a.stock_item_id = t.stock_item_id and a.source = t.source and coalesce(a.po_line_id, c_zero) = coalesce(t.po_line_id, c_zero) and a.qty = t.qty)
      returning id, stock_item_id, source, qty),
    led as (
      insert into flow.stock_movements (stock_item_id, movement_type, qty, ref_type, ref_id, run_id, note)
      select stock_item_id, 'allocated', qty, 'allocation', id::text, v_run, 'reserved by allocation engine' from ins where source = 'on_hand' returning 1)
    select count(*) into v_new from ins;

    -- 3. decisions: one audit row whenever an order's outcome changes (not on every run)
    with ins as (
      insert into flow.allocation_decisions (run_id, order_id, decision, reason, score, score_breakdown, qty_required, qty_allocated)
      select v_run, o.order_id, o.decision, o.reason, o.score, o.score_breakdown, o.qty_required, o.qty_allocated_on_hand
      from jsonb_to_recordset(coalesce(p_plan->'orders', '[]'::jsonb)) as o(order_id uuid, decision text, reason text, score numeric, score_breakdown jsonb, qty_required int, qty_allocated_on_hand int)
      where (select d.decision || '|' || coalesce(d.score_breakdown->>'sig', '') from flow.allocation_decisions d
             where d.order_id = o.order_id and d.order_line_id is null order by d.created_at desc limit 1)
            is distinct from (o.decision || '|' || coalesce(o.score_breakdown->>'sig', ''))
      returning 1)
    select count(*) into v_dec from ins;

    -- orders that left the awaiting-stock queue (DecoNetwork moved them on) lose their reservations; record why once
    with gone as (
      select distinct a.order_id from flow.allocations a
      where a.status = 'released' and a.reason like '%[superseded by run ' || v_run || ']'
        and not exists (select 1 from jsonb_to_recordset(coalesce(p_plan->'orders', '[]'::jsonb)) as o(order_id uuid) where o.order_id = a.order_id)
        and not exists (select 1 from flow.allocations b where b.order_id = a.order_id and b.status = 'active')),
    ins as (
      insert into flow.allocation_decisions (run_id, order_id, decision, reason, qty_required, qty_allocated)
      select v_run, g.order_id, 'release',
             'Reservations released: DecoNetwork no longer lists this order as awaiting stock (now: ' || coalesce(m.label, o.deco_status::text, 'unknown') || ').', 0, 0
      from gone g join flow.orders o on o.id = g.order_id left join flow.deco_status_map m on m.code = o.deco_status
      returning 1)
    select count(*) into v_released_orders from ins;

    -- 4. keep each order's allocation state and the 'Stock allocated' status in step with its reservations
    with need as (
      select l.order_id, sum(greatest(l.qty_required - l.qty_produced, 0)) as need from flow.order_lines l where l.is_active group by 1),
    got as (select order_id, sum(qty) filter (where source = 'on_hand') as oh from flow.allocations where status = 'active' group by 1),
    calc as (
      select o.id,
             (case when coalesce(g.oh, 0) = 0 then 'none' when g.oh >= n.need then 'full' else 'partial' end)::flow.alloc_state as new_state,
             o.order_status, o.alloc_state as old_state
      from flow.orders o join need n on n.order_id = o.id left join got g on g.order_id = o.id
      where o.is_active and not o.stock_secured),
    upd as (
      update flow.orders o set alloc_state = c.new_state,
        order_status = case when c.new_state = 'full' and o.order_status = 'awaiting_stock' then 'stock_allocated'::flow.order_status
                            when c.new_state <> 'full' and o.order_status = 'stock_allocated' then 'awaiting_stock'::flow.order_status
                            else o.order_status end,
        status_reason = case when c.new_state = 'full' and o.order_status = 'awaiting_stock' then 'stock fully allocated: release the order in DecoNetwork'
                             when c.new_state <> 'full' and o.order_status = 'stock_allocated' then 'allocation changed: stock no longer fully allocated'
                             else o.status_reason end
      from calc c where o.id = c.id
        and (c.new_state is distinct from c.old_state
             or (c.new_state = 'full' and o.order_status = 'awaiting_stock') or (c.new_state <> 'full' and o.order_status = 'stock_allocated'))
      returning 1)
    select count(*) into v_state from upd;

    update flow.flow_runs set status = 'success', finished_at = now(),
      summary = coalesce(p_plan->'summary', '{}'::jsonb) || jsonb_build_object('allocations_released', v_rel, 'allocations_created', v_new,
                'decisions_recorded', v_dec + v_released_orders, 'orders_state_changed', v_state)
    where id = v_run;
    return jsonb_build_object('ok', true, 'run_id', v_run, 'summary', p_plan->'summary', 'allocations_released', v_rel, 'allocations_created', v_new,
      'decisions_recorded', v_dec + v_released_orders, 'orders_state_changed', v_state);
  exception when others then
    update flow.flow_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'error', sqlerrm);
  end;
end $$;

-- Manual override: reserve units for a line by hand. The engine treats it as fixed and plans around it.
create or replace function flow.manual_allocate(p_order_line uuid, p_qty int, p_source text, p_po_line uuid, p_actor text, p_note text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare l flow.order_lines; v_stock uuid; v_id uuid; v_src flow.alloc_source := coalesce(nullif(p_source, ''), 'on_hand')::flow.alloc_source; v_have int;
begin
  begin
    if coalesce(p_note, '') = '' then raise exception 'a reason is required for a manual allocation'; end if;
    if p_qty is null or p_qty <= 0 then raise exception 'quantity must be positive'; end if;
    select * into l from flow.order_lines where id = p_order_line and is_active;
    if not found then raise exception 'order line not found'; end if;
    select id into v_stock from flow.stock_items where sku = l.sku;
    if v_stock is null then raise exception 'no stock record for SKU %', l.sku; end if;
    select coalesce(sum(a.qty), 0) into v_have from flow.allocations a where a.order_line_id = l.id and a.status = 'active' and a.is_manual;
    if v_have + p_qty > greatest(l.qty_required - l.qty_produced, 0) then
      raise exception 'line needs % unit(s) and % are already manually allocated', greatest(l.qty_required - l.qty_produced, 0), v_have;
    end if;
    insert into flow.allocations (order_id, order_line_id, stock_item_id, source, po_line_id, qty, status, is_manual, reason, created_by)
    values (l.order_id, l.id, v_stock, v_src, case when v_src = 'incoming_po' then p_po_line end, p_qty, 'active', true, 'Manual: ' || p_note, p_actor)
    returning id into v_id;
    if v_src = 'on_hand' then
      insert into flow.stock_movements (stock_item_id, movement_type, qty, ref_type, ref_id, note) values (v_stock, 'allocated', p_qty, 'allocation', v_id::text, 'manual: ' || p_note);
    end if;
    insert into flow.audit_log (actor, action, entity, entity_id, after, reason)
    values (p_actor, 'manual_allocate', 'allocation', v_id::text, jsonb_build_object('order_line', p_order_line, 'qty', p_qty, 'source', v_src), p_note);
    return jsonb_build_object('ok', true, 'allocation_id', v_id);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function flow.release_allocation(p_id uuid, p_actor text, p_reason text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare a flow.allocations;
begin
  begin
    if coalesce(p_reason, '') = '' then raise exception 'a reason is required'; end if;
    select * into a from flow.allocations where id = p_id;
    if not found then raise exception 'allocation not found'; end if;
    if a.status <> 'active' then raise exception 'allocation is already %', a.status; end if;
    update flow.allocations set status = 'released', released_at = now(), reason = coalesce(reason, '') || ' [released by ' || coalesce(p_actor, '?') || ': ' || p_reason || ']' where id = p_id;
    if a.source = 'on_hand' then
      insert into flow.stock_movements (stock_item_id, movement_type, qty, ref_type, ref_id, note) values (a.stock_item_id, 'released', -a.qty, 'allocation', p_id::text, p_reason);
    end if;
    insert into flow.audit_log (actor, action, entity, entity_id, before, reason)
    values (p_actor, 'release_allocation', 'allocation', p_id::text, jsonb_build_object('qty', a.qty, 'manual', a.is_manual), p_reason);
    return jsonb_build_object('ok', true);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- Read models ---------------------------------------------------------------------------------------------
create or replace view flow.v_allocation_board with (security_invoker = true) as
select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.priority, o.is_vip, o.deco_status, m.label as deco_status_label,
       o.alloc_state, o.order_status,
       t.units_needed, t.units_on_hand_reserved, t.units_incoming_reserved, greatest(t.units_needed - t.units_on_hand_reserved - t.units_incoming_reserved, 0) as units_short,
       d.decision, d.reason, d.score, (d.score_breakdown->>'projected_ready')::date as projected_ready_date,
       coalesce((d.score_breakdown->>'late_risk')::boolean, false) as late_risk, d.created_at as decided_at,
       (o.due_date < now() and o.is_active) as is_overdue
from flow.orders o
join flow.deco_status_map m on m.code = o.deco_status and m.maps_to = 'awaiting_stock'
left join lateral (select d1.* from flow.allocation_decisions d1 where d1.order_id = o.id and d1.order_line_id is null order by d1.created_at desc limit 1) d on true
left join lateral (
  select coalesce(sum(greatest(l.qty_required - l.qty_produced, 0)), 0)::int as units_needed,
         coalesce((select sum(a.qty) from flow.allocations a where a.order_id = o.id and a.status = 'active' and a.source = 'on_hand'), 0)::int as units_on_hand_reserved,
         coalesce((select sum(a.qty) from flow.allocations a where a.order_id = o.id and a.status = 'active' and a.source = 'incoming_po'), 0)::int as units_incoming_reserved
  from flow.order_lines l where l.order_id = o.id and l.is_active) t on true
where o.is_active and not o.stock_secured;

-- Live purchasing list: what is still uncovered after on-hand stock and incoming POs have been reserved
create or replace view flow.v_shortages with (security_invoker = true) as
select l.sku, max(l.product_name) as product_name, max(l.colour) as colour, max(l.size) as size,
       sum(greatest(l.qty_required - l.qty_produced, 0))::int as units_demanded,
       coalesce(sum(a.reserved), 0)::int as units_reserved,
       (sum(greatest(l.qty_required - l.qty_produced, 0)) - coalesce(sum(a.reserved), 0))::int as units_short,
       count(distinct o.id) as orders_affected, min(o.due_date)::date as earliest_due, array_agg(distinct o.order_ref order by o.order_ref) as order_refs,
       max(s.qty_on_hand) as on_hand, (select coalesce(sum(pl.qty_outstanding), 0) from flow.po_lines pl join flow.purchase_orders p on p.id = pl.po_id and p.is_active where pl.sku = l.sku)::int as on_order
from flow.order_lines l
join flow.orders o on o.id = l.order_id and o.is_active and not o.stock_secured
join flow.deco_status_map m on m.code = o.deco_status and m.maps_to = 'awaiting_stock'
left join flow.stock_items s on s.sku = l.sku
left join lateral (select sum(a1.qty) as reserved from flow.allocations a1 where a1.order_line_id = l.id and a1.status = 'active') a on true
where l.is_active and l.sku is not null and l.qty_required - l.qty_produced > 0
group by l.sku
having sum(greatest(l.qty_required - l.qty_produced, 0)) - coalesce(sum(a.reserved), 0) > 0;

-- n8n entry points + permissions ----------------------------------------------------------------------------
create or replace function public.flow_allocation_input() returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.allocation_input() $$;
create or replace function public.flow_apply_allocation(p_plan jsonb, p_triggered_by text default 'n8n') returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.apply_allocation(p_plan, p_triggered_by) $$;
create or replace function public.flow_manual_allocate(p_order_line uuid, p_qty int, p_source text, p_po_line uuid, p_actor text, p_note text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.manual_allocate(p_order_line, p_qty, p_source, p_po_line, p_actor, p_note) $$;
create or replace function public.flow_release_allocation(p_id uuid, p_actor text, p_reason text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.release_allocation(p_id, p_actor, p_reason) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'flow.allocation_input()', 'flow.apply_allocation(jsonb,text)', 'flow.manual_allocate(uuid,int,text,uuid,text,text)', 'flow.release_allocation(uuid,text,text)',
    'public.flow_allocation_input()', 'public.flow_apply_allocation(jsonb,text)', 'public.flow_manual_allocate(uuid,int,text,uuid,text,text)',
    'public.flow_release_allocation(uuid,text,text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on flow.v_allocation_board, flow.v_shortages to authenticated;
