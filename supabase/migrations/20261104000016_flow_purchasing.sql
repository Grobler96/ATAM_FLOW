-- Purchasing core: suppliers, ATAM_FLOW purchase orders (alongside the DecoNetwork-synced ones), goods-in receipts,
-- supplier discrepancies, a reviewable communication log, and dashboard notifications.
-- ATAM_FLOW POs share flow.purchase_orders / flow.po_lines with the DecoNetwork mirror so the allocation engine, stock views and
-- shortage list see one picture of incoming stock. DecoNetwork rows have origin 'deconetwork'; ATAM_FLOW rows 'atam_flow'
-- (they carry a synthetic negative deco_po_id until/unless they are created in DecoNetwork).

create type flow.af_po_status as enum ('draft','approved','sent','acknowledged','partially_received','received','short_shipped','cancelled','closed');

create sequence flow.af_po_seq start 1001;
create sequence flow.goods_receipt_seq start 1;
create sequence flow.supplier_disc_seq start 1;
create sequence flow.comm_seq start 1;

create table flow.suppliers (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,
  name               text not null,
  deco_vendor_id     bigint unique,
  contact_name       text,
  email              text,
  phone              text,
  address            text,
  is_active          boolean not null default true,
  lead_time_days     numeric(4,1) not null default 3,
  min_order_value    numeric(10,2),
  delivery_cost      numeric(10,2) not null default 0,
  free_delivery_over numeric(10,2),
  payment_terms      text,
  currency           text not null default 'GBP',
  can_deliver_to_producer boolean not null default false,
  quality_rating     numeric(3,1),
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create table flow.supplier_offers (                       -- what each supplier can supply and at what cost (filled from feeds / by hand)
  id             uuid primary key default gen_random_uuid(),
  supplier_id    uuid not null references flow.suppliers(id) on delete cascade,
  sku            text not null,
  supplier_sku   text,
  unit_cost      numeric(12,4),
  min_qty        int not null default 1,
  stock_available int,
  lead_time_days numeric(4,1),
  updated_at     timestamptz not null default now(),
  unique (supplier_id, sku)
);
create index supplier_offers_sku on flow.supplier_offers (sku);

alter table flow.purchase_orders
  add column af_po_ref text unique,
  add column origin text not null default 'deconetwork' check (origin in ('deconetwork','atam_flow')),
  add column supplier_ref_id uuid references flow.suppliers(id),
  add column po_status flow.af_po_status,
  add column po_date date,
  add column required_by date,
  add column actual_delivery date,
  add column currency text not null default 'GBP',
  add column subtotal numeric(12,2),
  add column delivery_cost numeric(12,2),
  add column tax numeric(12,2),
  add column total_cost numeric(12,2),
  add column payment_status text not null default 'unpaid' check (payment_status in ('unpaid','part_paid','paid','credit')),
  add column invoice_ref text,
  add column supplier_ref text,
  add column created_by text,
  add column approved_by text,
  add column approved_at timestamptz,
  add column sent_at timestamptz,
  add column acknowledged_at timestamptz,
  add column notes text,
  add column deliver_to text not null default 'warehouse' check (deliver_to in ('warehouse','producer')),
  add column deliver_to_producer_id uuid references flow.producers(id);
create index purchase_orders_status on flow.purchase_orders (po_status) where origin = 'atam_flow';

alter table flow.po_lines
  add column unit_cost numeric(12,4),
  add column line_total numeric(12,2) generated always as (round(coalesce(unit_cost, 0) * qty_expected, 2)) stored,
  add column garment_type text,
  add column brand text,
  add column colour text,
  add column size text,
  add column supplier_sku text,
  add column expected_date date,
  add column received_date date,
  add column qty_received_af int not null default 0 check (qty_received_af >= 0),     -- good units booked in via ATAM_FLOW
  add column qty_damaged int not null default 0 check (qty_damaged >= 0),
  add column qty_incorrect int not null default 0 check (qty_incorrect >= 0),
  add column qty_short int not null default 0 check (qty_short >= 0),                -- declared short-shipped on a final delivery
  add column qty_replacement_due int not null default 0 check (qty_replacement_due >= 0),
  add column replacement_expected_date date,
  add column discrepancy_status text not null default 'none' check (discrepancy_status in ('none','short_shipped','damaged','incorrect','overage','resolved')),
  add column qty_outstanding_eff int generated always as (
    greatest(qty_expected - greatest(qty_received, qty_received_af) - qty_damaged - qty_incorrect - qty_short, 0) + qty_replacement_due) stored;

create table flow.po_line_sources (                       -- which customer order lines a PO line is buying stock for
  id            uuid primary key default gen_random_uuid(),
  po_line_id    uuid not null references flow.po_lines(id) on delete cascade,
  order_line_id uuid not null references flow.order_lines(id) on delete cascade,
  qty           int not null check (qty > 0),
  unique (po_line_id, order_line_id)
);
create index po_line_sources_line on flow.po_line_sources (order_line_id);

create table flow.stock_receipts (                        -- one goods-in event
  id             uuid primary key default gen_random_uuid(),
  receipt_code   text not null unique,
  po_id          uuid not null references flow.purchase_orders(id),
  supplier_id    uuid references flow.suppliers(id),
  delivery_ref   text,
  received_at    timestamptz not null default now(),
  received_by    text,
  location       text not null default 'warehouse' check (location in ('warehouse','producer')),
  producer_id    uuid references flow.producers(id),
  notes          text,
  evidence       jsonb not null default '[]'::jsonb,
  created_at     timestamptz not null default now()
);
create table flow.stock_receipt_lines (
  id             uuid primary key default gen_random_uuid(),
  receipt_id     uuid not null references flow.stock_receipts(id) on delete cascade,
  po_line_id     uuid not null references flow.po_lines(id),
  sku            text not null,
  colour         text,
  size           text,
  qty_expected   int not null,                           -- outstanding on the PO line before this delivery
  qty_received   int not null default 0,
  qty_damaged    int not null default 0,
  qty_incorrect  int not null default 0,
  qty_short      int not null default 0,
  qty_over       int not null default 0,
  condition      text not null default 'good' check (condition in ('good','damaged','incorrect','mixed')),
  is_final       boolean not null default true,          -- false = supplier will send the rest later (partial delivery)
  batch_ref      text,
  notes          text,
  evidence       jsonb not null default '[]'::jsonb
);
create index stock_receipt_lines_po_line on flow.stock_receipt_lines (po_line_id);

create table flow.communications (                        -- every outbound message, reviewable before and after sending
  id             uuid primary key default gen_random_uuid(),
  comm_ref       text not null unique,
  kind           text not null check (kind in ('po_send','shortage','damage','incorrect','overage','escalation','producer_job','other')),
  channel        text not null default 'email',
  to_addresses   text[] not null default '{}',
  cc_addresses   text[] not null default '{}',
  reply_to       text,
  subject        text not null,
  body_text      text not null,
  body_html      text,
  attachments    jsonb not null default '[]'::jsonb,
  status         text not null default 'pending_review' check (status in ('draft','pending_review','approved','sending','sent','failed','cancelled')),
  claimed_at     timestamptz,
  entity_type    text,
  entity_id      uuid,
  supplier_id    uuid references flow.suppliers(id),
  producer_id    uuid references flow.producers(id),
  requires_review boolean not null default true,
  created_by     text,
  edited_by      text,
  edited_at      timestamptz,
  approved_by    text,
  approved_at    timestamptz,
  sent_at        timestamptz,
  error          text,
  resend_of      uuid references flow.communications(id),
  provider_message_id text,
  created_at     timestamptz not null default now()
);
create index communications_queue on flow.communications (status) where status in ('pending_review','approved','failed','draft');

create table flow.supplier_discrepancies (
  id             uuid primary key default gen_random_uuid(),
  disc_ref       text not null unique,
  po_id          uuid not null references flow.purchase_orders(id),
  po_line_id     uuid not null references flow.po_lines(id),
  receipt_line_id uuid references flow.stock_receipt_lines(id),
  supplier_id    uuid references flow.suppliers(id),
  disc_type      text not null check (disc_type in ('shortage','damaged','incorrect','overage','late','other')),
  sku            text not null,
  colour         text,
  size           text,
  qty_ordered    int,
  qty_received   int,
  qty            int not null,                           -- units affected
  status         text not null default 'open' check (status in ('open','awaiting_supplier','resolved','cancelled','accepted')),
  requested_action text check (requested_action in ('replacement','credit','urgent_replacement','investigation')),
  required_by    date,
  resolution     text check (resolution in ('replacement_promised','replacement_received','credit_issued','cancelled','accepted','manual')),
  resolution_note text,
  affected_orders jsonb not null default '[]'::jsonb,    -- [{order_id, order_ref, due_date, qty}]
  evidence       jsonb not null default '[]'::jsonb,
  origin         text not null default 'goods_in' check (origin in ('goods_in','producer')),
  movement_id    uuid references flow.tp_movements(id),
  communication_id uuid references flow.communications(id),
  escalated_at   timestamptz,
  opened_by      text,
  opened_at      timestamptz not null default now(),
  resolved_by    text,
  resolved_at    timestamptz,
  updated_at     timestamptz not null default now()
);
create index supplier_disc_open on flow.supplier_discrepancies (supplier_id) where status in ('open','awaiting_supplier');
create index supplier_disc_po_line on flow.supplier_discrepancies (po_line_id);

create table flow.notifications (                         -- dashboard alerts; n8n pushes them to the chosen channel
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  kind         text not null,
  severity     text not null default 'info' check (severity in ('info','warning','critical')),
  title        text not null,
  body         text,
  entity_type  text,
  entity_id    uuid,
  pushed_at    timestamptz,
  read_at      timestamptz,
  read_by      text
);
create index notifications_unread on flow.notifications (created_at desc) where read_at is null;

create trigger suppliers_touch before update on flow.suppliers for each row execute function flow.touch_updated_at();
create trigger supplier_disc_touch before update on flow.supplier_discrepancies for each row execute function flow.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Effective stock: units booked in through ATAM_FLOW that DecoNetwork has not yet recorded count as on hand straight away.
-- pending = booked in here minus what DecoNetwork's own PO receipt figure shows (so it falls to zero once DecoNetwork catches up).
-- Goods delivered straight to a producer never enter warehouse stock.
-- ---------------------------------------------------------------------------
alter table flow.stock_items add column qty_pending_receipt int not null default 0;

create or replace function flow.refresh_pending_receipt(p_sku text) returns void
language plpgsql security definer set search_path = flow, public as $$
declare v_pending int;
begin
  select coalesce(sum(greatest(pl.qty_received_af - pl.qty_received, 0)), 0)::int into v_pending
    from flow.po_lines pl join flow.purchase_orders p on p.id = pl.po_id where pl.sku = p_sku and p.deliver_to = 'warehouse';
  insert into flow.stock_items (sku, qty_on_hand, is_placeholder, qty_pending_receipt) values (p_sku, 0, true, v_pending)
  on conflict (sku) do update set qty_pending_receipt = excluded.qty_pending_receipt
    where flow.stock_items.qty_pending_receipt is distinct from excluded.qty_pending_receipt;
end $$;
create or replace function flow.trg_po_line_pending() returns trigger language plpgsql security definer set search_path = flow, public as $$
begin
  perform flow.refresh_pending_receipt(new.sku);
  return new;
end $$;
create trigger po_lines_pending_ins after insert on flow.po_lines
  for each row when (new.qty_received_af > 0) execute function flow.trg_po_line_pending();
create trigger po_lines_pending_upd after update of qty_received, qty_received_af on flow.po_lines
  for each row when (old.qty_received_af is distinct from new.qty_received_af or old.qty_received is distinct from new.qty_received)
  execute function flow.trg_po_line_pending();

-- ---------------------------------------------------------------------------
-- Seed: suppliers from the vendors already on your purchase orders (fill in emails in Settings before sending POs)
-- ---------------------------------------------------------------------------
insert into flow.suppliers (code, name, deco_vendor_id)
select distinct on (p.supplier_id) left(upper(regexp_replace(p.supplier, '[^A-Za-z0-9]', '', 'g')), 8) || '-' || (p.supplier_id % 1000)::text, p.supplier, p.supplier_id
from flow.purchase_orders p
where p.supplier_id is not null and p.supplier is not null and exists (select 1 from flow.po_lines l where l.po_id = p.id)
on conflict do nothing;
update flow.purchase_orders p set supplier_ref_id = s.id from flow.suppliers s where s.deco_vendor_id = p.supplier_id and p.supplier_ref_id is null;

insert into flow.flow_settings (key, value, description) values
 ('purchasing.options', '{"po_prefix":"AF-PO","vat_rate":0.2,"default_currency":"GBP","dispatch_buffer_days":2,"over_delivery_tolerance_pct":0}'::jsonb,
  'PO numbering prefix, VAT rate, and how many days before an order is due a shortage must be resolved.'),
 ('comms.settings', '{"from_name":"ATAM FLOW Production Control","reply_to":null,"signature":"ATAM FLOW Production Control",
    "company_name":"ATAM","delivery_address":null,"phone":null,
    "review_required":{"po_send":true,"shortage":true,"damage":true,"incorrect":true,"overage":true,"escalation":true,"producer_job":true},
    "shortage_default_days":2,"escalate_after_required_by":true}'::jsonb,
  'Outbound email settings. review_required true = the message waits in the Communications queue until approved; set false for a kind to send it automatically.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- RLS + grants (read for members; writes only through the service-role functions)
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['suppliers','supplier_offers','po_line_sources','stock_receipts','stock_receipt_lines','communications','supplier_discrepancies','notifications'] loop
    execute format('alter table flow.%I enable row level security', t);
    execute format('create policy %I on flow.%I for select to authenticated using (flow.is_member())', t || '_read', t);
  end loop;
end $$;
create policy suppliers_cfg_write on flow.suppliers for all to authenticated using (flow.has_role('admin','manager')) with check (flow.has_role('admin','manager'));
create policy supplier_offers_cfg_write on flow.supplier_offers for all to authenticated using (flow.has_role('admin','manager')) with check (flow.has_role('admin','manager'));
grant select on all tables in schema flow to authenticated;
grant insert, update on flow.suppliers, flow.supplier_offers to authenticated;
grant all on all tables in schema flow to service_role;
grant usage, select on all sequences in schema flow to authenticated, service_role;
revoke all on function flow.refresh_pending_receipt(text), flow.trg_po_line_pending() from public, anon, authenticated;
grant execute on function flow.refresh_pending_receipt(text), flow.trg_po_line_pending() to service_role;
