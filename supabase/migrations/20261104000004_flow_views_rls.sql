-- Read models for the dashboard + row level security. Views run as the caller (security_invoker) so RLS applies.

-- Stock position: on hand vs reserved vs available vs incoming. Incoming is NEVER counted as available.
create or replace view flow.v_stock_position with (security_invoker = true) as
select s.id as stock_item_id, s.sku, s.product_name, s.garment_type, s.colour, s.size, s.storage_location,
       s.min_threshold, s.reorder_qty, s.is_placeholder,
       s.qty_on_hand,
       coalesce(r.reserved, 0)                                 as qty_reserved,
       greatest(s.qty_on_hand - coalesce(r.reserved, 0), 0)    as qty_available,
       coalesce(i.incoming, 0)                                 as qty_incoming,
       coalesce(i.incoming, 0) - coalesce(ri.reserved_incoming, 0) as qty_incoming_free,
       i.next_expected,
       (s.min_threshold is not null and s.qty_on_hand <= s.min_threshold)  as is_low_stock,
       (s.qty_on_hand <= 0)                                    as is_out_of_stock,
       s.last_synced_at
from flow.stock_items s
left join (select stock_item_id, sum(qty)::int as reserved from flow.allocations
           where status = 'active' and source = 'on_hand' group by 1) r on r.stock_item_id = s.id
left join (select l.sku, sum(l.qty_outstanding)::int as incoming, min(p.expected_date) as next_expected
           from flow.po_lines l join flow.purchase_orders p on p.id = l.po_id and p.is_active
           group by 1) i on i.sku = s.sku
left join (select stock_item_id, sum(qty)::int as reserved_incoming from flow.allocations
           where status = 'active' and source = 'incoming_po' group by 1) ri on ri.stock_item_id = s.id;

-- Per line: what is needed, what is covered, what is short.
create or replace view flow.v_order_line_alloc with (security_invoker = true) as
select ol.id as order_line_id, ol.order_id, ol.sku, ol.product_name, ol.colour, ol.size,
       ol.qty_required, ol.qty_produced,
       greatest(ol.qty_required - ol.qty_produced, 0)                       as qty_needed,
       coalesce(a.on_hand, 0)                                               as qty_allocated_on_hand,
       coalesce(a.incoming, 0)                                              as qty_allocated_incoming,
       greatest(greatest(ol.qty_required - ol.qty_produced, 0) - coalesce(a.on_hand, 0), 0) as qty_shortage
from flow.order_lines ol
left join (select order_line_id,
                  sum(qty) filter (where source = 'on_hand')::int     as on_hand,
                  sum(qty) filter (where source = 'incoming_po')::int as incoming
           from flow.allocations where status = 'active' group by 1) a on a.order_line_id = ol.id
where ol.is_active;

-- Orders with live computed flags (overdue etc. depend on now(), so they are never stored).
create or replace view flow.v_orders_live with (security_invoker = true) as
select o.*,
       (o.due_date is not null and o.due_date < date_trunc('day', now()) and o.order_status <> 'dispatched') as is_overdue,
       (o.due_date::date = (now() at time zone 'Europe/London')::date)                                     as is_due_today,
       case when o.due_date is null then null
            else (o.due_date::date - (now() at time zone 'Europe/London')::date) end                       as days_to_due,
       coalesce(t.needed, 0)    as units_needed,
       coalesce(t.allocated, 0) as units_allocated,
       coalesce(t.shortage, 0)  as units_short,
       case when coalesce(t.needed, 0) = 0 then 100
            else round(100.0 * least(t.allocated, t.needed) / t.needed) end as pct_allocated
from flow.orders o
left join (select order_id, sum(qty_needed) needed, sum(qty_allocated_on_hand) allocated, sum(qty_shortage) shortage
           from flow.v_order_line_alloc group by 1) t on t.order_id = o.id;

-- Bin utilisation and current occupants.
create or replace view flow.v_bins_live with (security_invoker = true) as
select b.id as bin_id, b.bin_code, z.code as zone_code, z.name as zone_name, b.location_type, b.status,
       b.capacity_units, coalesce(u.units, 0) as units_in_bin,
       b.capacity_units - coalesce(u.units, 0) as units_free,
       u.order_refs, b.qr_value, b.label_printed, b.is_active
from flow.bins b
left join flow.bin_zones z on z.id = b.zone_id
left join (select ba.bin_id, sum(ba.units)::int units, array_agg(o.order_ref order by o.order_ref) order_refs
           from flow.bin_assignments ba join flow.orders o on o.id = ba.order_id
           where ba.released_at is null group by 1) u on u.bin_id = b.id;

-- ---------------------------------------------------------------------------
-- RLS: members read; admins/managers edit configuration; operational writes go through n8n (service role).
-- ---------------------------------------------------------------------------
create or replace function flow.is_member() returns boolean language sql stable security definer
set search_path = flow, public as $$
  select exists (select 1 from flow.user_roles where user_id = auth.uid())
$$;
create or replace function flow.has_role(variadic p_roles flow.app_role[]) returns boolean language sql stable
security definer set search_path = flow, public as $$
  select exists (select 1 from flow.user_roles where user_id = auth.uid() and role = any (p_roles))
$$;

do $$
declare t text;
  config_tables text[] := array['flow_settings','deco_status_map','process_code_map','garment_type_rules',
    'production_methods','machines','machine_shifts','changeover_rules','bin_zones','bins'];
begin
  for t in select table_name from information_schema.tables
           where table_schema = 'flow' and table_type = 'BASE TABLE' loop
    execute format('alter table flow.%I enable row level security', t);
    execute format('create policy %I on flow.%I for select to authenticated using (flow.is_member())', t || '_read', t);
    if t = any (config_tables) then
      execute format($f$create policy %I on flow.%I for all to authenticated
                        using (flow.has_role('admin','manager')) with check (flow.has_role('admin','manager'))$f$,
                     t || '_cfg_write', t);
    end if;
  end loop;
end $$;

create policy user_roles_admin on flow.user_roles for all to authenticated
  using (flow.has_role('admin')) with check (flow.has_role('admin'));

-- Existing ATAM GO superusers become ATAM_FLOW admins (others get access via Settings > Users).
do $$
begin
  if to_regclass('public.profiles') is not null then
    insert into flow.user_roles (user_id, role)
    select id, 'admin' from public.profiles where is_superuser is true
    on conflict (user_id) do nothing;
  end if;
end $$;

-- Grants. Sync/engine functions are callable only with the service role (n8n), never from the browser.
grant usage on schema flow to authenticated, service_role;
grant select on all tables in schema flow to authenticated;
grant insert, update, delete on flow.flow_settings, flow.deco_status_map, flow.process_code_map,
  flow.garment_type_rules, flow.production_methods, flow.machines, flow.machine_shifts, flow.changeover_rules,
  flow.bin_zones, flow.bins, flow.user_roles to authenticated;   -- still gated by the RLS policies above
grant all on all tables in schema flow to service_role;
grant usage, select on all sequences in schema flow to authenticated, service_role;
revoke execute on all functions in schema flow from public;
grant execute on all functions in schema flow to service_role;
grant execute on function flow.is_member(), flow.has_role(flow.app_role[]) to authenticated;
alter default privileges in schema flow grant all on tables to service_role;
alter default privileges in schema flow grant select on tables to authenticated;
