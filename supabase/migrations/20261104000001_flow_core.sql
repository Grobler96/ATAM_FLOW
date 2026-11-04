-- ATAM_FLOW core schema (additive only: creates the `flow` schema; touches nothing in `public`).
-- Source of truth for production control, stock allocation, scheduling, bins and labels.

create schema if not exists flow;

-- ---------------------------------------------------------------------------
-- Enums (status language is fixed by the business; see docs/data-model.md)
-- ---------------------------------------------------------------------------
create type flow.order_status as enum (
  'awaiting_stock','stock_allocated','ready_for_production','in_production',
  'quality_check','ready_for_dispatch','dispatched','blocked','on_hold');
create type flow.alloc_state    as enum ('none','partial','full');
create type flow.alloc_source   as enum ('on_hand','incoming_po');
create type flow.alloc_status   as enum ('active','released','consumed');
create type flow.delivery_status as enum ('draft','expected','partially_received','received','cancelled');
create type flow.location_type  as enum ('bin_bay','box','bucket','shelf','pallet','cage','staging','receiving');
create type flow.bin_status     as enum ('available','allocated','full','reserved','needs_emptying');
create type flow.batch_status   as enum ('queued','ready','in_progress','paused','complete','blocked');
create type flow.label_type     as enum ('order','bin','stock','pick','dispatch');
create type flow.print_status   as enum ('pending','printed','failed');
create type flow.run_status     as enum ('running','success','partial','failed','skipped');
create type flow.app_role       as enum ('admin','manager','production','warehouse','viewer');

create or replace function flow.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ---------------------------------------------------------------------------
-- Control plane: settings, runs, snapshots, audit, roles
-- ---------------------------------------------------------------------------
create table flow.flow_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  updated_by  text,
  updated_at  timestamptz not null default now()
);

create table flow.flow_runs (
  id          uuid primary key default gen_random_uuid(),
  workflow    text not null,
  status      flow.run_status not null default 'running',
  triggered_by text,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  summary     jsonb not null default '{}'::jsonb,
  error       text
);
create index flow_runs_workflow_started on flow.flow_runs (workflow, started_at desc);

create table flow.sync_snapshots (            -- raw / normalised API payloads kept for debugging
  id           uuid primary key default gen_random_uuid(),
  source       text not null,                 -- e.g. 'deconetwork.order'
  entity_id    text not null,
  content_hash text not null,
  payload      jsonb not null,
  captured_at  timestamptz not null default now(),
  unique (source, entity_id, content_hash)    -- same payload twice = one row (idempotent)
);

create table flow.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      text,
  action     text not null,
  entity     text not null,
  entity_id  text,
  before     jsonb,
  after      jsonb,
  reason     text,
  run_id     uuid references flow.flow_runs(id)
);
create index audit_log_entity on flow.audit_log (entity, entity_id, at desc);

create table flow.user_roles (
  user_id    uuid primary key,                -- = auth.users.id (same ids as public.profiles)
  role       flow.app_role not null default 'viewer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Lookup / mapping tables (editable from the Settings page)
create table flow.deco_status_map (
  code        int primary key,                -- DecoNetwork numeric order_status
  label       text not null,
  is_open     boolean not null,               -- open = still needs work in ATAM_FLOW
  is_assumed  boolean not null default true,  -- true until a human confirms it
  notes       text
);
create table flow.process_code_map (
  code        text primary key,               -- DecoNetwork process code, upper-case (WEMB, DTF...)
  method_code text not null
);
create table flow.garment_type_rules (
  id          int generated always as identity primary key,
  priority    int not null,
  pattern     text not null,                  -- case-insensitive regex on product name
  garment_type text not null
);

-- ---------------------------------------------------------------------------
-- Production configuration (methods, machines, shifts, changeovers)
-- ---------------------------------------------------------------------------
create table flow.production_methods (
  code            text primary key,
  name            text not null,
  setup_minutes   numeric(6,1) not null default 0,
  minutes_per_unit numeric(6,2) not null default 1,
  sort_order      int not null default 100,
  is_active       boolean not null default true
);
create table flow.machines (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  method_code text not null references flow.production_methods(code),
  units_per_hour numeric(8,2),
  is_active   boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table flow.machine_shifts (            -- machine_id null = default for all machines
  id         uuid primary key default gen_random_uuid(),
  machine_id uuid references flow.machines(id) on delete cascade,
  weekday    smallint not null check (weekday between 1 and 7),   -- ISO: 1=Mon
  start_time time not null,
  end_time   time not null,
  check (end_time > start_time)
);
create table flow.changeover_rules (
  id          uuid primary key default gen_random_uuid(),
  method_code text not null references flow.production_methods(code),
  change_type text not null check (change_type in
              ('garment_colour','thread_colour','ink_colour','design','garment_type','size_run')),
  minutes     numeric(6,1) not null check (minutes >= 0),
  unique (method_code, change_type)
);

-- ---------------------------------------------------------------------------
-- Orders and lines
-- ---------------------------------------------------------------------------
create table flow.orders (
  id              uuid primary key default gen_random_uuid(),
  deco_order_id   text not null unique,
  order_ref       text,
  customer_id     text,
  customer_name   text,
  store_name      text,
  order_date      timestamptz,
  due_date        timestamptz,                -- promised dispatch date (assumption: = DecoNetwork date_due)
  scheduled_date  timestamptz,
  shipped_at      timestamptz,                -- actual dispatch
  deco_status     int,
  deco_payment_status int,
  order_status    flow.order_status not null default 'awaiting_stock',   -- OWNED by ATAM_FLOW after insert
  status_reason   text,
  production_stage text,
  proof_status    text,
  artwork_status  text,
  priority        smallint not null default 0 check (priority between 0 and 3), -- 0 normal 1 high 2 rush 3 critical
  priority_note   text,
  is_vip          boolean not null default false,
  order_value     numeric(12,2),
  total_units     int not null default 0,
  decoration_methods text[] not null default '{}',
  shipping_method text,
  customer_po     text,
  assigned_to     text,
  production_notes text,
  alloc_state     flow.alloc_state not null default 'none',
  label_status    text not null default 'none' check (label_status in ('none','pending','printed','reprint_needed')),
  risk_score      numeric(6,2),
  sequence_position int,
  is_active       boolean not null default true,
  source_synced_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index orders_active_due on flow.orders (is_active, due_date);
create index orders_status on flow.orders (order_status) where is_active;

create table flow.order_lines (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references flow.orders(id) on delete cascade,
  deco_workflow_item_id text not null unique,   -- one row per size within a product line
  deco_line_id    text,
  sku             text,
  product_code    text,
  product_name    text,
  garment_type    text,
  brand           text,
  supplier        text,
  colour          text,
  size            text,
  qty_required    int not null default 0,
  qty_produced    int not null default 0,
  qty_shipped     int not null default 0,
  decoration_methods text[] not null default '{}',
  decoration_placement text,
  artwork_ref     text,
  decoration_spec jsonb not null default '{}'::jsonb,  -- thread/vinyl/DTF/print data (enrichment workflow)
  emb_areas       int,
  stitches_per_piece int,
  deco_production_status int,
  production_status text not null default 'pending'
                  check (production_status in ('pending','ready','in_progress','complete','blocked')),
  machine_id      uuid references flow.machines(id),
  est_minutes     numeric(8,1),
  dependencies    jsonb not null default '[]'::jsonb,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index order_lines_order on flow.order_lines (order_id);
create index order_lines_sku on flow.order_lines (sku) where is_active;

-- ---------------------------------------------------------------------------
-- Stock, movements, inbound
-- ---------------------------------------------------------------------------
create table flow.stock_items (
  id              uuid primary key default gen_random_uuid(),
  sku             text not null unique,
  product_name    text,
  garment_type    text,
  brand           text,
  colour          text,
  size            text,
  deco_sku_id     text,
  qty_on_hand     int not null default 0,       -- as reported by DecoNetwork; reservations are NOT netted off here
  supplier        text,
  storage_location text,
  min_threshold   int,
  reorder_qty     int,
  is_placeholder  boolean not null default false, -- SKU seen on an order but absent from inventory
  last_synced_at  timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table flow.stock_movements (             -- append-only ledger
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  stock_item_id uuid not null references flow.stock_items(id),
  movement_type text not null check (movement_type in
                ('sync_adjust','received','allocated','released','consumed','manual_adjust')),
  qty           int not null,
  ref_type      text,
  ref_id        text,
  run_id        uuid references flow.flow_runs(id),
  note          text
);
create index stock_movements_item on flow.stock_movements (stock_item_id, at desc);
create or replace function flow.block_ledger_mutation() returns trigger language plpgsql as $$
begin raise exception 'flow.stock_movements is append-only'; end $$;
create trigger stock_movements_immutable before update or delete on flow.stock_movements
  for each row execute function flow.block_ledger_mutation();

-- log every change of DecoNetwork on-hand as a ledger entry
create or replace function flow.log_on_hand_change() returns trigger language plpgsql as $$
begin
  if new.qty_on_hand is distinct from old.qty_on_hand then
    insert into flow.stock_movements (stock_item_id, movement_type, qty, ref_type, note)
    values (new.id, 'sync_adjust', new.qty_on_hand - old.qty_on_hand, 'sync',
            format('on hand %s -> %s', old.qty_on_hand, new.qty_on_hand));
  end if;
  return new;
end $$;
create trigger stock_items_on_hand_log after update of qty_on_hand on flow.stock_items
  for each row execute function flow.log_on_hand_change();

create table flow.purchase_orders (
  id              uuid primary key default gen_random_uuid(),
  deco_po_id      bigint not null unique,
  po_number       text,
  supplier        text,
  supplier_id     bigint,
  deco_status     int,
  delivery_status flow.delivery_status not null default 'draft',
  date_raised     timestamptz,
  expected_date   timestamptz,
  received_date   timestamptz,
  qty_expected    int,
  qty_received    int,
  receipt_status  text not null default 'none' check (receipt_status in ('none','partial','complete')),
  storage_destination text,
  is_active       boolean not null default false,  -- true while goods are still inbound
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index purchase_orders_active on flow.purchase_orders (is_active, expected_date);

create table flow.po_lines (
  id            uuid primary key default gen_random_uuid(),
  po_id         uuid not null references flow.purchase_orders(id) on delete cascade,
  line_no       int not null,                      -- position in the DecoNetwork PO (no native line id)
  sku           text not null,
  product_name  text,
  qty_expected  int not null default 0,
  qty_received  int not null default 0,
  qty_outstanding int generated always as (greatest(qty_expected - qty_received, 0)) stored,
  updated_at    timestamptz not null default now(),
  unique (po_id, line_no)
);
create index po_lines_sku on flow.po_lines (sku);

-- ---------------------------------------------------------------------------
-- Allocation (reservations + decision audit)
-- ---------------------------------------------------------------------------
create table flow.allocations (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references flow.orders(id) on delete cascade,
  order_line_id uuid not null references flow.order_lines(id) on delete cascade,
  stock_item_id uuid not null references flow.stock_items(id),
  source        flow.alloc_source not null default 'on_hand',
  po_line_id    uuid references flow.po_lines(id),
  qty           int not null check (qty > 0),
  status        flow.alloc_status not null default 'active',
  is_manual     boolean not null default false,
  reason        text,
  score         numeric(8,2),
  score_breakdown jsonb,
  run_id        uuid references flow.flow_runs(id),
  created_by    text,
  created_at    timestamptz not null default now(),
  released_at   timestamptz,
  updated_at    timestamptz not null default now(),
  check ((source = 'incoming_po') = (po_line_id is not null))
);
-- one active allocation per (line, stock, source, po line): re-running the engine upserts, never duplicates
create unique index allocations_one_active on flow.allocations
  (order_line_id, stock_item_id, source, (coalesce(po_line_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  where status = 'active';
create index allocations_stock_active on flow.allocations (stock_item_id) where status = 'active';
create index allocations_order on flow.allocations (order_id);

-- Hard guarantee against double-allocating physical stock, enforced in the database.
create or replace function flow.guard_allocation() returns trigger language plpgsql as $$
declare v_cap int; v_used int;
begin
  if new.status <> 'active' then return new; end if;
  if new.source = 'on_hand' then
    select greatest(qty_on_hand, 0) into v_cap from flow.stock_items where id = new.stock_item_id for update;
    select coalesce(sum(qty), 0) into v_used from flow.allocations
      where stock_item_id = new.stock_item_id and source = 'on_hand' and status = 'active' and id <> new.id;
    if v_used + new.qty > v_cap then
      raise exception 'over-allocation: stock % has % on hand, % already reserved, % requested',
        new.stock_item_id, v_cap, v_used, new.qty using errcode = 'check_violation';
    end if;
  else
    select qty_outstanding into v_cap from flow.po_lines where id = new.po_line_id for update;
    select coalesce(sum(qty), 0) into v_used from flow.allocations
      where po_line_id = new.po_line_id and status = 'active' and id <> new.id;
    if v_used + new.qty > coalesce(v_cap, 0) then
      raise exception 'over-allocation: PO line % has % outstanding, % already reserved, % requested',
        new.po_line_id, v_cap, v_used, new.qty using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger allocations_guard before insert or update of qty, status, source on flow.allocations
  for each row execute function flow.guard_allocation();

create table flow.allocation_decisions (        -- "why" for every automated decision
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid references flow.flow_runs(id),
  order_id      uuid not null references flow.orders(id) on delete cascade,
  order_line_id uuid references flow.order_lines(id) on delete cascade,
  decision      text not null check (decision in ('allocate','partial','hold','blocked','release')),
  reason        text not null,
  score         numeric(8,2),
  score_breakdown jsonb,
  qty_required  int,
  qty_allocated int,
  created_at    timestamptz not null default now()
);
create index allocation_decisions_order on flow.allocation_decisions (order_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Warehouse: zones, bins, assignments, contents
-- ---------------------------------------------------------------------------
create table flow.bin_zones (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  description text,
  sort_order  int not null default 100,
  is_active   boolean not null default true
);
create table flow.bins (
  id            uuid primary key default gen_random_uuid(),
  bin_code      text not null unique,
  zone_id       uuid references flow.bin_zones(id),
  location_type flow.location_type not null default 'bin_bay',
  capacity_units int,
  status        flow.bin_status not null default 'available',
  qr_value      text,
  label_printed boolean not null default false,
  notes         text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index bins_status on flow.bins (status) where is_active;

create table flow.bin_assignments (
  id          uuid primary key default gen_random_uuid(),
  bin_id      uuid not null references flow.bins(id),
  order_id    uuid not null references flow.orders(id) on delete cascade,
  units       int not null default 0,
  assigned_at timestamptz not null default now(),
  assigned_by text,
  released_at timestamptz,
  run_id      uuid references flow.flow_runs(id)
);
create unique index bin_assignments_one_active on flow.bin_assignments (bin_id, order_id) where released_at is null;

create table flow.bin_contents (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references flow.bin_assignments(id) on delete cascade,
  order_line_id uuid references flow.order_lines(id),
  stock_item_id uuid references flow.stock_items(id),
  qty           int not null check (qty > 0),
  placed_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Production batches / jobs
-- ---------------------------------------------------------------------------
create table flow.batches (
  id            uuid primary key default gen_random_uuid(),
  batch_code    text not null unique,
  method_code   text not null references flow.production_methods(code),
  machine_id    uuid references flow.machines(id),
  status        flow.batch_status not null default 'queued',
  total_units   int not null default 0,
  garment_types text[] not null default '{}',
  colours       text[] not null default '{}',
  colour_groups jsonb not null default '{}'::jsonb,   -- thread / ink / design groups
  est_setup_min numeric(8,1),
  est_run_min   numeric(8,1),
  priority_score numeric(8,2),
  scheduled_start timestamptz,
  scheduled_end   timestamptz,
  actual_start    timestamptz,
  actual_end      timestamptz,
  is_bottleneck boolean not null default false,
  sequence_position int,
  sequence_reason text,
  score_breakdown jsonb,
  manual_override jsonb,                                -- user override; system recommendation kept alongside
  blocked_reason text,
  depends_on    uuid[] not null default '{}',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index batches_status_seq on flow.batches (status, sequence_position);

create table flow.batch_orders (
  batch_id uuid not null references flow.batches(id) on delete cascade,
  order_id uuid not null references flow.orders(id) on delete cascade,
  units    int not null default 0,
  primary key (batch_id, order_id)
);

create table flow.job_steps (                           -- ordered stages for multi-process orders
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references flow.orders(id) on delete cascade,
  method_code   text not null references flow.production_methods(code),
  step_no       int not null,
  depends_on_step uuid references flow.job_steps(id),
  status        text not null default 'pending'
                check (status in ('pending','ready','in_progress','complete','blocked')),
  batch_id      uuid references flow.batches(id) on delete set null,
  updated_at    timestamptz not null default now(),
  unique (order_id, method_code)
);

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------
create table flow.labels (
  id           uuid primary key default gen_random_uuid(),
  label_code   text not null unique,
  label_type   flow.label_type not null,
  order_id     uuid references flow.orders(id) on delete cascade,
  bin_id       uuid references flow.bins(id),
  payload      jsonb not null default '{}'::jsonb,      -- all fields printed on the label
  qr_payload   text,
  html         text,                                    -- optional pre-rendered print output
  print_status flow.print_status not null default 'pending',
  print_count  int not null default 0,
  printed_by   text,
  printed_at   timestamptz,
  version      int not null default 1,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index labels_one_per_target on flow.labels
  (label_type, (coalesce(order_id, '00000000-0000-0000-0000-000000000000'::uuid)),
               (coalesce(bin_id,   '00000000-0000-0000-0000-000000000000'::uuid)));

create table flow.label_prints (                        -- reprint history
  id         uuid primary key default gen_random_uuid(),
  label_id   uuid not null references flow.labels(id) on delete cascade,
  printed_by text,
  printed_at timestamptz not null default now(),
  reason     text
);

-- ---------------------------------------------------------------------------
-- updated_at triggers on every table that has the column
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select c.table_name from information_schema.columns c
           join information_schema.tables tb on tb.table_schema=c.table_schema and tb.table_name=c.table_name
           where c.table_schema='flow' and c.column_name='updated_at' and tb.table_type='BASE TABLE'
  loop
    execute format('create trigger %I before update on flow.%I for each row execute function flow.touch_updated_at()',
                   t || '_touch', t);
  end loop;
end $$;
