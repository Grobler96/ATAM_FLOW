-- Third-party lifecycle: outbound, scans, receipt, returns, checks, direct dispatch, discrepancies, overdue alerts,
-- completion check, scorecards, label payloads, read views, n8n wrappers, RLS. All functions return {ok:true,...} or
-- {ok:false,error}; a failed call changes nothing (each runs in its own sub-transaction).

create or replace function flow.tp_log(p_mv uuid, p_event text, p_actor text, p_details jsonb default '{}'::jsonb, p_note text default null) returns void
language sql security definer set search_path = flow, public as $$
  insert into flow.tp_movement_events (movement_id, event, actor, details, note) values (p_mv, p_event, p_actor, coalesce(p_details, '{}'::jsonb), p_note)
$$;

create or replace function flow.tp_pick_list(p_mv uuid) returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'order_ref', o.order_ref, 'customer', o.customer_name, 'sku', i.sku,
           'product', l.product_name, 'colour', i.colour, 'size', i.size, 'qty', i.qty_sent, 'method', l.decoration_methods)
           order by i.sku, i.colour, i.size, o.order_ref), '[]'::jsonb)
  from flow.tp_movement_items i join flow.orders o on o.id = i.order_id join flow.order_lines l on l.id = i.order_line_id
  where i.movement_id = p_mv
$$;

-- How complete is an order's third-party work? Nothing may be marked complete while anything is unaccounted for.
create or replace function flow.order_completion_check(p_order uuid) returns jsonb language plpgsql stable security definer
set search_path = flow, public as $$
declare v_open int; v_routed int; v_at_prod int; v_unchecked int; v_ready int; v_done int; v_written_off int; v_blockers jsonb := '[]'::jsonb;
begin
  select count(*) into v_open from flow.tp_discrepancies where order_id = p_order and status in ('open','investigating') and blocks_completion;
  select coalesce(sum(rl.qty), 0) into v_routed from flow.route_lines rl join flow.production_routes r on r.id = rl.route_id
    where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed';
  select coalesce(sum(c.qty) filter (where c.location_state in ('picked_for_producer','in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back')), 0),
         coalesce(sum(c.qty) filter (where c.location_state = 'returned_to_warehouse'), 0),
         coalesce(sum(c.qty) filter (where c.location_state = 'ready_for_dispatch'), 0),
         coalesce(sum(c.qty) filter (where c.location_state = 'dispatched_to_customer'), 0)
    into v_at_prod, v_unchecked, v_ready, v_done
    from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id where l.order_id = p_order;
  select coalesce(sum(qty), 0) into v_written_off from flow.tp_discrepancies where order_id = p_order and status = 'written_off';
  if v_open > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s open discrepancy record(s)', v_open)); end if;
  if v_at_prod > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s unit(s) still with or travelling to/from a producer', v_at_prod)); end if;
  if v_unchecked > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s returned unit(s) not yet checked', v_unchecked)); end if;
  if v_ready > 0 then v_blockers := v_blockers || jsonb_build_array(format('%s checked unit(s) waiting to be dispatched', v_ready)); end if;
  if v_routed > 0 and v_done + v_written_off < v_routed then
    v_blockers := v_blockers || jsonb_build_array(format('%s of %s routed unit(s) accounted for (dispatched or written off)', v_done + v_written_off, v_routed));
  end if;
  return jsonb_build_object('order_id', p_order, 'routed_units', v_routed, 'with_producer_units', v_at_prod, 'unchecked_units', v_unchecked,
    'ready_units', v_ready, 'dispatched_units', v_done, 'written_off_units', v_written_off, 'open_discrepancies', v_open,
    'can_dispatch_partial', v_ready > 0 and v_open = 0,
    'can_dispatch_all', v_open = 0 and v_at_prod = 0 and v_unchecked = 0 and v_ready > 0 and v_done + v_ready + v_written_off >= v_routed,
    'can_complete', jsonb_array_length(v_blockers) = 0, 'blockers', v_blockers);
end $$;

-- Recompute an order's overall status from its third-party routes (replaces the earlier version)
create or replace function flow.tp_sync_order_status(p_order uuid) returns void
language plpgsql security definer set search_path = flow, public as $$
declare v_o flow.orders; v_new flow.order_status; v_reason text; v_chk jsonb;
begin
  select * into v_o from flow.orders where id = p_order;
  if not found or not v_o.is_active or v_o.order_status = 'dispatched' then return; end if;
  v_chk := flow.order_completion_check(p_order);
  if exists (select 1 from flow.tp_discrepancies d where d.order_id = p_order and d.status in ('open','investigating') and d.blocks_completion and d.disc_type <> 'shortage') then
    v_new := 'blocked'; v_reason := 'third-party exception: open discrepancy';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed')
        and (v_chk->>'can_complete')::boolean
        and not exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed'
                        and r.tp_status not in ('dispatched_to_customer','completed')) then
    v_new := 'dispatched'; v_reason := 'all third-party units dispatched to the customer';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed'
                and r.tp_status in ('dispatched_to_producer','received_by_producer','in_production_at_producer','production_complete_at_producer','awaiting_return','in_transit_back')) then
    v_new := 'in_production'; v_reason := 'with third-party producer';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed' and r.tp_status = 'returned_to_warehouse') then
    v_new := 'quality_check'; v_reason := 'returned from producer, awaiting check';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed' and r.tp_status in ('ready_for_dispatch','return_checked'))
        and not exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed'
                        and r.tp_status not in ('ready_for_dispatch','return_checked','dispatched_to_customer','completed')) then
    v_new := 'ready_for_dispatch'; v_reason := 'returned and checked';
  else
    return;
  end if;
  if v_o.order_status is distinct from v_new then
    update flow.orders set order_status = v_new, status_reason = v_reason where id = p_order;
    insert into flow.audit_log (actor, action, entity, entity_id, before, after, reason)
    values ('system', 'status_change', 'order', p_order::text, jsonb_build_object('status', v_o.order_status), jsonb_build_object('status', v_new), v_reason);
  end if;
end $$;

create or replace function flow.tp_sync_movement_orders(p_mv uuid) returns void language plpgsql security definer
set search_path = flow, public as $$
declare r record;
begin
  for r in select distinct order_id from flow.tp_movement_items where movement_id = p_mv loop
    perform flow.tp_sync_order_status(r.order_id);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Outbound movement (also used for direct-dispatch consignments)
-- ---------------------------------------------------------------------------
create or replace function flow.create_outbound_movement(p_producer uuid, p_items jsonb, p_actor text,
  p_type text default 'outbound_to_producer', p_carrier text default null, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  v_prod flow.producers; v_mv uuid; v_code text; v_it jsonb; v_line flow.order_lines; v_ord flow.orders; v_qty int; v_need int;
  v_out int; v_cover int; v_have int; v_route uuid; v_route_out int; v_direct boolean; v_bin uuid; v_bin_code text;
  v_type text := coalesce(nullif(p_type, ''), 'outbound_to_producer');           -- n8n may pass null for optional arguments
begin
  begin
    select * into v_prod from flow.producers where id = p_producer and is_active;
    if not found then raise exception 'producer not found or inactive'; end if;
    if v_type not in ('outbound_to_producer','direct_dispatch_to_customer') then raise exception 'unsupported movement type %', v_type; end if;
    v_direct := v_type = 'direct_dispatch_to_customer';
    if v_direct and not v_prod.can_direct_dispatch then raise exception 'producer % is not set up for direct dispatch', v_prod.name; end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'no items supplied'; end if;

    v_code := 'TP-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.tp_movement_seq')::text, 5, '0');
    insert into flow.tp_movements (movement_code, movement_type, producer_id, carrier, notes, created_by, updated_by)
    values (v_code, v_type::flow.tp_movement_type, p_producer, coalesce(nullif(p_carrier, ''), v_prod.default_method), p_notes, p_actor, p_actor)
    returning id into v_mv;

    for v_it in select * from jsonb_array_elements(p_items) loop
      v_qty := (v_it->>'qty')::int;
      if v_qty is null or v_qty <= 0 then raise exception 'each item needs a positive qty'; end if;
      select * into v_line from flow.order_lines where id = (v_it->>'order_line_id')::uuid and is_active;
      if not found then raise exception 'order line % not found or inactive', v_it->>'order_line_id'; end if;
      select * into v_ord from flow.orders where id = v_line.order_id;
      if not v_ord.is_active then raise exception 'order % is not active', v_ord.order_ref; end if;
      v_need := greatest(v_line.qty_required - v_line.qty_produced, 0);
      v_cover := case when v_ord.stock_secured then v_need
                      else coalesce((select sum(a.qty) from flow.allocations a where a.order_line_id = v_line.id and a.status = 'active' and a.source = 'on_hand'), 0)::int end;
      -- units already committed to producers on this line (damaged / rejected units free up for replacement)
      select coalesce(sum(i.qty_sent - i.qty_damaged - i.qty_rejected), 0)::int into v_out
        from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id
        where i.order_line_id = v_line.id and m.status <> 'cancelled' and i.movement_id <> v_mv;
      if v_cover <= 0 then
        raise exception 'order % has no secured stock yet (status: %)', v_ord.order_ref, v_ord.order_status;
      end if;
      if v_out + v_qty > least(v_need, v_cover) then
        raise exception 'order % %: % unit(s) requested but only % can still be sent (needed %, secured %, already with producers %)',
          v_ord.order_ref, coalesce(v_line.product_name, v_line.sku), v_qty, greatest(least(v_need, v_cover) - v_out, 0), v_need, v_cover, v_out;
      end if;

      select id into v_route from flow.production_routes
        where order_id = v_ord.id and kind = 'third_party' and producer_id = p_producer and direct_dispatch = v_direct
          and route_status in ('recommended','confirmed') limit 1;
      if v_route is null then
        insert into flow.production_routes (order_id, kind, producer_id, direct_dispatch, route_status, tp_status, reason, confirmed_by, confirmed_at)
        values (v_ord.id, 'third_party', p_producer, v_direct, 'confirmed', 'ready_to_send', 'created with consignment ' || v_code, p_actor, now())
        returning id into v_route;
      else
        update flow.production_routes set route_status = 'confirmed', confirmed_by = coalesce(confirmed_by, p_actor), confirmed_at = coalesce(confirmed_at, now()),
          tp_status = case when tp_status is null or tp_status in ('awaiting_stock','stock_allocated') then 'ready_to_send'::flow.tp_status else tp_status end
        where id = v_route;
      end if;
      select coalesce(sum(i.qty_sent - i.qty_damaged - i.qty_rejected), 0)::int into v_route_out from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id
        where i.route_id = v_route and i.order_line_id = v_line.id and m.status <> 'cancelled' and i.movement_id <> v_mv;
      update flow.route_lines set qty = greatest(qty, v_route_out + v_qty) where route_id = v_route and order_line_id = v_line.id;
      if not found then
        insert into flow.route_lines (route_id, order_line_id, qty) values (v_route, v_line.id, v_route_out + v_qty);
      end if;

      -- custody: reserve the units for this consignment (seed garments DecoNetwork has already secured on first use)
      v_have := coalesce((select qty from flow.stock_custody where order_line_id = v_line.id and location_state = 'allocated_to_order' and movement_id is null), 0);
      if v_have < v_qty then
        perform flow.custody_seed(v_line.id, v_qty - v_have, p_actor, 'garments secured for the order (seeded when consignment ' || v_code || ' was created)');
      end if;
      perform flow.custody_move(v_line.id, 'allocated_to_order', null, 'allocated_to_order', v_mv, v_qty, p_producer, p_actor, 'reserved for consignment ' || v_code);

      insert into flow.tp_movement_items (movement_id, route_id, order_id, order_line_id, sku, colour, size, qty_sent, qty_expected_back)
      values (v_mv, v_route, v_ord.id, v_line.id, v_line.sku, v_line.colour, v_line.size, v_qty, case when v_direct then 0 else v_qty end);
    end loop;

    select b.id, b.bin_code into v_bin, v_bin_code from flow.bins b join flow.bin_zones z on z.id = b.zone_id
      where z.code = 'OUT' and b.is_active and b.status = 'available' order by b.bin_code limit 1 for update of b skip locked;
    if v_bin is not null then
      update flow.bins set status = 'allocated' where id = v_bin;
      update flow.tp_movements set staging_bin_id = v_bin where id = v_mv;
    end if;
    perform flow.tp_log(v_mv, 'created', p_actor, jsonb_build_object('type', v_type, 'items', jsonb_array_length(p_items), 'staging_bin', v_bin_code));
    return jsonb_build_object('ok', true, 'movement_id', v_mv, 'movement_code', v_code, 'staging_bin', v_bin_code,
      'pick_list', flow.tp_pick_list(v_mv),
      'warnings', case when v_bin is null then jsonb_build_array('no free staging bin in zone OUT - create some with flow.generate_bins(''OUT'', ''OUT'', 6)') else '[]'::jsonb end);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Scan events: picked, packed, dispatched, received_by_producer, production_started, production_complete,
--    awaiting_return, return_dispatched
-- ---------------------------------------------------------------------------
create or replace function flow.tp_scan(p_movement text, p_event text, p_actor text, p_payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  m flow.tp_movements; v_prod flow.producers; it record; v_status flow.tp_movement_status; v_tp flow.tp_status;
  v_disp date; v_recv timestamptz; v_exp date; v_have int; v_state flow.custody_state;
begin
  begin
    m := flow.tp_find(p_movement);
    if m.id is null then raise exception 'movement % not found', p_movement; end if;
    select * into v_prod from flow.producers where id = m.producer_id;
    v_disp := m.dispatch_date; v_exp := m.expected_return_date; v_recv := m.received_by_producer_at;

    case p_event
    when 'picked' then
      if m.status <> 'draft' then raise exception 'cannot pick a movement that is %', m.status; end if;
      for it in select * from flow.tp_movement_items where movement_id = m.id loop
        perform flow.custody_move(it.order_line_id, 'allocated_to_order', m.id, 'picked_for_producer', m.id, it.qty_sent, m.producer_id, p_actor, 'picked for ' || m.movement_code);
      end loop;
      v_status := 'picked'; v_tp := 'picked_for_producer';
    when 'packed' then
      if m.status <> 'picked' then raise exception 'cannot pack a movement that is %', m.status; end if;
      v_status := 'packed'; v_tp := 'packed_for_producer';
    when 'dispatched' then
      if m.status <> 'packed' then raise exception 'cannot dispatch a movement that is %', m.status; end if;
      for it in select * from flow.tp_movement_items where movement_id = m.id loop
        perform flow.custody_move(it.order_line_id, 'picked_for_producer', m.id, 'in_transit_to_producer', m.id, it.qty_sent, m.producer_id, p_actor, 'dispatched on ' || m.movement_code);
      end loop;
      v_disp := coalesce((p_payload->>'date')::date, current_date);
      v_exp := v_disp + (ceil(v_prod.turnaround_days)::int + 1);          -- tentative: 1 day transit + turnaround
      v_status := 'dispatched'; v_tp := 'dispatched_to_producer';
      if m.staging_bin_id is not null then update flow.bins set status = 'available' where id = m.staging_bin_id; end if;
    when 'received_by_producer' then
      if m.status <> 'dispatched' then raise exception 'producer cannot receive a movement that is %', m.status; end if;
      for it in select * from flow.tp_movement_items where movement_id = m.id loop
        perform flow.custody_move(it.order_line_id, 'in_transit_to_producer', m.id, 'at_producer', m.id, it.qty_sent, m.producer_id, p_actor, 'receipt confirmed by producer');
      end loop;
      v_recv := coalesce((p_payload->>'at')::timestamptz, now());
      v_exp := v_recv::date + ceil(v_prod.turnaround_days)::int;           -- the turnaround clock starts at receipt
      v_status := 'received_by_producer'; v_tp := 'received_by_producer';
    when 'production_started' then
      if m.status <> 'received_by_producer' then raise exception 'production cannot start on a movement that is %', m.status; end if;
      for it in select * from flow.tp_movement_items where movement_id = m.id loop
        perform flow.custody_move(it.order_line_id, 'at_producer', m.id, 'in_production_at_producer', m.id, it.qty_sent, m.producer_id, p_actor, 'production started at producer');
      end loop;
      v_status := 'in_production'; v_tp := 'in_production_at_producer';
    when 'production_complete' then
      if m.status not in ('received_by_producer','in_production') then raise exception 'production cannot complete on a movement that is %', m.status; end if;
      for it in select * from flow.tp_movement_items where movement_id = m.id loop
        select qty into v_have from flow.stock_custody where order_line_id = it.order_line_id and location_state = 'in_production_at_producer' and movement_id = m.id;
        if coalesce(v_have, 0) > 0 then
          perform flow.custody_move(it.order_line_id, 'in_production_at_producer', m.id, 'at_producer', m.id, v_have, m.producer_id, p_actor, 'production complete at producer');
        end if;
      end loop;
      v_status := 'production_complete'; v_tp := 'production_complete_at_producer';
    when 'awaiting_return' then
      if m.status <> 'production_complete' then raise exception 'cannot await return on a movement that is %', m.status; end if;
      v_status := m.status; v_tp := 'awaiting_return';
    when 'return_dispatched' then
      if m.movement_type <> 'outbound_to_producer' then raise exception 'only outbound-to-producer movements come back'; end if;
      if m.status not in ('received_by_producer','in_production','production_complete') then raise exception 'cannot return a movement that is %', m.status; end if;
      for it in select * from flow.tp_movement_items where movement_id = m.id and qty_outstanding > 0 loop
        v_have := it.qty_outstanding;
        foreach v_state in array array['at_producer','in_production_at_producer']::flow.custody_state[] loop
          exit when v_have <= 0;
          declare v_in int; v_mvq int;
          begin
            select qty into v_in from flow.stock_custody where order_line_id = it.order_line_id and location_state = v_state and movement_id = m.id;
            v_mvq := least(coalesce(v_in, 0), v_have);
            if v_mvq > 0 then
              perform flow.custody_move(it.order_line_id, v_state, m.id, 'in_transit_back', m.id, v_mvq, m.producer_id, p_actor, 'producer shipped the goods back');
              v_have := v_have - v_mvq;
            end if;
          end;
        end loop;
      end loop;
      update flow.tp_movements set return_tracking_ref = coalesce(p_payload->>'tracking_ref', return_tracking_ref) where id = m.id;
      v_status := 'in_transit_back'; v_tp := 'in_transit_back';
    else
      raise exception 'unknown event % (use picked, packed, dispatched, received_by_producer, production_started, production_complete, awaiting_return, return_dispatched)', p_event;
    end case;

    update flow.tp_movements set status = v_status, dispatch_date = v_disp, expected_return_date = v_exp, received_by_producer_at = v_recv,
      carrier = coalesce(p_payload->>'carrier', carrier), tracking_ref = coalesce(p_payload->>'tracking_ref', tracking_ref),
      consignment_ref = coalesce(p_payload->>'consignment_ref', consignment_ref),
      package_info = case when p_event = 'packed' then coalesce(p_payload - 'scan', '{}'::jsonb) else package_info end,
      evidence = case when p_payload ? 'evidence' then evidence || (p_payload->'evidence') else evidence end,
      updated_by = p_actor
    where id = m.id;
    perform flow.tp_set_route_status(m.id, v_tp);
    perform flow.tp_log(m.id, p_event, p_actor, p_payload, p_payload->>'note');
    perform flow.tp_sync_movement_orders(m.id);
    return jsonb_build_object('ok', true, 'movement_code', m.movement_code, 'status', v_status, 'order_stage', v_tp,
      'dispatch_date', v_disp, 'expected_return_date', v_exp);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Return from producer (supports several partial deliveries)
--    p_items: [{item_id, qty_received, qty_damaged, qty_rejected, note}]
-- ---------------------------------------------------------------------------
create or replace function flow.tp_record_return(p_movement text, p_items jsonb, p_actor text, p_payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  m flow.tp_movements; e jsonb; it flow.tp_movement_items; v_good int; v_dam int; v_rej int; v_in int; v_before int; v_over int;
  v_good_c int; v_dam_c int; v_rej_c int; v_ord flow.orders; v_all_back boolean; v_summary jsonb := '[]'::jsonb; v_reco jsonb := '[]'::jsonb;
  v_action text; v_new flow.tp_movement_status; v_after flow.tp_movement_items; v_overdue boolean; v_orders uuid[] := '{}';
begin
  begin
    m := flow.tp_find(p_movement);
    if m.id is null then raise exception 'movement % not found', p_movement; end if;
    if m.movement_type <> 'outbound_to_producer' or m.status not in ('dispatched','received_by_producer','in_production','production_complete','in_transit_back','partially_returned') then
      raise exception 'movement % (%) is not awaiting a return', m.movement_code, m.status;
    end if;
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'no returned items supplied'; end if;
    v_overdue := m.expected_return_date is not null and m.expected_return_date < current_date;

    for e in select * from jsonb_array_elements(p_items) loop
      select * into it from flow.tp_movement_items where id = (e->>'item_id')::uuid and movement_id = m.id;
      if not found then raise exception 'item % is not part of %', e->>'item_id', m.movement_code; end if;
      v_good := coalesce((e->>'qty_received')::int, 0); v_dam := coalesce((e->>'qty_damaged')::int, 0); v_rej := coalesce((e->>'qty_rejected')::int, 0);
      if v_good < 0 or v_dam < 0 or v_rej < 0 then raise exception 'quantities cannot be negative'; end if;
      v_in := v_good + v_dam + v_rej;
      v_before := it.qty_received_back + it.qty_damaged + it.qty_rejected;
      v_over := greatest(v_before + v_in - it.qty_expected_back, 0);                -- more units than were sent
      -- only units that were actually sent can leave producer custody; extra units are an overage, recorded but not tracked as stock
      v_good_c := greatest(v_good - v_over, 0);
      v_dam_c := least(v_dam, greatest(v_dam - greatest(v_over - v_good, 0), 0));
      v_rej_c := least(v_rej, greatest(v_rej - greatest(v_over - v_good - v_dam, 0), 0));
      perform flow.custody_take_from_producer(it.order_line_id, m.id, 'returned_to_warehouse', v_good_c, m.producer_id, p_actor, 'returned by producer, awaiting check');
      perform flow.custody_take_from_producer(it.order_line_id, m.id, 'lost_damaged_discrepancy', v_dam_c + v_rej_c, m.producer_id, p_actor, 'returned damaged or rejected');
      update flow.tp_movement_items set qty_received_back = qty_received_back + v_good, qty_damaged = qty_damaged + v_dam, qty_rejected = qty_rejected + v_rej
        where id = it.id returning * into v_after;
      select * into v_ord from flow.orders where id = it.order_id;
      v_orders := array_append(v_orders, it.order_id);

      if v_dam > 0 then
        insert into flow.tp_discrepancies (movement_id, item_id, order_id, order_line_id, producer_id, disc_type, qty, opened_by, resolution_note)
        values (m.id, it.id, it.order_id, it.order_line_id, m.producer_id, 'damaged', v_dam, p_actor, e->>'note');
      end if;
      if v_rej > 0 then
        insert into flow.tp_discrepancies (movement_id, item_id, order_id, order_line_id, producer_id, disc_type, qty, opened_by, resolution_note)
        values (m.id, it.id, it.order_id, it.order_line_id, m.producer_id, 'rejected', v_rej, p_actor, e->>'note');
      end if;
      if v_over > 0 then
        insert into flow.tp_discrepancies (movement_id, item_id, order_id, order_line_id, producer_id, disc_type, qty, opened_by)
        values (m.id, it.id, it.order_id, it.order_line_id, m.producer_id, 'overage', v_over, p_actor)
        on conflict (item_id, disc_type) where status in ('open','investigating') and disc_type in ('shortage','overage')
        do update set qty = flow.tp_discrepancies.qty + excluded.qty;
      end if;
      if v_after.qty_outstanding > 0 then
        insert into flow.tp_discrepancies (movement_id, item_id, order_id, order_line_id, producer_id, disc_type, qty, opened_by)
        values (m.id, it.id, it.order_id, it.order_line_id, m.producer_id, 'shortage', v_after.qty_outstanding, p_actor)
        on conflict (item_id, disc_type) where status in ('open','investigating') and disc_type in ('shortage','overage')
        do update set qty = excluded.qty;
      else
        update flow.tp_discrepancies set status = 'resolved', resolution = 'received_later', resolved_at = now(), resolved_by = p_actor
          where item_id = it.id and disc_type = 'shortage' and status in ('open','investigating');
      end if;

      v_action := case
        when v_dam + v_rej > 0 then 'Reorder or replace the damaged/rejected units, or ask the producer to redo them; hold the order until resolved.'
        when v_after.qty_outstanding > 0 and v_overdue then format('Chase the producer for the %s outstanding unit(s), already past the return date.', v_after.qty_outstanding)
        when v_after.qty_outstanding > 0 and v_after.qty_received_back > 0 then format('Wait for the remaining %s unit(s) due back %s, or split the dispatch if the customer agrees.', v_after.qty_outstanding, m.expected_return_date)
        when v_after.qty_outstanding > 0 then format('Wait for the %s unit(s) due back %s.', v_after.qty_outstanding, m.expected_return_date)
        when v_over > 0 then 'More units came back than were sent: check the producer paperwork before accepting.'
        else 'Complete: check the goods and release for dispatch.' end;
      v_summary := v_summary || jsonb_build_array(jsonb_build_object('item_id', it.id, 'order_ref', v_ord.order_ref, 'sku', it.sku, 'colour', it.colour, 'size', it.size,
        'expected', it.qty_expected_back, 'received_good', v_after.qty_received_back, 'damaged', v_after.qty_damaged, 'rejected', v_after.qty_rejected,
        'outstanding', v_after.qty_outstanding, 'overage', v_over, 'blocks_dispatch', v_after.qty_outstanding > 0 or v_after.qty_damaged + v_after.qty_rejected > 0));
      v_reco := v_reco || jsonb_build_array(jsonb_build_object('order_ref', v_ord.order_ref, 'sku', it.sku, 'action', v_action));
    end loop;

    select bool_and(qty_outstanding = 0) into v_all_back from flow.tp_movement_items where movement_id = m.id;
    v_new := case when v_all_back then 'returned' else 'partially_returned' end;
    if exists (select 1 from flow.tp_discrepancies where movement_id = m.id and status in ('open','investigating') and disc_type in ('damaged','rejected','overage','lost')) then
      v_new := case when v_all_back then 'exception' else 'partially_returned' end;
    end if;
    update flow.tp_movements set status = v_new, actual_return_date = case when v_all_back then coalesce(actual_return_date, current_date) else actual_return_date end,
      evidence = case when p_payload ? 'evidence' then evidence || (p_payload->'evidence') else evidence end, updated_by = p_actor where id = m.id;
    perform flow.tp_set_route_status(m.id, case
      when exists (select 1 from flow.tp_discrepancies where movement_id = m.id and status in ('open','investigating') and disc_type in ('damaged','rejected','overage','lost')) then 'exception'::flow.tp_status
      when v_all_back then 'returned_to_warehouse'::flow.tp_status else 'awaiting_return'::flow.tp_status end);
    perform flow.tp_log(m.id, 'return_recorded', p_actor, jsonb_build_object('items', v_summary), p_payload->>'note');
    perform flow.tp_sync_movement_orders(m.id);
    return jsonb_build_object('ok', true, 'movement_code', m.movement_code, 'status', v_new, 'complete_return', v_all_back, 'items', v_summary,
      'recommendations', v_reco, 'notify', exists (select 1 from jsonb_array_elements(v_summary) s where (s->>'blocks_dispatch')::boolean or (s->>'overage')::int > 0));
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Goods-in check after a return: p_items [{item_id, qty_ok, qty_rejected}]
-- ---------------------------------------------------------------------------
create or replace function flow.tp_check_return(p_movement text, p_items jsonb, p_actor text, p_payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; e jsonb; it flow.tp_movement_items; v_ok int; v_rej int; v_have int; v_unchecked int; v_blocked boolean;
begin
  begin
    m := flow.tp_find(p_movement);
    if m.id is null then raise exception 'movement % not found', p_movement; end if;
    if m.status not in ('returned','partially_returned','exception') then raise exception 'nothing to check on a movement that is %', m.status; end if;
    for e in select * from jsonb_array_elements(p_items) loop
      select * into it from flow.tp_movement_items where id = (e->>'item_id')::uuid and movement_id = m.id;
      if not found then raise exception 'item % is not part of %', e->>'item_id', m.movement_code; end if;
      v_ok := coalesce((e->>'qty_ok')::int, 0); v_rej := coalesce((e->>'qty_rejected')::int, 0);
      select qty into v_have from flow.stock_custody where order_line_id = it.order_line_id and location_state = 'returned_to_warehouse' and movement_id = m.id;
      if v_ok < 0 or v_rej < 0 or v_ok + v_rej > coalesce(v_have, 0) then
        raise exception 'item %: % unit(s) awaiting check but % submitted', it.sku, coalesce(v_have, 0), v_ok + v_rej;
      end if;
      perform flow.custody_move(it.order_line_id, 'returned_to_warehouse', m.id, 'ready_for_dispatch', m.id, v_ok, m.producer_id, p_actor, 'checked OK');
      perform flow.custody_move(it.order_line_id, 'returned_to_warehouse', m.id, 'lost_damaged_discrepancy', m.id, v_rej, m.producer_id, p_actor, 'failed goods-in check');
      update flow.tp_movement_items set qty_checked_ok = qty_checked_ok + v_ok, qty_rejected = qty_rejected + v_rej, qty_received_back = qty_received_back - v_rej where id = it.id;
      if v_rej > 0 then
        insert into flow.tp_discrepancies (movement_id, item_id, order_id, order_line_id, producer_id, disc_type, qty, opened_by, resolution_note)
        values (m.id, it.id, it.order_id, it.order_line_id, m.producer_id, 'rejected', v_rej, p_actor, e->>'note');
      end if;
    end loop;
    select coalesce(sum(c.qty), 0) into v_unchecked from flow.stock_custody c where c.movement_id = m.id and c.location_state = 'returned_to_warehouse';
    v_blocked := exists (select 1 from flow.tp_discrepancies where movement_id = m.id and status in ('open','investigating') and blocks_completion);
    update flow.tp_movements set status = case when v_blocked then 'exception'::flow.tp_movement_status
        when v_unchecked = 0 and not exists (select 1 from flow.tp_movement_items where movement_id = m.id and qty_outstanding > 0) then 'checked'::flow.tp_movement_status
        else status end, updated_by = p_actor where id = m.id;
    perform flow.tp_set_route_status(m.id, case when v_blocked then 'exception'::flow.tp_status
        when v_unchecked = 0 and not exists (select 1 from flow.tp_movement_items where movement_id = m.id and qty_outstanding > 0) then 'ready_for_dispatch'::flow.tp_status
        else 'returned_to_warehouse'::flow.tp_status end);
    perform flow.tp_log(m.id, 'return_checked', p_actor, p_items, p_payload->>'note');
    perform flow.tp_sync_movement_orders(m.id);
    return jsonb_build_object('ok', true, 'movement_code', m.movement_code, 'unchecked_units', v_unchecked, 'blocked_by_discrepancy', v_blocked,
      'status', (select status from flow.tp_movements where id = m.id));
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Direct dispatch: the producer ships to the customer; stock never comes back
-- ---------------------------------------------------------------------------
create or replace function flow.tp_direct_dispatch(p_movement text, p_tracking text, p_carrier text, p_pod jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; it record; v_moved int;
begin
  begin
    m := flow.tp_find(p_movement);
    if m.id is null then raise exception 'movement % not found', p_movement; end if;
    if m.movement_type <> 'direct_dispatch_to_customer' then raise exception '% is not a direct-dispatch movement', m.movement_code; end if;
    if m.status not in ('received_by_producer','in_production','production_complete') then raise exception 'cannot dispatch to the customer from status %', m.status; end if;
    if coalesce(p_tracking, '') = '' then raise exception 'a tracking reference is required'; end if;
    for it in select * from flow.tp_movement_items where movement_id = m.id loop
      v_moved := flow.custody_take_from_producer(it.order_line_id, m.id, 'dispatched_to_customer', it.qty_sent, m.producer_id, p_actor, 'producer dispatched directly to the customer');
      if v_moved < it.qty_sent then raise exception 'only % of % unit(s) were held by the producer for %', v_moved, it.qty_sent, it.sku; end if;
    end loop;
    update flow.tp_movements set status = 'closed', actual_return_date = current_date, customer_tracking_ref = p_tracking,
      carrier = coalesce(p_carrier, carrier), proof_of_delivery = p_pod, updated_by = p_actor where id = m.id;
    perform flow.tp_set_route_status(m.id, case when p_pod is not null then 'completed'::flow.tp_status else 'dispatched_to_customer'::flow.tp_status end);
    perform flow.tp_log(m.id, 'direct_dispatched', p_actor, jsonb_build_object('tracking', p_tracking, 'carrier', p_carrier, 'pod', p_pod));
    perform flow.tp_sync_movement_orders(m.id);
    return jsonb_build_object('ok', true, 'movement_code', m.movement_code, 'status', 'closed', 'tracking', p_tracking,
      'note', 'stock never returns to the warehouse; counts are unaffected');
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- Goods we dispatch to the customer ourselves (DecoNetwork shows shipped): move checked units out of custody.
create or replace function flow.tp_reconcile_shipped(p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r record; v_n int := 0;
begin
  for r in select c.id, c.order_line_id, c.movement_id, c.qty, l.order_id from flow.stock_custody c
           join flow.order_lines l on l.id = c.order_line_id join flow.orders o on o.id = l.order_id
           where c.location_state = 'ready_for_dispatch' and c.qty > 0 and o.shipped_at is not null loop
    perform flow.custody_move(r.order_line_id, 'ready_for_dispatch', r.movement_id, 'dispatched_to_customer', r.movement_id, r.qty, null, p_actor, 'order shipped in DecoNetwork');
    perform flow.tp_set_route_status(r.movement_id, 'dispatched_to_customer');
    update flow.tp_movements set status = 'closed' where id = r.movement_id and status = 'checked';
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'custody_rows_moved', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Discrepancies
-- ---------------------------------------------------------------------------
create or replace function flow.tp_resolve_discrepancy(p_id uuid, p_resolution text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare d flow.tp_discrepancies;
begin
  begin
    select * into d from flow.tp_discrepancies where id = p_id;
    if not found then raise exception 'discrepancy not found'; end if;
    if d.status in ('resolved','written_off') then raise exception 'discrepancy is already %', d.status; end if;
    if p_resolution not in ('received_later','replaced','credited','accepted','written_off') then raise exception 'unknown resolution %', p_resolution; end if;
    if coalesce(p_note, '') = '' then raise exception 'a resolution note is required'; end if;
    update flow.tp_discrepancies set status = case when p_resolution = 'written_off' then 'written_off' else 'resolved' end,
      resolution = p_resolution, resolution_note = p_note, resolved_at = now(), resolved_by = p_actor where id = p_id;
    perform flow.tp_log(d.movement_id, 'discrepancy_resolved', p_actor, jsonb_build_object('discrepancy', p_id, 'resolution', p_resolution), p_note);
    update flow.tp_movements set status = 'closed', updated_by = p_actor where id = d.movement_id and status in ('checked','exception','returned')
      and not exists (select 1 from flow.tp_discrepancies x where x.movement_id = d.movement_id and x.status in ('open','investigating'))
      and not exists (select 1 from flow.stock_custody c where c.movement_id = d.movement_id and c.qty > 0 and c.location_state in ('returned_to_warehouse','picked_for_producer','in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back'))
      and not exists (select 1 from flow.tp_movement_items i where i.movement_id = d.movement_id and i.qty_outstanding > 0);
    perform flow.tp_sync_movement_orders(d.movement_id);
    if d.order_id is not null then perform flow.tp_sync_order_status(d.order_id); end if;
    return jsonb_build_object('ok', true, 'completion', case when d.order_id is not null then flow.order_completion_check(d.order_id) end);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- Raise one 'late' discrepancy per overdue movement and return them for notification. Safe to run as often as you like.
create or replace function flow.tp_overdue_check() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r record; v_list jsonb := '[]'::jsonb; v_new int := 0;
begin
  for r in select m.id, m.movement_code, m.expected_return_date, m.producer_id, p.name as producer, m.status,
                  (current_date - m.expected_return_date) as days_late,
                  (select coalesce(sum(qty_outstanding), 0) from flow.tp_movement_items where movement_id = m.id) as units_out,
                  (select array_agg(distinct o.order_ref) from flow.tp_movement_items i join flow.orders o on o.id = i.order_id where i.movement_id = m.id) as orders
           from flow.tp_movements m join flow.producers p on p.id = m.producer_id
           where m.expected_return_date < current_date and m.status in ('dispatched','received_by_producer','in_production','production_complete','in_transit_back','partially_returned')
             and m.movement_type in ('outbound_to_producer','direct_dispatch_to_customer') loop
    insert into flow.tp_discrepancies (movement_id, order_id, producer_id, disc_type, qty, opened_by, blocks_completion, resolution_note)
    select r.id, null, r.producer_id, 'late', r.units_out, 'system', false, format('overdue by %s day(s)', r.days_late)
    where not exists (select 1 from flow.tp_discrepancies d where d.movement_id = r.id and d.disc_type = 'late' and d.status in ('open','investigating'));
    if found then
      v_new := v_new + 1;
      perform flow.tp_log(r.id, 'overdue_flagged', 'system', jsonb_build_object('days_late', r.days_late));
    end if;
    v_list := v_list || jsonb_build_array(jsonb_build_object('movement_code', r.movement_code, 'producer', r.producer, 'days_late', r.days_late,
      'units_outstanding', r.units_out, 'orders', to_jsonb(r.orders), 'expected_return_date', r.expected_return_date));
  end loop;
  return jsonb_build_object('ok', true, 'overdue', v_list, 'newly_flagged', v_new);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Producer scorecards
-- ---------------------------------------------------------------------------
create or replace function flow.refresh_producer_stats() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p record; v_val numeric; v_n int := 0;
begin
  for p in select id from flow.producers loop
    v_val := 0;
    if to_regclass('public.sku_costs') is not null then
      execute $q$select coalesce(sum(c.qty * coalesce(sc.unit_cost, 0)), 0) from flow.stock_custody c
                 join flow.order_lines l on l.id = c.order_line_id left join public.sku_costs sc on sc.sku = l.sku
                 where c.producer_id = $1 and c.location_state in ('in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back')$q$
        using p.id into v_val;
    end if;
    insert into flow.producer_stats as s (producer_id, open_jobs, units_in_transit, units_held, value_held, on_time_rate, avg_turnaround_days,
        late_returns, discrepancy_rate, return_accuracy, orders_blocked, refreshed_at)
    select p.id,
      (select count(*) from flow.tp_movements m where m.producer_id = p.id and m.status in ('dispatched','received_by_producer','in_production','production_complete','in_transit_back','partially_returned')),
      (select coalesce(sum(c.qty), 0) from flow.stock_custody c where c.producer_id = p.id and c.location_state in ('in_transit_to_producer','in_transit_back')),
      (select coalesce(sum(c.qty), 0) from flow.stock_custody c where c.producer_id = p.id and c.location_state in ('at_producer','in_production_at_producer')),
      v_val,
      (select round(100.0 * count(*) filter (where m.actual_return_date <= m.expected_return_date) / nullif(count(*), 0), 2) from flow.tp_movements m
        where m.producer_id = p.id and m.actual_return_date is not null and m.expected_return_date is not null and m.actual_return_date > current_date - 180),
      (select round(avg(m.actual_return_date - m.received_by_producer_at::date), 1) from flow.tp_movements m
        where m.producer_id = p.id and m.actual_return_date is not null and m.received_by_producer_at is not null and m.actual_return_date > current_date - 180),
      (select count(*) from flow.tp_movements m where m.producer_id = p.id and ((m.actual_return_date > m.expected_return_date)
          or (m.actual_return_date is null and m.expected_return_date < current_date and m.status in ('dispatched','received_by_producer','in_production','production_complete','in_transit_back','partially_returned')))),
      (select round(100.0 * coalesce(sum(i.qty_damaged + i.qty_rejected + i.qty_outstanding), 0) / nullif(sum(i.qty_sent), 0), 2)
        from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id
        where m.producer_id = p.id and m.status in ('partially_returned','returned','checked','closed','exception') and m.created_at > now() - interval '180 days'),
      null,
      (select count(distinct x.order_id) from (
          select d.order_id from flow.tp_discrepancies d where d.producer_id = p.id and d.status in ('open','investigating') and d.order_id is not null
          union select i.order_id from flow.tp_movements m join flow.tp_movement_items i on i.movement_id = m.id
                where m.producer_id = p.id and m.expected_return_date < current_date
                  and m.status in ('dispatched','received_by_producer','in_production','production_complete','in_transit_back','partially_returned')) x),
      now()
    on conflict (producer_id) do update set open_jobs = excluded.open_jobs, units_in_transit = excluded.units_in_transit, units_held = excluded.units_held,
      value_held = excluded.value_held, on_time_rate = excluded.on_time_rate, avg_turnaround_days = excluded.avg_turnaround_days, late_returns = excluded.late_returns,
      discrepancy_rate = excluded.discrepancy_rate, orders_blocked = excluded.orders_blocked, refreshed_at = excluded.refreshed_at;
    update flow.producer_stats set return_accuracy = case when discrepancy_rate is null then null else round(100 - discrepancy_rate, 2) end where producer_id = p.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'producers_refreshed', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Label / document payloads (rendered by the dashboard; QR text is 'tp:<code>')
-- ---------------------------------------------------------------------------
create or replace function flow.tp_label_payloads(p_movement text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  m flow.tp_movements; v_prod flow.producers; v_base text; v_qr text; v_orders jsonb; v_lines jsonb; v_units int; v_contents text; v_due date; v_methods text;
  v_prio text; v_special text;
begin
  m := flow.tp_find(p_movement);
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'movement not found'); end if;
  select * into v_prod from flow.producers where id = m.producer_id;
  v_base := coalesce((select value #>> '{}' from flow.flow_settings where key = 'labels.base_url'), (select value->>'base_url' from flow.flow_settings where key = 'labels.defaults'), '');
  v_qr := case when v_base <> '' then v_base || '/#/tp/' || m.movement_code else 'tp:' || m.movement_code end;
  select coalesce(sum(qty_sent), 0)::int into v_units from flow.tp_movement_items where movement_id = m.id;
  v_due := coalesce(m.expected_return_date, current_date + ceil(v_prod.turnaround_days)::int + 1);
  select string_agg(format('%s × %s %s', q.qty, coalesce(q.colour, ''), coalesce(q.garment, 'item')), ' / ' order by q.colour, q.garment)
    into v_contents from (select sum(i.qty_sent) qty, i.colour, coalesce(l.garment_type, l.product_name) garment
                          from flow.tp_movement_items i join flow.order_lines l on l.id = i.order_line_id where i.movement_id = m.id group by 2, 3) q;
  select string_agg(distinct upper(x), ' + ') into v_methods from flow.tp_movement_items i join flow.order_lines l on l.id = i.order_line_id, unnest(l.decoration_methods) x where i.movement_id = m.id;
  select case when bool_or(o.due_date < now()) then 'OVERDUE' when max(o.priority) >= 2 then 'RUSH' when max(o.priority) = 1 then 'HIGH' else 'NORMAL' end into v_prio
    from flow.tp_movement_items i join flow.orders o on o.id = i.order_id where i.movement_id = m.id;
  select coalesce(jsonb_agg(jsonb_build_object('order_ref', o.order_ref, 'customer', o.customer_name, 'due_date', o.due_date::date, 'units', t.u,
           'notes', o.production_notes) order by o.order_ref), '[]'::jsonb) into v_orders
    from (select order_id, sum(qty_sent) u from flow.tp_movement_items where movement_id = m.id group by 1) t join flow.orders o on o.id = t.order_id;
  v_special := concat_ws(' | ', v_prod.special_instructions, m.notes);
  select jsonb_agg(jsonb_build_object('order_ref', o.order_ref, 'sku', i.sku, 'product', l.product_name, 'colour', i.colour, 'size', i.size, 'qty', i.qty_sent,
           'methods', l.decoration_methods, 'stitches_per_piece', l.stitches_per_piece, 'expected_back', i.qty_expected_back) order by o.order_ref, i.sku, i.size)
    into v_lines from flow.tp_movement_items i join flow.orders o on o.id = i.order_id join flow.order_lines l on l.id = i.order_line_id where i.movement_id = m.id;
  perform flow.tp_log(m.id, 'labels_generated', 'system');
  return jsonb_build_object('ok', true, 'movement_code', m.movement_code, 'qr_payload', v_qr,
    'outbound_label', jsonb_build_object('title', 'ATAM FLOW — OUTBOUND TO PRODUCER', 'producer', v_prod.name, 'movement', m.movement_code,
       'orders', (select jsonb_agg(x->>'order_ref') from jsonb_array_elements(v_orders) x), 'customers', (select jsonb_agg(distinct x->>'customer') from jsonb_array_elements(v_orders) x),
       'total_units', v_units, 'contents', v_contents, 'decoration', v_methods, 'due_back', v_due, 'due_back_is_tentative', m.expected_return_date is null,
       'priority', v_prio, 'special_instructions', v_special, 'staging_bin', (select bin_code from flow.bins where id = m.staging_bin_id), 'qr_payload', v_qr),
    'consignment_label', jsonb_build_object('to', v_prod.name, 'address', v_prod.address, 'contact', v_prod.contact_name, 'phone', v_prod.phone,
       'movement', m.movement_code, 'carrier', m.carrier, 'total_units', v_units, 'qr_payload', v_qr),
    'order_bag_labels', v_orders,
    'job_sheet', jsonb_build_object('movement', m.movement_code, 'producer', v_prod.name, 'send_date', m.dispatch_date, 'due_back', v_due,
       'special_instructions', v_special, 'quality_notes', v_prod.quality_notes, 'lines', coalesce(v_lines, '[]'::jsonb), 'qr_payload', v_qr),
    'return_checklist', jsonb_build_object('movement', m.movement_code, 'producer', v_prod.name, 'expected_back', coalesce(v_lines, '[]'::jsonb),
       'steps', jsonb_build_array('Scan the movement QR', 'Count each SKU/colour/size against this list', 'Record damaged or wrongly decorated units', 'Photograph any problem', 'Attach the producer delivery note')));
end $$;

-- ---------------------------------------------------------------------------
-- Read models for the dashboard
-- ---------------------------------------------------------------------------
create or replace view flow.v_tp_movements_live with (security_invoker = true) as
select m.id as movement_id, m.movement_code, m.movement_type, m.status, p.id as producer_id, p.code as producer_code, p.name as producer_name,
       m.dispatch_date, m.expected_return_date, m.actual_return_date, m.received_by_producer_at, m.carrier, m.tracking_ref, m.consignment_ref,
       t.units_sent, t.units_expected_back, t.units_received_good, t.units_damaged, t.units_rejected, t.units_outstanding, t.order_refs,
       (m.expected_return_date < current_date and m.status in ('dispatched','received_by_producer','in_production','production_complete','in_transit_back','partially_returned')) as is_overdue,
       greatest(current_date - m.expected_return_date, 0) as days_overdue,
       case when m.expected_return_date is null then 'unknown' when m.expected_return_date < current_date then 'overdue'
            when m.expected_return_date = current_date then 'today' when m.expected_return_date = current_date + 1 then 'tomorrow' else 'later' end as return_bucket,
       (select count(*) from flow.tp_discrepancies d where d.movement_id = m.id and d.status in ('open','investigating')) as open_discrepancies,
       m.staging_bin_id, m.created_at
from flow.tp_movements m
join flow.producers p on p.id = m.producer_id
left join lateral (select sum(i.qty_sent)::int units_sent, sum(i.qty_expected_back)::int units_expected_back, sum(i.qty_received_back)::int units_received_good,
                          sum(i.qty_damaged)::int units_damaged, sum(i.qty_rejected)::int units_rejected, sum(i.qty_outstanding)::int units_outstanding,
                          array_agg(distinct o.order_ref) order_refs
                   from flow.tp_movement_items i join flow.orders o on o.id = i.order_id where i.movement_id = m.id) t on true;

create or replace view flow.v_tp_orders with (security_invoker = true) as
select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.priority, o.order_status, r.id as route_id, r.tp_status, r.direct_dispatch,
       p.id as producer_id, p.name as producer_name, mv.movement_code, mv.expected_return_date,
       (mv.expected_return_date < current_date and r.tp_status not in ('returned_to_warehouse','return_checked','ready_for_dispatch','dispatched_to_customer','completed')) as is_return_overdue,
       (mv.expected_return_date is not null and o.due_date is not null and mv.expected_return_date + 1 > o.due_date::date) as at_risk_of_missing_due_date,
       (select count(*) from flow.tp_discrepancies d where d.order_id = o.id and d.status in ('open','investigating')) as open_discrepancies,
       flow.order_completion_check(o.id) as completion
from flow.production_routes r
join flow.orders o on o.id = r.order_id
join flow.producers p on p.id = r.producer_id
left join lateral (select m.movement_code, m.expected_return_date from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id
                   where i.route_id = r.id and m.status <> 'cancelled' order by m.created_at desc limit 1) mv on true
where r.kind = 'third_party' and r.route_status = 'confirmed' and o.is_active;

create or replace view flow.v_producer_held_stock with (security_invoker = true) as
select p.id as producer_id, p.name as producer_name, c.location_state, l.sku, l.colour, l.size, l.product_name, sum(c.qty)::int as qty,
       count(distinct l.order_id) as orders
from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id join flow.producers p on p.id = c.producer_id
where c.qty > 0 and c.location_state in ('picked_for_producer','in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back')
group by p.id, p.name, c.location_state, l.sku, l.colour, l.size, l.product_name;

create or replace view flow.v_custody_summary with (security_invoker = true) as
select l.order_id, c.order_line_id, l.sku, l.colour, l.size, c.location_state, c.movement_id, c.producer_id, c.qty
from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id where c.qty > 0;

create or replace view flow.v_tp_open_discrepancies with (security_invoker = true) as
select d.id, d.disc_type, d.qty, d.status, d.opened_at, d.blocks_completion, m.movement_code, p.name as producer_name, o.order_ref, o.customer_name, d.resolution_note
from flow.tp_discrepancies d join flow.tp_movements m on m.id = d.movement_id join flow.producers p on p.id = d.producer_id
left join flow.orders o on o.id = d.order_id where d.status in ('open','investigating');

-- ---------------------------------------------------------------------------
-- RLS + grants + n8n wrappers
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['producers','producer_stats','production_routes','route_lines','tp_movements','tp_movement_items','tp_movement_events',
                           'tp_discrepancies','stock_custody','custody_events'] loop
    execute format('alter table flow.%I enable row level security', t);
    execute format('create policy %I on flow.%I for select to authenticated using (flow.is_member())', t || '_read', t);
  end loop;
end $$;
create policy producers_cfg_write on flow.producers for all to authenticated
  using (flow.has_role('admin','manager')) with check (flow.has_role('admin','manager'));
grant select on all tables in schema flow to authenticated;
grant insert, update on flow.producers to authenticated;
grant all on all tables in schema flow to service_role;
grant usage, select on all sequences in schema flow to authenticated, service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'flow.tp_log(uuid,text,text,jsonb,text)', 'flow.tp_pick_list(uuid)', 'flow.order_completion_check(uuid)', 'flow.tp_sync_order_status(uuid)',
    'flow.tp_sync_movement_orders(uuid)', 'flow.create_outbound_movement(uuid,jsonb,text,text,text,text)', 'flow.tp_scan(text,text,text,jsonb)',
    'flow.tp_record_return(text,jsonb,text,jsonb)', 'flow.tp_check_return(text,jsonb,text,jsonb)', 'flow.tp_direct_dispatch(text,text,text,jsonb,text)',
    'flow.tp_reconcile_shipped(text)', 'flow.tp_resolve_discrepancy(uuid,text,text,text)', 'flow.tp_overdue_check()', 'flow.refresh_producer_stats()',
    'flow.tp_label_payloads(text)', 'flow.custody_total(uuid)', 'flow.custody_seed(uuid,int,text,text)',
    'flow.custody_move(uuid,flow.custody_state,uuid,flow.custody_state,uuid,int,uuid,text,text)',
    'flow.custody_take_from_producer(uuid,uuid,flow.custody_state,int,uuid,text,text)', 'flow.tp_find(text)', 'flow.tp_set_route_status(uuid,flow.tp_status)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

create or replace function public.flow_create_outbound_movement(p_producer uuid, p_items jsonb, p_actor text, p_type text default 'outbound_to_producer', p_carrier text default null, p_notes text default null) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.create_outbound_movement(p_producer, p_items, p_actor, p_type, p_carrier, p_notes) $$;
create or replace function public.flow_tp_scan(p_movement text, p_event text, p_actor text, p_payload jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_scan(p_movement, p_event, p_actor, p_payload) $$;
create or replace function public.flow_tp_record_return(p_movement text, p_items jsonb, p_actor text, p_payload jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_record_return(p_movement, p_items, p_actor, p_payload) $$;
create or replace function public.flow_tp_check_return(p_movement text, p_items jsonb, p_actor text, p_payload jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_check_return(p_movement, p_items, p_actor, p_payload) $$;
create or replace function public.flow_tp_direct_dispatch(p_movement text, p_tracking text, p_carrier text, p_pod jsonb, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_direct_dispatch(p_movement, p_tracking, p_carrier, p_pod, p_actor) $$;
create or replace function public.flow_tp_resolve_discrepancy(p_id uuid, p_resolution text, p_note text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_resolve_discrepancy(p_id, p_resolution, p_note, p_actor) $$;
create or replace function public.flow_tp_overdue_check() returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_overdue_check() $$;
create or replace function public.flow_refresh_producer_stats() returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.refresh_producer_stats() $$;
create or replace function public.flow_tp_label_payloads(p_movement text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_label_payloads(p_movement) $$;
create or replace function public.flow_order_completion_check(p_order uuid) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.order_completion_check(p_order) $$;
create or replace function public.flow_tp_reconcile_shipped(p_actor text default 'system') returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.tp_reconcile_shipped(p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.flow_create_outbound_movement(uuid,jsonb,text,text,text,text)', 'public.flow_tp_scan(text,text,text,jsonb)',
    'public.flow_tp_record_return(text,jsonb,text,jsonb)', 'public.flow_tp_check_return(text,jsonb,text,jsonb)',
    'public.flow_tp_direct_dispatch(text,text,text,jsonb,text)', 'public.flow_tp_resolve_discrepancy(uuid,text,text,text)',
    'public.flow_tp_overdue_check()', 'public.flow_refresh_producer_stats()', 'public.flow_tp_label_payloads(text)',
    'public.flow_order_completion_check(uuid)', 'public.flow_tp_reconcile_shipped(text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
