-- 22 Nov 2026: buying stock, step 1: supplier cards with shipping options. (written and tested locally; NOT applied to the live project)
-- Stock is going to be bought from Flow itself instead of from DecoNetwork. First every supplier needs a proper card: who they are, how we order from them
-- (email today; API or EDI later for Ralawise and ORN), what they charge for delivery, and what the delivery options are.
--   * flow.suppliers gets: order method (email / api / edi / portal / phone / other), notes on how to order, account number, website. The API or EDI
--     credentials are NEVER kept in Flow: they go in n8n's credentials. The notes only say where to find them.
--   * flow.supplier_shipping_options: any number of options per supplier (for example Standard, Next day, Pallet), each with a cost, a "free over" amount,
--     a lead time and a cut-off time. One is the default. Options are switched off, never removed.
--   * The default option keeps the older single delivery fields on the supplier (delivery_cost, free_delivery_over) in step, so nothing that already reads
--     them changes.
--   * Managers and admins add and change suppliers and options from the dashboard (database functions that check the role themselves, like the catalogue).
-- Nothing is sent and no purchase order changes.

alter table flow.suppliers
  add column order_method        text not null default 'email' check (order_method in ('email', 'api', 'edi', 'portal', 'phone', 'other')),
  add column order_method_notes  text,
  add column account_number      text,
  add column website             text;

create table flow.supplier_shipping_options (
  id             uuid primary key default gen_random_uuid(),
  supplier_id    uuid not null references flow.suppliers(id),
  name           text not null,
  cost           numeric(10,2) not null default 0 check (cost >= 0),
  free_over      numeric(10,2) check (free_over is null or free_over >= 0),
  lead_time_days numeric(4,1) check (lead_time_days is null or lead_time_days >= 0),
  cut_off_time   time,
  is_default     boolean not null default false,
  is_active      boolean not null default true,
  notes          text,
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_by     text,
  updated_at     timestamptz not null default now()
);
create unique index supplier_shipping_one_default on flow.supplier_shipping_options (supplier_id) where is_default and is_active;
create index supplier_shipping_supplier on flow.supplier_shipping_options (supplier_id);
alter table flow.supplier_shipping_options enable row level security;
create policy supplier_shipping_read on flow.supplier_shipping_options for select to authenticated using (flow.is_member());

-- 1. Keep the older single delivery fields in step with the default option -------------------------------------------------------------------------
create or replace function flow.supplier_sync_shipping(p_supplier uuid) returns void language plpgsql security definer set search_path = flow, public as $$
declare o flow.supplier_shipping_options;
begin
  select * into o from flow.supplier_shipping_options where supplier_id = p_supplier and is_default and is_active;
  if found then update flow.suppliers set delivery_cost = o.cost, free_delivery_over = o.free_over, updated_at = now() where id = p_supplier;
  else update flow.suppliers set delivery_cost = 0, free_delivery_over = null, updated_at = now() where id = p_supplier; end if;
end $$;

-- 2. Add or change a supplier ------------------------------------------------------------------------------------------------------------------------
-- p_f holds only the fields to set. Text is trimmed and an empty text clears the field. A new supplier needs a name; its code is made from the name.
create or replace function flow.supplier_save(p_id uuid, p_f jsonb, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare s flow.suppliers; v_name text; v_email text; v_method text; v_num numeric; v_code text; v_new boolean := p_id is null;
begin
  if p_f is null or jsonb_typeof(p_f) <> 'object' then return jsonb_build_object('ok', false, 'error', 'Nothing to save.'); end if;
  if v_new then
    v_name := btrim(coalesce(p_f->>'name', ''));
    if v_name = '' then return jsonb_build_object('ok', false, 'error', 'Give the supplier a name.'); end if;
    if exists (select 1 from flow.suppliers where lower(name) = lower(v_name)) then return jsonb_build_object('ok', false, 'error', 'There is already a supplier called "' || v_name || '".'); end if;
    v_code := upper(left(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g'), 10));
    if v_code = '' then v_code := 'SUPPLIER'; end if;
    loop v_code := regexp_replace(v_code, '-[0-9a-f]{4}$', '') || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 4); exit when not exists (select 1 from flow.suppliers where code = v_code); end loop;
    insert into flow.suppliers (code, name) values (v_code, v_name) returning * into s;
  else
    select * into s from flow.suppliers where id = p_id for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'That supplier does not exist.'); end if;
  end if;
  if p_f ? 'name' and not v_new then
    v_name := btrim(coalesce(p_f->>'name', ''));
    if v_name = '' then return jsonb_build_object('ok', false, 'error', 'A supplier needs a name.'); end if;
    if exists (select 1 from flow.suppliers where lower(name) = lower(v_name) and id <> s.id) then return jsonb_build_object('ok', false, 'error', 'There is already a supplier called "' || v_name || '".'); end if;
    update flow.suppliers set name = v_name where id = s.id;
  end if;
  if p_f ? 'email' then
    v_email := nullif(btrim(coalesce(p_f->>'email', '')), '');
    if v_email is not null and v_email !~ '^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$' then return jsonb_build_object('ok', false, 'error', '"' || v_email || '" is not an email address.'); end if;
    update flow.suppliers set email = lower(v_email) where id = s.id;
  end if;
  if p_f ? 'order_method' then
    v_method := btrim(coalesce(p_f->>'order_method', ''));
    if v_method not in ('email', 'api', 'edi', 'portal', 'phone', 'other') then return jsonb_build_object('ok', false, 'error', 'Choose how orders are placed: email, API, EDI, portal, phone or other.'); end if;
    update flow.suppliers set order_method = v_method where id = s.id;
  end if;
  if p_f ? 'lead_time_days' then
    begin v_num := nullif(btrim(coalesce(p_f->>'lead_time_days', '')), '')::numeric; exception when others then return jsonb_build_object('ok', false, 'error', 'The lead time has to be a number of days.'); end;
    if v_num is null or v_num < 0 or v_num > 99 then return jsonb_build_object('ok', false, 'error', 'The lead time has to be between 0 and 99 days.'); end if;
    update flow.suppliers set lead_time_days = v_num where id = s.id;
  end if;
  if p_f ? 'min_order_value' then
    begin v_num := nullif(btrim(coalesce(p_f->>'min_order_value', '')), '')::numeric; exception when others then return jsonb_build_object('ok', false, 'error', 'The minimum order has to be an amount.'); end;
    if v_num is not null and v_num < 0 then return jsonb_build_object('ok', false, 'error', 'The minimum order cannot be negative.'); end if;
    update flow.suppliers set min_order_value = v_num where id = s.id;
  end if;
  if p_f ? 'contact_name' then update flow.suppliers set contact_name = nullif(btrim(coalesce(p_f->>'contact_name', '')), '') where id = s.id; end if;
  if p_f ? 'phone' then update flow.suppliers set phone = nullif(btrim(coalesce(p_f->>'phone', '')), '') where id = s.id; end if;
  if p_f ? 'address' then update flow.suppliers set address = nullif(btrim(coalesce(p_f->>'address', '')), '') where id = s.id; end if;
  if p_f ? 'website' then update flow.suppliers set website = nullif(btrim(coalesce(p_f->>'website', '')), '') where id = s.id; end if;
  if p_f ? 'account_number' then update flow.suppliers set account_number = nullif(btrim(coalesce(p_f->>'account_number', '')), '') where id = s.id; end if;
  if p_f ? 'payment_terms' then update flow.suppliers set payment_terms = nullif(btrim(coalesce(p_f->>'payment_terms', '')), '') where id = s.id; end if;
  if p_f ? 'order_method_notes' then update flow.suppliers set order_method_notes = nullif(btrim(coalesce(p_f->>'order_method_notes', '')), '') where id = s.id; end if;
  if p_f ? 'notes' then update flow.suppliers set notes = nullif(btrim(coalesce(p_f->>'notes', '')), '') where id = s.id; end if;
  if p_f ? 'can_deliver_to_producer' then update flow.suppliers set can_deliver_to_producer = coalesce((p_f->>'can_deliver_to_producer')::boolean, false) where id = s.id; end if;
  if p_f ? 'is_active' then update flow.suppliers set is_active = coalesce((p_f->>'is_active')::boolean, true) where id = s.id; end if;
  update flow.suppliers set updated_at = now() where id = s.id;
  select * into s from flow.suppliers where id = s.id;
  perform flow.wh_audit(p_actor, case when v_new then 'supplier_created' else 'supplier_saved' end, 'supplier', s.code, null, p_f - 'notes', null);
  return jsonb_build_object('ok', true, 'id', s.id, 'code', s.code, 'created', v_new);
end $$;

-- 3. Shipping options ---------------------------------------------------------------------------------------------------------------------------------
create or replace function flow.supplier_shipping_save(p_supplier uuid, p_option uuid, p_f jsonb, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare s flow.suppliers; o flow.supplier_shipping_options; v_name text; v_cost numeric; v_free numeric; v_lead numeric; v_cut time; v_def boolean; v_act boolean; v_new boolean := p_option is null;
begin
  select * into s from flow.suppliers where id = p_supplier;
  if not found then return jsonb_build_object('ok', false, 'error', 'That supplier does not exist.'); end if;
  if p_f is null or jsonb_typeof(p_f) <> 'object' then return jsonb_build_object('ok', false, 'error', 'Nothing to save.'); end if;
  if not v_new then
    select * into o from flow.supplier_shipping_options where id = p_option and supplier_id = p_supplier for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'That shipping option does not exist.'); end if;
  end if;
  v_name := btrim(coalesce(p_f->>'name', case when v_new then '' else o.name end));
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'Give the shipping option a name, for example Standard or Next day.'); end if;
  if exists (select 1 from flow.supplier_shipping_options x where x.supplier_id = p_supplier and x.is_active and lower(x.name) = lower(v_name) and (v_new or x.id <> p_option)) then return jsonb_build_object('ok', false, 'error', 'This supplier already has an option called "' || v_name || '".'); end if;
  begin
    v_cost := coalesce(nullif(btrim(coalesce(p_f->>'cost', case when v_new then '0' else o.cost::text end)), '')::numeric, 0);
    v_free := case when p_f ? 'free_over' then nullif(btrim(coalesce(p_f->>'free_over', '')), '')::numeric else o.free_over end;
    v_lead := case when p_f ? 'lead_time_days' then nullif(btrim(coalesce(p_f->>'lead_time_days', '')), '')::numeric else o.lead_time_days end;
    v_cut  := case when p_f ? 'cut_off_time' then nullif(btrim(coalesce(p_f->>'cut_off_time', '')), '')::time else o.cut_off_time end;
  exception when others then return jsonb_build_object('ok', false, 'error', 'Check the cost, free-over amount, lead time and cut-off time: they have to be numbers and a time like 14:30.'); end;
  if v_cost < 0 or coalesce(v_free, 0) < 0 or coalesce(v_lead, 0) < 0 then return jsonb_build_object('ok', false, 'error', 'Costs and days cannot be negative.'); end if;
  v_def := coalesce((p_f->>'is_default')::boolean, case when v_new then false else o.is_default end);
  v_act := coalesce((p_f->>'is_active')::boolean, case when v_new then true else o.is_active end);
  -- switching the current default off (without asking for it to stay the default) simply makes it a non-default option
  if not v_act and not v_new and o.is_default and not coalesce((p_f->>'is_default')::boolean, false) then v_def := false; end if;
  if v_def and not v_act then return jsonb_build_object('ok', false, 'error', 'The default option has to be switched on.'); end if;
  -- the first option a supplier gets is its default
  if v_act and not exists (select 1 from flow.supplier_shipping_options x where x.supplier_id = p_supplier and x.is_active and x.is_default and (v_new or x.id <> p_option)) and not v_def then v_def := true; end if;
  if v_def then update flow.supplier_shipping_options set is_default = false where supplier_id = p_supplier and is_default and (v_new or id <> p_option); end if;
  if v_new then
    insert into flow.supplier_shipping_options (supplier_id, name, cost, free_over, lead_time_days, cut_off_time, is_default, is_active, notes, created_by, updated_by)
      values (p_supplier, v_name, v_cost, v_free, v_lead, v_cut, v_def, v_act, nullif(btrim(coalesce(p_f->>'notes', '')), ''), p_actor, p_actor) returning * into o;
  else
    update flow.supplier_shipping_options set name = v_name, cost = v_cost, free_over = v_free, lead_time_days = v_lead, cut_off_time = v_cut, is_default = v_def, is_active = v_act,
           notes = case when p_f ? 'notes' then nullif(btrim(coalesce(p_f->>'notes', '')), '') else notes end, updated_by = p_actor, updated_at = now() where id = p_option returning * into o;
    -- switching the default option off promotes the cheapest other one
    if not o.is_active and not exists (select 1 from flow.supplier_shipping_options x where x.supplier_id = p_supplier and x.is_active and x.is_default) then
      update flow.supplier_shipping_options set is_default = true where id = (select id from flow.supplier_shipping_options where supplier_id = p_supplier and is_active order by cost, name limit 1);
    end if;
  end if;
  perform flow.supplier_sync_shipping(p_supplier);
  perform flow.wh_audit(p_actor, case when v_new then 'supplier_shipping_added' else 'supplier_shipping_saved' end, 'supplier', s.code, null, jsonb_build_object('option', v_name, 'cost', v_cost, 'free_over', v_free, 'default', v_def, 'active', v_act), null);
  return jsonb_build_object('ok', true, 'id', o.id, 'is_default', (select is_default from flow.supplier_shipping_options where id = o.id));
end $$;

-- 4. What the dashboard calls (the role is checked inside) and what it reads ------------------------------------------------------------------------
create or replace function public.supplier_save(p_id uuid, p_f jsonb) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can change suppliers.'); end if;
  return flow.supplier_save(p_id, p_f, flow.catalogue_actor());
end $$;
create or replace function public.supplier_shipping_save(p_supplier uuid, p_option uuid, p_f jsonb) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can change suppliers.'); end if;
  return flow.supplier_shipping_save(p_supplier, p_option, p_f, flow.catalogue_actor());
end $$;

create or replace view public.ui_supplier_cards with (security_invoker = true) as
  select s.id, s.code, s.name, s.contact_name, s.email, s.phone, s.address, s.website, s.account_number, s.payment_terms, s.lead_time_days, s.min_order_value, s.currency,
         s.order_method, s.order_method_notes, s.notes, s.can_deliver_to_producer, s.is_active, s.updated_at,
         (select count(*)::int from flow.supplier_offers o where o.supplier_id = s.id) as catalogue_items
  from flow.suppliers s;
create or replace view public.ui_supplier_shipping with (security_invoker = true) as
  select x.id, x.supplier_id, x.name, x.cost, x.free_over, x.lead_time_days, to_char(x.cut_off_time, 'HH24:MI') as cut_off_time, x.is_default, x.is_active, x.notes, x.updated_at
  from flow.supplier_shipping_options x;

do $$
declare f text;
begin
  revoke all on flow.supplier_shipping_options from public, anon, authenticated;
  grant select on flow.supplier_shipping_options to authenticated;
  foreach f in array array['flow.supplier_sync_shipping(uuid)', 'flow.supplier_save(uuid,jsonb,text)', 'flow.supplier_shipping_save(uuid,uuid,jsonb,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['public.supplier_save(uuid,jsonb)', 'public.supplier_shipping_save(uuid,uuid,jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  revoke all on public.ui_supplier_cards, public.ui_supplier_shipping from public, anon;
  grant select on public.ui_supplier_cards, public.ui_supplier_shipping to authenticated;
end $$;
