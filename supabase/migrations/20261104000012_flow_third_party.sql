-- Third-party production and chain of custody.
-- Every garment sent to a producer stays traceable to its order line: where it is, who holds it, what is owed back.
-- Producer-held / in-transit stock lives ONLY in flow.stock_custody and is never part of available warehouse stock.
-- Conservative rule: a stock allocation stays 'active' (reserved) while its goods are out with a producer, so available
-- stock can never be overstated (revisit once we know exactly when DecoNetwork deducts stock for awaiting-stock orders).

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type flow.tp_status as enum (
  'awaiting_stock','stock_allocated','ready_to_send','picked_for_producer','packed_for_producer','dispatched_to_producer',
  'received_by_producer','in_production_at_producer','production_complete_at_producer','awaiting_return','in_transit_back',
  'returned_to_warehouse','return_checked','ready_for_dispatch','dispatched_to_customer','completed','exception','on_hold');
create type flow.custody_state as enum (
  'at_supplier_incoming','in_warehouse','allocated_to_order','in_internal_production','picked_for_producer',
  'in_transit_to_producer','at_producer','in_production_at_producer','in_transit_back','returned_to_warehouse',
  'ready_for_dispatch','dispatched_to_customer','lost_damaged_discrepancy');
create type flow.tp_movement_type as enum (
  'outbound_to_producer','return_from_producer','direct_dispatch_to_customer','partial_return','correction');
create type flow.tp_movement_status as enum (
  'draft','picked','packed','dispatched','received_by_producer','in_production','production_complete','in_transit_back',
  'partially_returned','returned','checked','closed','exception','cancelled');

-- ---------------------------------------------------------------------------
-- Producers
-- ---------------------------------------------------------------------------
create table flow.producers (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,
  name               text not null,
  contact_name       text,
  email              text,
  phone              text,
  address            text,
  default_method     text not null default 'courier' check (default_method in ('courier','collection','own_van','post')),
  is_active          boolean not null default true,
  capable_methods    text[] not null default '{}',          -- production method codes they can do
  preferred_methods  text[] not null default '{}',          -- ones they are best at
  daily_capacity_units  int,
  weekly_capacity_units int,
  turnaround_days    numeric(4,1) not null default 3,        -- standard, from receipt of goods to ready
  rate_card_ref      text,
  quality_notes      text,
  special_instructions text,
  can_direct_dispatch boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table flow.producer_stats (                           -- scorecard, refreshed by flow.refresh_producer_stats()
  producer_id        uuid primary key references flow.producers(id) on delete cascade,
  open_jobs          int not null default 0,
  units_in_transit   int not null default 0,
  units_held         int not null default 0,
  value_held         numeric(12,2) not null default 0,
  on_time_rate       numeric(5,2),
  avg_turnaround_days numeric(5,1),
  late_returns       int not null default 0,
  discrepancy_rate   numeric(5,2),
  return_accuracy    numeric(5,2),
  orders_blocked     int not null default 0,
  refreshed_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Routes: how each order (or part of it) will be produced
-- ---------------------------------------------------------------------------
create table flow.production_routes (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references flow.orders(id) on delete cascade,
  kind          text not null check (kind in ('internal','third_party')),
  producer_id   uuid references flow.producers(id),
  direct_dispatch boolean not null default false,
  route_status  text not null default 'recommended' check (route_status in ('recommended','confirmed','superseded','cancelled')),
  tp_status     flow.tp_status,
  reason        text,
  score_breakdown jsonb,
  due_back_date date,
  confirmed_by  text,
  confirmed_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((kind = 'third_party') = (producer_id is not null))
);
create index production_routes_order on flow.production_routes (order_id) where route_status in ('recommended','confirmed');
create index production_routes_producer on flow.production_routes (producer_id) where route_status = 'confirmed';
create unique index production_routes_one_active on flow.production_routes
  (order_id, kind, (coalesce(producer_id, '00000000-0000-0000-0000-000000000000'::uuid)), direct_dispatch)
  where route_status in ('recommended','confirmed');

create table flow.route_lines (
  id            uuid primary key default gen_random_uuid(),
  route_id      uuid not null references flow.production_routes(id) on delete cascade,
  order_line_id uuid not null references flow.order_lines(id) on delete cascade,
  qty           int not null check (qty > 0),
  unique (route_id, order_line_id)
);
create or replace function flow.guard_route_lines() returns trigger language plpgsql set search_path = flow, public as $$
declare v_need int; v_used int; v_status text;
begin
  select route_status into v_status from flow.production_routes where id = new.route_id;
  if v_status not in ('recommended','confirmed') then return new; end if;
  select greatest(qty_required - qty_produced, 0) into v_need from flow.order_lines where id = new.order_line_id;
  select coalesce(sum(rl.qty), 0) into v_used from flow.route_lines rl join flow.production_routes r on r.id = rl.route_id
    where rl.order_line_id = new.order_line_id and r.route_status in ('recommended','confirmed') and rl.id <> new.id;
  if v_used + new.qty > v_need then
    raise exception 'route over-commits order line %: % needed, % already routed, % requested', new.order_line_id, v_need, v_used, new.qty
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger route_lines_guard before insert or update of qty on flow.route_lines
  for each row execute function flow.guard_route_lines();

-- ---------------------------------------------------------------------------
-- Movements (every physical handoff to or from a producer) and their items
-- ---------------------------------------------------------------------------
create sequence flow.tp_movement_seq;
create table flow.tp_movements (
  id               uuid primary key default gen_random_uuid(),
  movement_code    text not null unique,
  movement_type    flow.tp_movement_type not null default 'outbound_to_producer',
  producer_id      uuid not null references flow.producers(id),
  status           flow.tp_movement_status not null default 'draft',
  parent_movement_id uuid references flow.tp_movements(id),
  dispatch_date    date,
  expected_return_date date,                    -- for direct dispatch: when the producer should ship to the customer
  actual_return_date date,
  received_by_producer_at timestamptz,
  carrier          text,
  tracking_ref     text,
  consignment_ref  text,
  return_tracking_ref text,
  customer_tracking_ref text,
  proof_of_delivery jsonb,
  staging_bin_id   uuid references flow.bins(id),
  package_info     jsonb not null default '{}'::jsonb,
  evidence         jsonb not null default '[]'::jsonb,        -- [{url, kind, caption, added_by, at}]
  notes            text,
  created_by       text,
  updated_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index tp_movements_open on flow.tp_movements (producer_id, expected_return_date)
  where status not in ('closed','cancelled','checked');

create table flow.tp_movement_items (
  id               uuid primary key default gen_random_uuid(),
  movement_id      uuid not null references flow.tp_movements(id) on delete cascade,
  route_id         uuid references flow.production_routes(id),
  order_id         uuid not null references flow.orders(id),
  order_line_id    uuid not null references flow.order_lines(id),
  sku              text,
  colour           text,
  size             text,
  qty_sent         int not null check (qty_sent > 0),
  qty_expected_back int not null default 0 check (qty_expected_back >= 0),
  qty_received_back int not null default 0 check (qty_received_back >= 0),   -- good units
  qty_damaged      int not null default 0 check (qty_damaged >= 0),          -- returned but damaged
  qty_rejected     int not null default 0 check (qty_rejected >= 0),         -- returned but wrong/poor decoration
  qty_checked_ok   int not null default 0 check (qty_checked_ok >= 0),
  qty_outstanding  int generated always as (greatest(qty_expected_back - qty_received_back - qty_damaged - qty_rejected, 0)) stored,
  created_at       timestamptz not null default now(),
  unique (movement_id, order_line_id)
);
create index tp_items_line on flow.tp_movement_items (order_line_id);
create index tp_items_order on flow.tp_movement_items (order_id);

create table flow.tp_movement_events (                         -- scan / handoff log (append-only)
  id           bigint generated always as identity primary key,
  movement_id  uuid not null references flow.tp_movements(id) on delete cascade,
  at           timestamptz not null default now(),
  event        text not null,
  actor        text,
  scan_payload text,
  details      jsonb not null default '{}'::jsonb,
  note         text
);
create index tp_events_movement on flow.tp_movement_events (movement_id, at);
create trigger tp_events_immutable before update or delete on flow.tp_movement_events
  for each row execute function flow.block_ledger_mutation();

create table flow.tp_discrepancies (
  id            uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references flow.tp_movements(id) on delete cascade,
  item_id       uuid references flow.tp_movement_items(id) on delete cascade,
  order_id      uuid references flow.orders(id),
  order_line_id uuid references flow.order_lines(id),
  producer_id   uuid not null references flow.producers(id),
  disc_type     text not null check (disc_type in ('shortage','overage','damaged','rejected','late','lost','other')),
  qty           int not null default 0,
  status        text not null default 'open' check (status in ('open','investigating','resolved','written_off')),
  resolution    text check (resolution in ('received_later','replaced','credited','accepted','written_off')),
  resolution_note text,
  blocks_completion boolean not null default true,
  evidence      jsonb not null default '[]'::jsonb,
  opened_at     timestamptz not null default now(),
  opened_by     text,
  resolved_at   timestamptz,
  resolved_by   text,
  updated_at    timestamptz not null default now()
);
create index tp_disc_open on flow.tp_discrepancies (producer_id) where status in ('open','investigating');
create unique index tp_disc_one_open_per_item on flow.tp_discrepancies (item_id, disc_type)
  where status in ('open','investigating') and disc_type in ('shortage','overage');
create unique index tp_disc_one_open_late on flow.tp_discrepancies (movement_id)
  where status in ('open','investigating') and disc_type = 'late';

-- ---------------------------------------------------------------------------
-- Chain of custody: where every unit is, per order line
-- ---------------------------------------------------------------------------
create table flow.stock_custody (
  id             uuid primary key default gen_random_uuid(),
  order_line_id  uuid not null references flow.order_lines(id) on delete cascade,
  location_state flow.custody_state not null,
  movement_id    uuid references flow.tp_movements(id),
  producer_id    uuid references flow.producers(id),
  qty            int not null default 0 check (qty >= 0),
  updated_at     timestamptz not null default now()
);
create unique index stock_custody_one on flow.stock_custody
  (order_line_id, location_state, (coalesce(movement_id, '00000000-0000-0000-0000-000000000000'::uuid)));
create index stock_custody_state on flow.stock_custody (location_state) where qty > 0;

create table flow.custody_events (                             -- append-only ledger of every move
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  order_line_id uuid not null references flow.order_lines(id),
  from_state    flow.custody_state,
  to_state      flow.custody_state not null,
  qty           int not null check (qty > 0),
  movement_id   uuid references flow.tp_movements(id),
  producer_id   uuid references flow.producers(id),
  actor         text,
  reason        text
);
create index custody_events_line on flow.custody_events (order_line_id, at);
create trigger custody_events_immutable before update or delete on flow.custody_events
  for each row execute function flow.block_ledger_mutation();

-- updated_at triggers for the new mutable tables
create trigger producers_touch before update on flow.producers for each row execute function flow.touch_updated_at();
create trigger production_routes_touch before update on flow.production_routes for each row execute function flow.touch_updated_at();
create trigger tp_movements_touch before update on flow.tp_movements for each row execute function flow.touch_updated_at();
create trigger tp_discrepancies_touch before update on flow.tp_discrepancies for each row execute function flow.touch_updated_at();
create trigger stock_custody_touch before update on flow.stock_custody for each row execute function flow.touch_updated_at();

insert into flow.bin_zones (code, name, description, sort_order) values
  ('OUT', 'Outbound to producers', 'Staging for consignments going to third-party producers', 25),
  ('RET', 'Returns from producers', 'Goods back from producers awaiting check', 26)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Custody primitives
-- ---------------------------------------------------------------------------
-- Usable units in custody for a line. Quarantined (damaged / lost) units are excluded so replacements can be sent.
create or replace function flow.custody_total(p_line uuid) returns int language sql stable set search_path = flow, public as $$
  select coalesce(sum(qty), 0)::int from flow.stock_custody where order_line_id = p_line and location_state <> 'lost_damaged_discrepancy'
$$;

-- Put units into custody for the first time (e.g. garments DecoNetwork has secured for the order).
create or replace function flow.custody_seed(p_line uuid, p_qty int, p_actor text, p_reason text) returns void
language plpgsql security definer set search_path = flow, public as $$
declare v_req int;
begin
  if p_qty <= 0 then return; end if;
  select qty_required into v_req from flow.order_lines where id = p_line;
  if flow.custody_total(p_line) + p_qty > v_req then
    raise exception 'custody for line % would exceed the % units ordered', p_line, v_req;
  end if;
  insert into flow.stock_custody (order_line_id, location_state, movement_id, qty)
  values (p_line, 'allocated_to_order', null, p_qty)
  on conflict (order_line_id, location_state, (coalesce(movement_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  do update set qty = flow.stock_custody.qty + excluded.qty;
  insert into flow.custody_events (order_line_id, from_state, to_state, qty, actor, reason)
  values (p_line, null, 'allocated_to_order', p_qty, p_actor, p_reason);
end $$;

-- Move units between states. Fails (and rolls back the caller's block) if the source does not hold enough.
create or replace function flow.custody_move(p_line uuid, p_from flow.custody_state, p_from_mv uuid, p_to flow.custody_state,
  p_to_mv uuid, p_qty int, p_producer uuid, p_actor text, p_reason text) returns void
language plpgsql security definer set search_path = flow, public as $$
declare v_have int; v_row uuid;
begin
  if p_qty <= 0 then return; end if;
  select id, qty into v_row, v_have from flow.stock_custody
    where order_line_id = p_line and location_state = p_from
      and coalesce(movement_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_from_mv, '00000000-0000-0000-0000-000000000000'::uuid)
    for update;
  if v_row is null or v_have < p_qty then
    raise exception 'custody: line % holds % in % but % were requested', p_line, coalesce(v_have, 0), p_from, p_qty;
  end if;
  update flow.stock_custody set qty = qty - p_qty where id = v_row;
  insert into flow.stock_custody (order_line_id, location_state, movement_id, producer_id, qty)
  values (p_line, p_to, p_to_mv, p_producer, p_qty)
  on conflict (order_line_id, location_state, (coalesce(movement_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  do update set qty = flow.stock_custody.qty + excluded.qty, producer_id = coalesce(excluded.producer_id, flow.stock_custody.producer_id);
  insert into flow.custody_events (order_line_id, from_state, to_state, qty, movement_id, producer_id, actor, reason)
  values (p_line, p_from, p_to, p_qty, coalesce(p_to_mv, p_from_mv), p_producer, p_actor, p_reason);
end $$;

-- Take up to p_qty from whichever producer-side state still holds the units, moving them to p_to. Returns units moved.
create or replace function flow.custody_take_from_producer(p_line uuid, p_mv uuid, p_to flow.custody_state, p_qty int,
  p_producer uuid, p_actor text, p_reason text) returns int
language plpgsql security definer set search_path = flow, public as $$
declare v_left int := p_qty; v_state flow.custody_state; v_have int; v_take int;
begin
  foreach v_state in array array['in_transit_back','at_producer','in_production_at_producer','in_transit_to_producer']::flow.custody_state[] loop
    exit when v_left <= 0;
    select qty into v_have from flow.stock_custody where order_line_id = p_line and location_state = v_state and movement_id = p_mv;
    v_take := least(coalesce(v_have, 0), v_left);
    if v_take > 0 then
      perform flow.custody_move(p_line, v_state, p_mv, p_to, p_mv, v_take, p_producer, p_actor, p_reason);
      v_left := v_left - v_take;
    end if;
  end loop;
  return p_qty - v_left;
end $$;

create or replace function flow.tp_find(p text) returns flow.tp_movements language sql stable set search_path = flow, public as $$
  select * from flow.tp_movements where movement_code = p or id::text = p limit 1
$$;

-- Recompute an order's overall ATAM_FLOW status from its third-party routes and open discrepancies.
create or replace function flow.tp_sync_order_status(p_order uuid) returns void
language plpgsql security definer set search_path = flow, public as $$
declare v_o flow.orders; v_new flow.order_status; v_reason text;
begin
  select * into v_o from flow.orders where id = p_order;
  if not found or not v_o.is_active or v_o.order_status = 'dispatched' then return; end if;
  if exists (select 1 from flow.tp_discrepancies d where d.order_id = p_order and d.status in ('open','investigating') and d.blocks_completion
             and d.disc_type <> 'shortage') then
    v_new := 'blocked'; v_reason := 'third-party exception: open discrepancy';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed'
                and r.tp_status in ('dispatched_to_producer','received_by_producer','in_production_at_producer','production_complete_at_producer','awaiting_return','in_transit_back')) then
    v_new := 'in_production'; v_reason := 'with third-party producer';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed' and r.tp_status = 'returned_to_warehouse') then
    v_new := 'quality_check'; v_reason := 'returned from producer, awaiting check';
  elsif exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed' and r.tp_status in ('ready_for_dispatch','return_checked'))
        and not exists (select 1 from flow.production_routes r where r.order_id = p_order and r.kind = 'third_party' and r.route_status = 'confirmed' and r.tp_status not in ('ready_for_dispatch','return_checked','dispatched_to_customer','completed')) then
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

create or replace function flow.tp_set_route_status(p_movement uuid, p_status flow.tp_status) returns void
language sql security definer set search_path = flow, public as $$
  update flow.production_routes set tp_status = p_status
  where id in (select route_id from flow.tp_movement_items where movement_id = p_movement and route_id is not null)
$$;
