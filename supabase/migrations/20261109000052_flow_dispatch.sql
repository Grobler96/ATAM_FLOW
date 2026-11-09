-- Dispatch queue and courier labels.
-- ATAM_FLOW does not book couriers (there is no courier connection) and DecoNetwork stays the place an order is marked shipped. What this adds is the
-- worklist and the paperwork on our side: which orders are ready to go (and for the ones that are not, why), packing into numbered parcels with a
-- courier label each, the courier's tracking number typed in, and a scan-to-hand-over that records the parcel left with the courier.
-- Nothing here changes stock, order status or DecoNetwork. Every step is audited; sending an order that is not ready needs a manager's reason.

create table flow.dispatch_parcels (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references flow.orders(id),
  parcel_no     int not null check (parcel_no > 0),
  parcels_total int not null check (parcels_total > 0 and parcels_total <= 20),
  label_code    text not null unique,                       -- printed as the barcode and QR on the courier label, e.g. DSP-636220-1of3
  kind          text not null default 'courier' check (kind in ('courier', 'collection')),
  weight_kg     numeric(8,2) check (weight_kg is null or weight_kg > 0),
  carrier       text,
  service       text,
  tracking_ref  text,
  status        text not null default 'packed' check (status in ('packed', 'handed_over', 'cancelled')),
  note          text,
  override_reason text,                                     -- set when the order was packed or handed over while not ready
  packed_by     text not null,
  packed_at     timestamptz not null default now(),
  print_count   int not null default 0,
  last_printed_at timestamptz,
  last_printed_by text,
  handed_by     text,
  handed_at     timestamptz,
  cancelled_by  text,
  cancelled_at  timestamptz,
  cancel_reason text
);
create unique index dispatch_parcels_active on flow.dispatch_parcels (order_id, parcel_no) where status <> 'cancelled';
create index dispatch_parcels_order on flow.dispatch_parcels (order_id);
alter table flow.dispatch_parcels enable row level security;
create policy dispatch_parcels_read on flow.dispatch_parcels for select to authenticated using (flow.is_member());

-- Delivery details for an order (DecoNetwork's free-text address block and shipping method). Members only; the service role may also call it.
create or replace function flow.dispatch_address(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare o flow.orders; u record;
begin
  if auth.uid() is not null and not flow.is_member() then return null; end if;
  select * into o from flow.orders where id = p_order; if o.id is null then return null; end if;
  select shipping_address, shipping_method, ship_country, customer_po_number into u from public.upcoming_orders where order_id = o.deco_order_id;
  return jsonb_build_object('ship_to', nullif(btrim(coalesce(u.shipping_address, '')), ''), 'shipping_method', coalesce(nullif(btrim(coalesce(u.shipping_method, '')), ''), o.shipping_method),
    'ship_country', u.ship_country, 'customer_po', coalesce(nullif(btrim(coalesce(u.customer_po_number, '')), ''), o.customer_po),
    'is_collection', coalesce(u.shipping_method, o.shipping_method, '') ilike '%collect%');
end $$;

-- Is this order ready to go out, and if not, why not? Plain-English reasons. A decorator's work that is only partly back is "partly ready".
create or replace function flow.dispatch_state(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare o flow.orders; chk jsonb; exc jsonb; v_routed int; v_ready int; v_can boolean; v_partial boolean := false; v_block jsonb := '[]'::jsonb; e jsonb; a jsonb;
begin
  if auth.uid() is not null and not flow.is_member() then return null; end if;
  select * into o from flow.orders where id = p_order; if o.id is null then return null; end if;
  a := flow.dispatch_address(p_order);
  chk := flow.order_completion_check(p_order); exc := flow.order_blocking_exceptions(p_order, 'dispatch');
  v_routed := coalesce((chk->>'routed_units')::int, 0); v_ready := coalesce((chk->>'ready_units')::int, 0);
  if v_routed > 0 then                                          -- work that went to a decorator: units must be back and checked
    v_can := coalesce((chk->>'can_dispatch_partial')::boolean, false); v_partial := v_can and not coalesce((chk->>'can_dispatch_all')::boolean, false);
    if coalesce((chk->>'open_discrepancies')::int, 0) > 0 then v_block := v_block || to_jsonb(format('%s open discrepancy record(s) with a decorator', (chk->>'open_discrepancies')::int)); end if;
    if v_ready = 0 then
      v_block := v_block || to_jsonb(format('No checked units are waiting to go out yet (%s unit(s) still with a decorator, %s back but not yet checked)', coalesce((chk->>'with_producer_units')::int, 0), coalesce((chk->>'unchecked_units')::int, 0)));
    end if;
  else                                                          -- not routed through a decorator
    v_can := o.order_status = 'ready_for_dispatch' and jsonb_array_length(exc) = 0;
    if o.order_status <> 'ready_for_dispatch' then v_block := v_block || to_jsonb(format('The order is "%s", not ready for dispatch yet', replace(o.order_status::text, '_', ' '))); end if;
  end if;
  for e in select * from jsonb_array_elements(exc) loop v_block := v_block || to_jsonb(coalesce(e->>'description', e->>'exc_ref')); end loop;
  if o.shipped_at is not null then v_can := false; v_block := v_block || to_jsonb('DecoNetwork already shows this order as shipped'::text); end if;
  return jsonb_build_object('can_pack', v_can and jsonb_array_length(v_block) = 0, 'partial', v_partial, 'blockers', v_block,
    'ready_units', v_ready, 'routed_units', v_routed, 'with_producer_units', coalesce((chk->>'with_producer_units')::int, 0), 'unchecked_units', coalesce((chk->>'unchecked_units')::int, 0),
    'ship_to', a->'ship_to', 'shipping_method', a->'shipping_method', 'ship_country', a->'ship_country', 'customer_po', a->'customer_po', 'is_collection', a->'is_collection');
end $$;

-- ---------------------------------------------------------------------------
-- Actions (service role, called by the Operations actions workflow)
-- ---------------------------------------------------------------------------
create or replace function flow.dispatch_pack(p_order uuid, p_parcels int, p_weights numeric[], p_carrier text, p_service text, p_note text, p_override text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; s jsonb; v_active int; i int; v_code text; v_coll boolean; v_ovr text := nullif(btrim(coalesce(p_override, '')), ''); v_codes text[] := '{}'; v_car text; v_w numeric;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if o.shipped_at is not null or o.order_status = 'dispatched' then return jsonb_build_object('ok', false, 'error', 'This order has already shipped.'); end if;
  if p_parcels is null or p_parcels < 1 or p_parcels > 20 then return jsonb_build_object('ok', false, 'error', 'Enter how many parcels (1 to 20).'); end if;
  if p_weights is not null and coalesce(array_length(p_weights, 1), 0) > p_parcels then return jsonb_build_object('ok', false, 'error', 'There are more weights than parcels.'); end if;
  select count(*) into v_active from flow.dispatch_parcels where order_id = p_order and status <> 'cancelled';
  if v_active > 0 then return jsonb_build_object('ok', false, 'error', 'This order is already packed. Cancel the packing first if you need to change it.'); end if;
  s := flow.dispatch_state(p_order);
  if not coalesce((s->>'can_pack')::boolean, false) then
    if v_ovr is null or length(v_ovr) < 5 then
      return jsonb_build_object('ok', false, 'needs_override', true, 'blockers', s->'blockers',
        'error', 'Not ready to go out: ' || coalesce((select string_agg(x, '; ') from jsonb_array_elements_text(s->'blockers') x), 'unknown reason') || '. A manager can send it anyway with a written reason.');
    end if;
  else v_ovr := null; end if;
  v_coll := coalesce((s->>'is_collection')::boolean, false);
  v_car := case when v_coll then 'Customer collection' else coalesce(nullif(btrim(coalesce(p_carrier, '')), ''), s->>'shipping_method') end;
  for i in 1..p_parcels loop
    v_code := 'DSP-' || upper(replace(o.order_ref, '#', '')) || '-' || i || 'of' || p_parcels;
    if exists (select 1 from flow.dispatch_parcels where label_code = v_code) then v_code := v_code || '-' || substr(gen_random_uuid()::text, 1, 4); end if;
    v_w := case when p_weights is not null and i <= coalesce(array_length(p_weights, 1), 0) and p_weights[i] > 0 then p_weights[i] end;
    insert into flow.dispatch_parcels (order_id, parcel_no, parcels_total, label_code, kind, weight_kg, carrier, service, note, override_reason, packed_by)
    values (p_order, i, p_parcels, v_code, case when v_coll then 'collection' else 'courier' end, v_w, v_car, nullif(btrim(coalesce(p_service, '')), ''), nullif(btrim(coalesce(p_note, '')), ''), v_ovr, p_actor);
    v_codes := v_codes || v_code;
  end loop;
  perform flow.wh_audit(p_actor, case when v_ovr is not null then 'dispatch_pack_override' else 'dispatch_pack' end, 'order', o.order_ref, null,
    jsonb_build_object('parcels', p_parcels, 'labels', v_codes, 'blockers', case when v_ovr is not null then s->'blockers' end), coalesce(v_ovr, p_note));
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'parcels', p_parcels, 'labels', to_jsonb(v_codes), 'kind', case when v_coll then 'collection' else 'courier' end);
end $$;

-- Mark the order's current labels as printed (call it after the print dialog). Printing again is a reprint and needs a reason.
create or replace function flow.dispatch_printed(p_order uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_n int; v_re int; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into o from flow.orders where id = p_order; if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  select count(*), count(*) filter (where print_count > 0) into v_n, v_re from flow.dispatch_parcels where order_id = p_order and status <> 'cancelled';
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'There are no labels to print. Pack the order first.'); end if;
  if v_re > 0 and (v_reason is null or length(v_reason) < 5) then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'These labels were printed before. Say why you are printing them again (at least a few words).'); end if;
  update flow.dispatch_parcels set print_count = print_count + 1, last_printed_at = now(), last_printed_by = p_actor where order_id = p_order and status <> 'cancelled';
  perform flow.wh_audit(p_actor, case when v_re > 0 then 'dispatch_reprint' else 'dispatch_print' end, 'order', o.order_ref, null, jsonb_build_object('labels', v_n), v_reason);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'labels', v_n, 'reprint', v_re > 0);
end $$;

-- The courier's tracking number, typed in after the courier is booked. One parcel, or (no parcel number) every parcel on the order.
create or replace function flow.dispatch_set_tracking(p_order uuid, p_carrier text, p_tracking text, p_parcel_no int, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_t text := btrim(coalesce(p_tracking, '')); v_n int;
begin
  select * into o from flow.orders where id = p_order; if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if length(v_t) < 3 or length(v_t) > 60 then return jsonb_build_object('ok', false, 'error', 'Enter the courier''s tracking reference.'); end if;
  update flow.dispatch_parcels set tracking_ref = v_t, carrier = coalesce(nullif(btrim(coalesce(p_carrier, '')), ''), carrier)
    where order_id = p_order and status <> 'cancelled' and (p_parcel_no is null or parcel_no = p_parcel_no);
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'There is no parcel to put that on. Pack the order first.'); end if;
  perform flow.wh_audit(p_actor, 'dispatch_tracking', 'order', o.order_ref, null, jsonb_build_object('tracking', v_t, 'parcels', v_n, 'carrier', p_carrier), null);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'parcels', v_n);
end $$;

-- A parcel leaves with the courier. Found by its label code (a scan). Checks the order is still fine to send unless a manager gives a reason.
create or replace function flow.dispatch_handover(p_label text, p_override text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.dispatch_parcels; o flow.orders; s jsonb; v_ovr text := nullif(btrim(coalesce(p_override, '')), ''); v_left int; v_notrack int;
begin
  select * into p from flow.dispatch_parcels where upper(label_code) = upper(btrim(coalesce(p_label, '')));
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'That parcel label was not found.'); end if;
  select * into o from flow.orders where id = p.order_id;
  if p.status = 'cancelled' then return jsonb_build_object('ok', false, 'error', 'This label was cancelled. Do not use this parcel; pack the order again and use the new labels.'); end if;
  if p.status = 'handed_over' then
    return jsonb_build_object('ok', true, 'already', true, 'order_ref', o.order_ref, 'customer_name', o.customer_name, 'parcel_no', p.parcel_no, 'parcels_total', p.parcels_total, 'handed_at', p.handed_at, 'kind', p.kind);
  end if;
  if o.shipped_at is null then
    s := flow.dispatch_state(o.id);
    if not coalesce((s->>'can_pack')::boolean, false) then
      if v_ovr is null or length(v_ovr) < 5 then
        return jsonb_build_object('ok', false, 'needs_override', true, 'blockers', s->'blockers', 'order_ref', o.order_ref,
          'error', 'Hold this parcel. ' || o.order_ref || ' is no longer clear to go: ' || coalesce((select string_agg(x, '; ') from jsonb_array_elements_text(s->'blockers') x), 'unknown reason') || '.');
      end if;
    else v_ovr := null; end if;
  else v_ovr := null; end if;
  update flow.dispatch_parcels set status = 'handed_over', handed_by = p_actor, handed_at = now(), override_reason = coalesce(v_ovr, override_reason) where id = p.id;
  select count(*) filter (where status = 'packed'), count(*) filter (where status = 'handed_over' and tracking_ref is null) into v_left, v_notrack
    from flow.dispatch_parcels where order_id = p.order_id and status <> 'cancelled';
  perform flow.wh_audit(p_actor, case when v_ovr is not null then 'dispatch_handover_override' else 'dispatch_handover' end, 'order', o.order_ref, null,
    jsonb_build_object('label', p.label_code, 'parcel', p.parcel_no, 'of', p.parcels_total), v_ovr);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'customer_name', o.customer_name, 'parcel_no', p.parcel_no, 'parcels_total', p.parcels_total, 'kind', p.kind,
    'all_handed', v_left = 0, 'parcels_left', v_left, 'tracking_missing', v_notrack > 0);
end $$;

-- Undo packing before anything has left: the old labels are void (a scan of one is refused).
create or replace function flow.dispatch_cancel(p_order uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_reason text := btrim(coalesce(p_reason, '')); v_handed int; v_n int;
begin
  select * into o from flow.orders where id = p_order; if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if length(v_reason) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the packing is being cancelled (at least a few words).'); end if;
  select count(*) filter (where status = 'handed_over'), count(*) filter (where status = 'packed') into v_handed, v_n from flow.dispatch_parcels where order_id = p_order;
  if v_handed > 0 then return jsonb_build_object('ok', false, 'error', 'Some parcels have already been handed to the courier, so this cannot be cancelled here.'); end if;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'There is nothing packed to cancel.'); end if;
  update flow.dispatch_parcels set status = 'cancelled', cancelled_by = p_actor, cancelled_at = now(), cancel_reason = v_reason where order_id = p_order and status = 'packed';
  perform flow.wh_audit(p_actor, 'dispatch_cancel', 'order', o.order_ref, null, jsonb_build_object('parcels', v_n), v_reason);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'cancelled', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------
-- One row per order that has something ready to go out, or has been packed. Stage: blocked, ready, packed (labels made, still here), with_courier, shipped.
create or replace view public.ui_dispatch_queue with (security_invoker = true) as
with cand as (
  select o.* from flow.orders o
  where o.is_active and (
    (o.shipped_at is null and o.order_status <> 'dispatched' and (o.order_status = 'ready_for_dispatch' or exists (
        select 1 from flow.stock_custody c join flow.order_lines l on l.id = c.order_line_id where l.order_id = o.id and c.location_state = 'ready_for_dispatch' and c.qty > 0)))
    or exists (select 1 from flow.dispatch_parcels p where p.order_id = o.id and p.status <> 'cancelled' and (o.shipped_at is null or o.shipped_at > now() - interval '3 days')))
)
select o.id as order_id, o.order_ref, o.customer_name, s->>'customer_po' as customer_po, o.due_date,
       case when o.due_date is null then null else (o.due_date::date - (now() at time zone 'Europe/London')::date) end as days_to_due,
       o.priority, o.is_vip, flow.order_scope(o) as scope, o.order_status::text as order_status, o.total_units as units,
       coalesce((s->>'ready_units')::int, 0) as ready_units, coalesce((s->>'routed_units')::int, 0) as routed_units,
       s->>'shipping_method' as shipping_method, s->>'ship_to' as ship_to, s->>'ship_country' as ship_country, coalesce((s->>'is_collection')::boolean, false) as is_collection,
       (s->>'can_pack')::boolean as can_pack, (s->>'partial')::boolean as partial, s->'blockers' as blockers,
       (select string_agg(distinct b.bin_code, ', ') from flow.bin_assignments ba join flow.bins b on b.id = ba.bin_id where ba.order_id = o.id and ba.released_at is null) as bins,
       coalesce(pc.active, 0) as parcels, coalesce(pc.handed, 0) as parcels_handed, coalesce(pc.printed, 0) as parcels_printed, pc.tracking, pc.carrier, pc.last_handed_at,
       o.shipped_at,
       case when o.shipped_at is not null then 'shipped'
            when coalesce(pc.active, 0) > 0 and pc.handed = pc.active then 'with_courier'
            when coalesce(pc.active, 0) > 0 then 'packed'
            when (s->>'can_pack')::boolean then 'ready'
            else 'blocked' end as stage
from cand o
cross join lateral flow.dispatch_state(o.id) s
left join lateral (select count(*) filter (where p.status <> 'cancelled') as active, count(*) filter (where p.status = 'handed_over') as handed,
                          count(*) filter (where p.status <> 'cancelled' and p.print_count > 0) as printed,
                          string_agg(distinct p.tracking_ref, ', ') filter (where p.status <> 'cancelled' and p.tracking_ref is not null) as tracking,
                          string_agg(distinct p.carrier, ', ') filter (where p.status <> 'cancelled') as carrier, max(p.handed_at) as last_handed_at
                   from flow.dispatch_parcels p where p.order_id = o.id) pc on true;

-- Parcels with everything a label needs. Cancelled labels stay visible for a week so a stray old label is recognised.
create or replace view public.ui_dispatch_parcels with (security_invoker = true) as
select p.id, p.order_id, o.order_ref, o.customer_name, o.due_date, p.parcel_no, p.parcels_total, p.label_code, p.kind, p.weight_kg, p.carrier, p.service, p.tracking_ref, p.status, p.note, p.override_reason,
       p.packed_by, p.packed_at, p.print_count, p.last_printed_at, p.last_printed_by, p.handed_by, p.handed_at, p.cancelled_at, p.cancel_reason,
       a->>'ship_to' as ship_to, a->>'shipping_method' as shipping_method, a->>'customer_po' as customer_po, a->>'ship_country' as ship_country
from flow.dispatch_parcels p join flow.orders o on o.id = p.order_id
cross join lateral flow.dispatch_address(o.id) a
where p.status <> 'cancelled' or p.cancelled_at > now() - interval '7 days';

-- Wrappers for n8n (service role only)
create or replace function public.flow_dispatch_pack(p_order uuid, p_parcels int, p_weights numeric[], p_carrier text, p_service text, p_note text, p_override text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.dispatch_pack(p_order, p_parcels, p_weights, p_carrier, p_service, p_note, p_override, p_actor) $$;
create or replace function public.flow_dispatch_printed(p_order uuid, p_reason text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.dispatch_printed(p_order, p_reason, p_actor) $$;
create or replace function public.flow_dispatch_set_tracking(p_order uuid, p_carrier text, p_tracking text, p_parcel_no int, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.dispatch_set_tracking(p_order, p_carrier, p_tracking, p_parcel_no, p_actor) $$;
create or replace function public.flow_dispatch_handover(p_label text, p_override text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.dispatch_handover(p_label, p_override, p_actor) $$;
create or replace function public.flow_dispatch_cancel(p_order uuid, p_reason text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.dispatch_cancel(p_order, p_reason, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['flow.dispatch_pack(uuid,int,numeric[],text,text,text,text,text)', 'flow.dispatch_printed(uuid,text,text)', 'flow.dispatch_set_tracking(uuid,text,text,int,text)', 'flow.dispatch_handover(text,text,text)', 'flow.dispatch_cancel(uuid,text,text)',
      'public.flow_dispatch_pack(uuid,int,numeric[],text,text,text,text,text)', 'public.flow_dispatch_printed(uuid,text,text)', 'public.flow_dispatch_set_tracking(uuid,text,text,int,text)', 'public.flow_dispatch_handover(text,text,text)', 'public.flow_dispatch_cancel(uuid,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach f in array array['public.flow_dispatch_pack(uuid,int,numeric[],text,text,text,text,text)', 'public.flow_dispatch_printed(uuid,text,text)', 'public.flow_dispatch_set_tracking(uuid,text,text,int,text)', 'public.flow_dispatch_handover(text,text,text)', 'public.flow_dispatch_cancel(uuid,text,text)']
  loop execute format('grant execute on function %s to service_role', f); end loop;
  -- read helpers used by the two views run as the logged-in user and answer only for team members (null for anyone else)
  revoke all on function flow.dispatch_address(uuid), flow.dispatch_state(uuid) from public, anon;
  grant execute on function flow.dispatch_address(uuid), flow.dispatch_state(uuid) to authenticated, service_role;
  revoke all on flow.dispatch_parcels from public, anon;
  grant select on flow.dispatch_parcels to authenticated;
  revoke all on public.ui_dispatch_queue, public.ui_dispatch_parcels from public, anon;
  grant select on public.ui_dispatch_queue, public.ui_dispatch_parcels to authenticated;
end $$;
