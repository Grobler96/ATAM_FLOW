-- LOCAL TEST ONLY. Stands in for the Supabase roles/auth and the existing `public` source tables
-- (column names/types copied from the live N8N_Daniel_Spooner project, read-only inspection).
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth, public to authenticated, service_role;
grant execute on function auth.uid() to authenticated, service_role;

create table public.profiles (id uuid primary key, full_name text, email text, is_superuser boolean, allowed_customer_ids text[]);
create table public.upcoming_orders (
  id uuid primary key default gen_random_uuid(), order_id text unique, customer_id text, customer_name text, store_name text,
  order_status int, date_due timestamptz, date_scheduled timestamptz, date_modified timestamptz, date_produced timestamptz,
  date_shipped timestamptz, date_ordered timestamptz, shipping_method text, assigned_to text, total_quantity int,
  processes text[], products text[], is_production_complete boolean, synced_at timestamptz, payment_status int,
  outstanding_balance numeric, customer_po_number text, shipping_amount numeric, shipping_address text,
  dismissed_at timestamptz, dismissed_reason text, extra_lines jsonb, tax_amount numeric, billable_amount numeric, ship_country text);
create table public.sales_order_lines (
  id bigint generated always as identity primary key, order_id text, line_id text, workflow_item_id text unique,
  product_name text, product_code text, sku text, option_name text, qty_required int, qty_produced int, qty_shipped int,
  qty_invoiced int, unit_price numeric, shipping_status int, production_status int, shipped_date timestamptz,
  synced_at timestamptz, size text, line_total numeric, line_qty int);
create table public.job_lines (
  id bigint generated always as identity primary key, order_id text, line_id text, product_code text, product_name text,
  supplier text, colour text, qty int, line_total numeric, unit_price numeric, discount numeric, garment_cost_unit numeric,
  garment_cost_total numeric, decoration_unit_price numeric, processes text[], emb_areas int, other_areas int,
  stitches_per_piece int, synced_at timestamptz);
create table public.job_settings (id int primary key, minutes_per_item numeric, stitches_per_minute numeric, cost_per_hour numeric);
create table public.sku_inventory (sku text primary key, product_name text, color text, size text, qty_on_hand int, updated_at timestamptz);
create table public.purchase_orders (
  id bigint primary key, po_number text, vendor text, vendor_id bigint, status int, status_description text,
  date_raised timestamptz, date_delivery timestamptz, date_received timestamptz, qty_ordered int, qty_received int,
  sub_total numeric, tax numeric, total numeric, lines jsonb, synced_at timestamptz);
create table public.product_type_rules (id int generated always as identity primary key, priority int, pattern text, product_type text);

create table public.sku_costs (sku text primary key, product_name text, unit_cost numeric, last_cost_date timestamptz, updated_at timestamptz);
insert into public.sku_costs values ('POLO-BLK-M','Polo',4.5,now(),now()),('POLO-WHT-M','Polo',4.2,now(),now());
