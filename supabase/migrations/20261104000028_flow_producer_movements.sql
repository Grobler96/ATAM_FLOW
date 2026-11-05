-- Producer movement flows: producer + rate-card management, what can be sent, cancelling before dispatch,
-- movement item / timeline read models. The lifecycle itself (create, scan, return, check, direct dispatch,
-- resolve) already exists in migrations 12–13.

-- ---------------------------------------------------------------------------
-- Producers and rate cards
-- ---------------------------------------------------------------------------
create or replace function flow.mv_upsert_producer(p jsonb, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_name text := btrim(coalesce(p->>'name', '')); v_code text; v_before jsonb; v_methods text[];
begin
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'A producer needs a name.'); end if;
  if p ? 'turnaround_days' and (nullif(p->>'turnaround_days', '') is null or (p->>'turnaround_days')::numeric < 0 or (p->>'turnaround_days')::numeric > 60) then
    return jsonb_build_object('ok', false, 'error', 'Turnaround must be between 0 and 60 days.'); end if;
  if p ? 'capable_methods' then select coalesce(array_agg(lower(btrim(x))) filter (where btrim(x) <> ''), '{}') into v_methods from jsonb_array_elements_text(p->'capable_methods') x; end if;
  if v_id is null then
    v_code := upper(regexp_replace(coalesce(nullif(btrim(p->>'code'), ''), left(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g'), 6)), '[^A-Za-z0-9]', '', 'g'));
    if v_code = '' then return jsonb_build_object('ok', false, 'error', 'Could not make a short code from that name.'); end if;
    if exists (select 1 from flow.producers where code = v_code) then v_code := v_code || (select (count(*) + 1)::text from flow.producers where code like v_code || '%'); end if;
    insert into flow.producers (code, name, contact_name, email, phone, address, default_method, capable_methods, turnaround_days, daily_capacity_units, weekly_capacity_units, can_direct_dispatch, quality_notes, special_instructions, rate_card_ref)
    values (v_code, v_name, nullif(p->>'contact_name', ''), nullif(p->>'email', ''), nullif(p->>'phone', ''), nullif(p->>'address', ''), coalesce(nullif(p->>'default_method', ''), 'courier'), coalesce(v_methods, '{}'),
            coalesce(nullif(p->>'turnaround_days', '')::numeric, 3), nullif(p->>'daily_capacity_units', '')::int, nullif(p->>'weekly_capacity_units', '')::int, coalesce((p->>'can_direct_dispatch')::boolean, false),
            nullif(p->>'quality_notes', ''), nullif(p->>'special_instructions', ''), nullif(p->>'rate_card_ref', ''))
    returning id into v_id;
    perform flow.wh_audit(p_actor, 'producer_created', 'producer', v_code, null, jsonb_build_object('name', v_name), null);
    return jsonb_build_object('ok', true, 'producer_id', v_id, 'code', v_code, 'created', true);
  end if;
  select to_jsonb(x) into v_before from flow.producers x where id = v_id;
  if v_before is null then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  update flow.producers set name = v_name, contact_name = case when p ? 'contact_name' then nullif(p->>'contact_name', '') else contact_name end,
    email = case when p ? 'email' then nullif(p->>'email', '') else email end, phone = case when p ? 'phone' then nullif(p->>'phone', '') else phone end,
    address = case when p ? 'address' then nullif(p->>'address', '') else address end, default_method = coalesce(nullif(p->>'default_method', ''), default_method),
    capable_methods = case when p ? 'capable_methods' then coalesce(v_methods, '{}') else capable_methods end,
    turnaround_days = coalesce(nullif(p->>'turnaround_days', '')::numeric, turnaround_days),
    daily_capacity_units = case when p ? 'daily_capacity_units' then nullif(p->>'daily_capacity_units', '')::int else daily_capacity_units end,
    weekly_capacity_units = case when p ? 'weekly_capacity_units' then nullif(p->>'weekly_capacity_units', '')::int else weekly_capacity_units end,
    can_direct_dispatch = coalesce((p->>'can_direct_dispatch')::boolean, can_direct_dispatch), is_active = coalesce((p->>'is_active')::boolean, is_active),
    quality_notes = case when p ? 'quality_notes' then nullif(p->>'quality_notes', '') else quality_notes end,
    special_instructions = case when p ? 'special_instructions' then nullif(p->>'special_instructions', '') else special_instructions end
  where id = v_id;
  perform flow.wh_audit(p_actor, 'producer_updated', 'producer', v_before->>'code', v_before, p, null);
  return jsonb_build_object('ok', true, 'producer_id', v_id, 'code', v_before->>'code', 'created', false);
end $$;

create or replace function flow.mv_set_rate(p_producer uuid, p_method text, p_basis text, p_unit_price numeric, p_setup_fee numeric default 0, p_min_job numeric default 0,
                                            p_notes text default null, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if not exists (select 1 from flow.producers where id = p_producer) then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  if coalesce(btrim(p_method), '') = '' then return jsonb_build_object('ok', false, 'error', 'Choose a decoration method.'); end if;
  if p_basis not in ('per_1000_stitches', 'per_piece') then return jsonb_build_object('ok', false, 'error', 'Basis must be per_1000_stitches or per_piece.'); end if;
  if p_unit_price is null or p_unit_price < 0 or coalesce(p_setup_fee, 0) < 0 or coalesce(p_min_job, 0) < 0 then return jsonb_build_object('ok', false, 'error', 'Prices cannot be negative.'); end if;
  insert into flow.producer_rates (producer_id, method, basis, unit_price, setup_fee, min_job_charge, notes) values (p_producer, lower(btrim(p_method)), p_basis, p_unit_price, coalesce(p_setup_fee, 0), coalesce(p_min_job, 0), nullif(p_notes, ''))
  on conflict (producer_id, method) do update set basis = excluded.basis, unit_price = excluded.unit_price, setup_fee = excluded.setup_fee, min_job_charge = excluded.min_job_charge, notes = excluded.notes, updated_at = now();
  perform flow.wh_audit(p_actor, 'producer_rate_set', 'producer', p_producer::text, null, jsonb_build_object('method', lower(btrim(p_method)), 'basis', p_basis, 'unit_price', p_unit_price, 'setup_fee', p_setup_fee, 'min_job', p_min_job), null);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- What can be sent: units still needed, covered by secured stock, not already committed to a producer.
-- ---------------------------------------------------------------------------
create or replace view flow.v_tp_sendable_lines with (security_invoker = true) as
select x.* from (
  select l.id as order_line_id, o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.order_status, l.sku, l.product_name, l.colour, l.size, l.decoration_methods,
         greatest(l.qty_required - l.qty_produced, 0) as qty_needed,
         least(greatest(l.qty_required - l.qty_produced, 0),
               case when o.stock_secured then greatest(l.qty_required - l.qty_produced, 0)
                    else coalesce((select sum(a.qty) from flow.allocations a where a.order_line_id = l.id and a.status = 'active' and a.source = 'on_hand'), 0)::int end)
         - coalesce((select sum(i.qty_sent - i.qty_damaged - i.qty_rejected) from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where i.order_line_id = l.id and m.status <> 'cancelled'), 0)::int as qty_sendable
  from flow.order_lines l join flow.orders o on o.id = l.order_id
  where l.is_active and o.is_active and o.shipped_at is null) x
where x.qty_sendable > 0;

create or replace view flow.v_tp_items with (security_invoker = true) as
select i.id as item_id, m.movement_code, m.id as movement_id, o.id as order_id, o.order_ref, o.customer_name, i.order_line_id, i.sku, l.product_name, i.colour, i.size,
       i.qty_sent, i.qty_expected_back, i.qty_received_back, i.qty_damaged, i.qty_rejected, i.qty_checked_ok, i.qty_outstanding,
       coalesce((select sum(c.qty) from flow.stock_custody c where c.order_line_id = i.order_line_id and c.movement_id = m.id and c.location_state = 'returned_to_warehouse'), 0)::int as qty_awaiting_check
from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id join flow.orders o on o.id = i.order_id join flow.order_lines l on l.id = i.order_line_id;

create or replace view flow.v_tp_events with (security_invoker = true) as
select e.id, m.movement_code, e.at, e.event, e.actor, e.details, e.note from flow.tp_movement_events e join flow.tp_movements m on m.id = e.movement_id;

create or replace view public.ui_tp_sendable_lines with (security_invoker = true) as select * from flow.v_tp_sendable_lines;
create or replace view public.ui_tp_items with (security_invoker = true) as select * from flow.v_tp_items;
create or replace view public.ui_tp_events with (security_invoker = true) as select * from flow.v_tp_events;
create or replace view public.ui_producer_rates with (security_invoker = true) as
select r.id, r.producer_id, p.name as producer_name, r.method, r.basis, r.unit_price, r.setup_fee, r.min_job_charge, r.notes, r.updated_at from flow.producer_rates r join flow.producers p on p.id = r.producer_id;
create or replace view public.ui_producers_all with (security_invoker = true) as
select p.*, (select count(*) from flow.producer_rates r where r.producer_id = p.id) as rate_count from flow.producers p;

create or replace function public.ui_tp_pick_list(p_code text) returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when flow.is_member() then (select flow.tp_pick_list(m.id) from flow.tp_movements m where m.movement_code = p_code) else '[]'::jsonb end
$$;

-- ---------------------------------------------------------------------------
-- Cancel a consignment that has not left the building (draft, picked or packed). Units go back to the order; nothing is deleted.
-- ---------------------------------------------------------------------------
create or replace function flow.mv_cancel_movement(p_movement text, p_actor text, p_reason text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; it record; v_from flow.custody_state; r record;
begin
  begin
    m := flow.tp_find(p_movement);
    if m.id is null then raise exception 'movement % not found', p_movement; end if;
    if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why this consignment is being cancelled.'; end if;
    if m.status not in ('draft', 'picked', 'packed') then raise exception '% has already been % and cannot be cancelled here. Use returns, corrections or discrepancies instead.', m.movement_code, replace(m.status::text, '_', ' '); end if;
    v_from := case when m.status = 'draft' then 'allocated_to_order' else 'picked_for_producer' end;
    for it in select * from flow.tp_movement_items where movement_id = m.id loop
      perform flow.custody_move(it.order_line_id, v_from, m.id, 'allocated_to_order', null, it.qty_sent, m.producer_id, p_actor, 'consignment ' || m.movement_code || ' cancelled: ' || p_reason);
    end loop;
    update flow.tp_movements set status = 'cancelled', updated_by = p_actor where id = m.id;
    update flow.tp_movement_items set qty_expected_back = 0 where movement_id = m.id;
    if m.staging_bin_id is not null then update flow.bins set status = 'available' where id = m.staging_bin_id and not exists (select 1 from flow.bin_assignments a where a.bin_id = m.staging_bin_id and a.released_at is null); end if;
    for r in select distinct route_id from flow.tp_movement_items where movement_id = m.id and route_id is not null loop
      if not exists (select 1 from flow.tp_movement_items i join flow.tp_movements x on x.id = i.movement_id where i.route_id = r.route_id and x.status <> 'cancelled') then
        update flow.production_routes set route_status = 'cancelled', tp_status = null, reason = coalesce(reason, '') || ' (consignment ' || m.movement_code || ' cancelled)' where id = r.route_id;
      end if;
    end loop;
    perform flow.tp_log(m.id, 'cancelled', p_actor, jsonb_build_object('reason', p_reason), p_reason);
    perform flow.wh_audit(p_actor, 'movement_cancelled', 'tp_movement', m.movement_code, jsonb_build_object('status', m.status), jsonb_build_object('status', 'cancelled'), p_reason);
    return jsonb_build_object('ok', true, 'movement_code', m.movement_code);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Wrappers (service role only) and grants
-- ---------------------------------------------------------------------------
create or replace function public.flow_mv_upsert_producer(p jsonb, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.mv_upsert_producer(p, p_actor) $$;
create or replace function public.flow_mv_set_rate(p_producer uuid, p_method text, p_basis text, p_unit_price numeric, p_setup_fee numeric, p_min_job numeric, p_notes text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.mv_set_rate(p_producer, p_method, p_basis, p_unit_price, p_setup_fee, p_min_job, p_notes, p_actor) $$;
create or replace function public.flow_mv_cancel_movement(p_movement text, p_actor text, p_reason text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.mv_cancel_movement(p_movement, p_actor, p_reason) $$;

do $$
declare f text; v text;
begin
  foreach f in array array['public.flow_mv_upsert_producer(jsonb,text)', 'public.flow_mv_set_rate(uuid,text,text,numeric,numeric,numeric,text,text)', 'public.flow_mv_cancel_movement(text,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.mv_upsert_producer(jsonb,text)', 'flow.mv_set_rate(uuid,text,text,numeric,numeric,numeric,text,text)', 'flow.mv_cancel_movement(text,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach v in array array['ui_tp_sendable_lines', 'ui_tp_items', 'ui_tp_events', 'ui_producer_rates', 'ui_producers_all'] loop
    execute format('revoke all on public.%I from public, anon', v); execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
revoke all on function public.ui_tp_pick_list(text) from public, anon;
grant execute on function public.ui_tp_pick_list(text) to authenticated;
