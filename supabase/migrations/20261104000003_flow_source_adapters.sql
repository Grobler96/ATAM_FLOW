-- SOURCE ADAPTERS: map the existing, already-syncing `public` tables into the `flow` model.
-- These depend on tables owned by the ATAM GO / n8n DecoNetwork syncs. If ATAM_FLOW later reads DecoNetwork
-- directly, replace only this file; the rest of the schema is independent of it.
--
-- Ownership rules (so a re-sync never clobbers decisions made inside ATAM_FLOW):
--   source-owned (overwritten by sync): names, dates, DecoNetwork statuses, value, units, methods, qty required/produced
--   flow-owned   (never touched):       order_status after insert, priority, is_vip, notes, proof/artwork status,
--                                       alloc_state, label_status, risk_score, sequence_position, thresholds, storage

-- ---------- helpers ----------
create or replace function flow.map_processes(p_codes text[]) returns text[]
language sql stable as $$
  select coalesce(array_agg(distinct m.method_code order by m.method_code), '{}')
  from unnest(coalesce(p_codes, '{}')) c
  join flow.process_code_map m on m.code = upper(trim(c))
$$;

create or replace function flow.garment_type(p_name text) returns text
language sql stable as $$
  select garment_type from flow.garment_type_rules
  where p_name ~* pattern order by priority limit 1
$$;

-- Estimated minutes for a line. Embroidery uses stitch count and the existing public.job_settings
-- (stitches_per_minute, minutes_per_item); other methods use the per-unit default of each method.
create or replace function flow.est_minutes(p_qty int, p_methods text[], p_stitches int) returns numeric
language plpgsql stable as $$
declare v_spm numeric; v_mpi numeric; v_total numeric := 0; m text; v_pu numeric;
begin
  if to_regclass('public.job_settings') is not null then
    execute 'select stitches_per_minute, minutes_per_item from public.job_settings order by id limit 1'
      into v_spm, v_mpi;
  end if;
  foreach m in array coalesce(p_methods, '{}') loop
    if m = 'embroidery' and coalesce(v_spm, 0) > 0 and p_stitches is not null then
      v_total := v_total + p_qty * (p_stitches / v_spm + coalesce(v_mpi, 0));
    else
      select minutes_per_unit into v_pu from flow.production_methods where code = m;
      v_total := v_total + p_qty * coalesce(v_pu, 1);
    end if;
  end loop;
  return round(v_total, 1);
end $$;

-- ---------- source view: every upcoming order, with open/closed resolved ----------
create or replace view flow.v_src_orders with (security_invoker = true) as
select
  u.order_id,
  u.customer_id, u.customer_name, u.store_name,
  u.order_status, u.payment_status,
  u.date_ordered, u.date_due, u.date_scheduled, u.date_shipped, u.date_produced,
  u.shipping_method, u.assigned_to, u.customer_po_number,
  coalesce(u.total_quantity, 0) as total_quantity,
  u.billable_amount,
  flow.map_processes(u.processes) as methods,
  u.is_production_complete,
  u.synced_at,
  (coalesce(m.is_open, false) and u.date_shipped is null and u.dismissed_at is null) as is_active
from public.upcoming_orders u
left join flow.deco_status_map m on m.code = u.order_status;

-- ---------- sync_orders ----------
create or replace function flow.sync_orders(p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  v_run uuid; v_ins int := 0; v_upd int := 0; v_closed int := 0;
  v_l_ins int := 0; v_l_upd int := 0; v_l_off int := 0; v_unmapped text[];
begin
  if not pg_try_advisory_xact_lock(hashtext('flow.sync_orders')) then
    return jsonb_build_object('ok', true, 'skipped', 'another sync_orders run is in progress');
  end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('sync_orders', p_triggered_by) returning id into v_run;

  begin
    -- 1. upsert active orders (only source-owned columns; no-op rows are not rewritten)
    with up as (
      insert into flow.orders as o (
        deco_order_id, order_ref, customer_id, customer_name, store_name, order_date, due_date, scheduled_date,
        shipped_at, deco_status, deco_payment_status, order_value, total_units, decoration_methods,
        shipping_method, customer_po, assigned_to, order_status, source_synced_at, is_active)
      select s.order_id, '#' || s.order_id, s.customer_id, s.customer_name, s.store_name, s.date_ordered, s.date_due,
             s.date_scheduled, s.date_shipped, s.order_status, s.payment_status, s.billable_amount, s.total_quantity,
             s.methods, s.shipping_method, s.customer_po_number, s.assigned_to,
             case when s.is_production_complete then 'ready_for_dispatch'::flow.order_status
                  else 'awaiting_stock'::flow.order_status end,
             s.synced_at, true
      from flow.v_src_orders s where s.is_active
      on conflict (deco_order_id) do update set
        customer_id = excluded.customer_id, customer_name = excluded.customer_name, store_name = excluded.store_name,
        order_date = excluded.order_date, due_date = excluded.due_date, scheduled_date = excluded.scheduled_date,
        shipped_at = excluded.shipped_at, deco_status = excluded.deco_status,
        deco_payment_status = excluded.deco_payment_status, order_value = excluded.order_value,
        total_units = excluded.total_units, decoration_methods = excluded.decoration_methods,
        shipping_method = excluded.shipping_method, customer_po = excluded.customer_po,
        assigned_to = excluded.assigned_to, is_active = true, source_synced_at = excluded.source_synced_at
      where (o.customer_id, o.customer_name, o.store_name, o.order_date, o.due_date, o.scheduled_date, o.shipped_at,
             o.deco_status, o.deco_payment_status, o.order_value, o.total_units, o.decoration_methods,
             o.shipping_method, o.customer_po, o.assigned_to, o.is_active)
        is distinct from
            (excluded.customer_id, excluded.customer_name, excluded.store_name, excluded.order_date, excluded.due_date,
             excluded.scheduled_date, excluded.shipped_at, excluded.deco_status, excluded.deco_payment_status,
             excluded.order_value, excluded.total_units, excluded.decoration_methods, excluded.shipping_method,
             excluded.customer_po, excluded.assigned_to, true)
      returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from up;

    -- 2. close orders the source now says are finished/cancelled/dismissed (positive evidence only)
    with cl as (
      update flow.orders o set
        is_active = false,
        shipped_at = coalesce(s.date_shipped, o.shipped_at),
        order_status = case when s.date_shipped is not null then 'dispatched'::flow.order_status else o.order_status end
      from flow.v_src_orders s
      where s.order_id = o.deco_order_id and o.is_active and not s.is_active
      returning 1)
    select count(*) into v_closed from cl;

    -- 3. upsert lines for active orders (one row per DecoNetwork workflow item = per size)
    with src as (
      select l.workflow_item_id, o.id as order_id, l.line_id, l.sku, l.product_code, l.product_name,
             flow.garment_type(l.product_name) as garment_type, j.supplier, l.option_name as colour, l.size,
             greatest(l.qty_required, 0) as qty_required, coalesce(l.qty_produced, 0) as qty_produced,
             coalesce(l.qty_shipped, 0) as qty_shipped, flow.map_processes(j.processes) as methods,
             j.emb_areas, j.stitches_per_piece, l.production_status,
             case when coalesce(l.qty_produced, 0) >= l.qty_required and l.qty_required > 0 then 'complete'
                  else 'pending' end as pstatus
      from public.sales_order_lines l
      join flow.orders o on o.deco_order_id = l.order_id and o.is_active
      left join lateral (select * from public.job_lines jl
                         where jl.order_id = l.order_id and jl.line_id = l.line_id limit 1) j on true
      where l.workflow_item_id is not null
    ), up as (
      insert into flow.order_lines as ol (
        deco_workflow_item_id, order_id, deco_line_id, sku, product_code, product_name, garment_type, supplier,
        colour, size, qty_required, qty_produced, qty_shipped, decoration_methods, emb_areas, stitches_per_piece,
        deco_production_status, production_status, est_minutes, is_active)
      select workflow_item_id, order_id, line_id, nullif(sku,''), product_code, product_name, garment_type, supplier,
             colour, size, qty_required, qty_produced, qty_shipped, methods, emb_areas, stitches_per_piece,
             production_status, pstatus,
             flow.est_minutes(greatest(qty_required - qty_produced, 0), methods, stitches_per_piece), true
      from src
      on conflict (deco_workflow_item_id) do update set
        order_id = excluded.order_id, sku = excluded.sku, product_code = excluded.product_code,
        product_name = excluded.product_name, garment_type = excluded.garment_type, supplier = excluded.supplier,
        colour = excluded.colour, size = excluded.size, qty_required = excluded.qty_required,
        qty_produced = excluded.qty_produced, qty_shipped = excluded.qty_shipped,
        decoration_methods = excluded.decoration_methods, emb_areas = excluded.emb_areas,
        stitches_per_piece = excluded.stitches_per_piece, deco_production_status = excluded.deco_production_status,
        est_minutes = excluded.est_minutes, is_active = true,
        -- do not regress a status set inside ATAM_FLOW; only auto-complete
        production_status = case when excluded.production_status = 'complete' then 'complete'
                                 else ol.production_status end
      where (ol.sku, ol.colour, ol.size, ol.qty_required, ol.qty_produced, ol.qty_shipped, ol.decoration_methods,
             ol.stitches_per_piece, ol.deco_production_status, ol.order_id, ol.is_active)
        is distinct from
            (excluded.sku, excluded.colour, excluded.size, excluded.qty_required, excluded.qty_produced,
             excluded.qty_shipped, excluded.decoration_methods, excluded.stitches_per_piece,
             excluded.deco_production_status, excluded.order_id, true)
      returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_l_ins, v_l_upd from up;

    -- 4. deactivate lines that vanished from the source for orders that still have source lines
    with off as (
      update flow.order_lines ol set is_active = false
      where ol.is_active
        and exists (select 1 from flow.orders o where o.id = ol.order_id and o.is_active)
        and exists (select 1 from public.sales_order_lines x
                    join flow.orders o2 on o2.deco_order_id = x.order_id where o2.id = ol.order_id)
        and not exists (select 1 from public.sales_order_lines x where x.workflow_item_id = ol.deco_workflow_item_id)
      returning 1)
    select count(*) into v_l_off from off;

    -- process codes seen on active orders that have no mapping (so nothing is silently dropped)
    select coalesce(array_agg(distinct upper(trim(c))), '{}') into v_unmapped
    from public.upcoming_orders u, unnest(u.processes) c
    where u.date_shipped is null and u.dismissed_at is null
      and not exists (select 1 from flow.process_code_map m where m.code = upper(trim(c)));

    update flow.flow_runs set status = (case when cardinality(v_unmapped) > 0 then 'partial' else 'success' end)::flow.run_status,
      finished_at = now(),
      summary = jsonb_build_object('orders_inserted', v_ins, 'orders_updated', v_upd, 'orders_closed', v_closed,
        'lines_inserted', v_l_ins, 'lines_updated', v_l_upd, 'lines_deactivated', v_l_off,
        'unmapped_process_codes', to_jsonb(v_unmapped))
    where id = v_run;
    return jsonb_build_object('ok', true, 'run_id', v_run, 'orders_inserted', v_ins, 'orders_updated', v_upd,
      'orders_closed', v_closed, 'lines_inserted', v_l_ins, 'lines_updated', v_l_upd, 'lines_deactivated', v_l_off,
      'unmapped_process_codes', to_jsonb(v_unmapped));
  exception when others then
    update flow.flow_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'error', sqlerrm);
  end;
end $$;

-- ---------- sync_stock ----------
create or replace function flow.sync_stock(p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_run uuid; v_ins int := 0; v_upd int := 0; v_ph int := 0; v_low int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('flow.sync_stock')) then
    return jsonb_build_object('ok', true, 'skipped', 'another sync_stock run is in progress');
  end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('sync_stock', p_triggered_by) returning id into v_run;

  begin
    with up as (
      insert into flow.stock_items as s (sku, product_name, garment_type, colour, size, qty_on_hand, is_placeholder, last_synced_at)
      select i.sku, i.product_name, flow.garment_type(i.product_name), i.color, i.size,
             coalesce(i.qty_on_hand, 0), false, now()
      from public.sku_inventory i where i.sku is not null and i.sku <> ''
      on conflict (sku) do update set
        product_name = coalesce(excluded.product_name, s.product_name),
        garment_type = coalesce(excluded.garment_type, s.garment_type),
        colour = coalesce(excluded.colour, s.colour), size = coalesce(excluded.size, s.size),
        qty_on_hand = excluded.qty_on_hand, is_placeholder = false
      where (s.qty_on_hand, s.is_placeholder, s.product_name, s.colour, s.size)
        is distinct from (excluded.qty_on_hand, false, coalesce(excluded.product_name, s.product_name),
                          coalesce(excluded.colour, s.colour), coalesce(excluded.size, s.size))
      returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from up;

    -- SKUs demanded by open order lines but unknown to inventory: zero-qty placeholders so shortages are visible
    with ph as (
      insert into flow.stock_items (sku, product_name, garment_type, colour, size, qty_on_hand, is_placeholder, last_synced_at)
      select distinct on (ol.sku) ol.sku, ol.product_name, ol.garment_type, ol.colour, ol.size, 0, true, now()
      from flow.order_lines ol where ol.is_active and ol.sku is not null
      on conflict (sku) do nothing returning 1)
    select count(*) into v_ph from ph;

    update flow.stock_items set last_synced_at = now() where last_synced_at is distinct from now() and not is_placeholder;

    select count(*) into v_low from flow.stock_items
      where min_threshold is not null and qty_on_hand <= min_threshold;

    update flow.flow_runs set status = 'success', finished_at = now(),
      summary = jsonb_build_object('stock_inserted', v_ins, 'stock_updated', v_upd, 'placeholders_created', v_ph,
                                   'below_min_threshold', v_low)
    where id = v_run;
    return jsonb_build_object('ok', true, 'run_id', v_run, 'stock_inserted', v_ins, 'stock_updated', v_upd,
      'placeholders_created', v_ph, 'below_min_threshold', v_low);
  exception when others then
    update flow.flow_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'error', sqlerrm);
  end;
end $$;

-- ---------- sync_purchase_orders ----------
create or replace function flow.po_delivery_status(p_status int) returns flow.delivery_status
language sql immutable as $$
  select case p_status when 1 then 'draft' when 2 then 'expected' when 3 then 'expected'
                       when 4 then 'partially_received' when 5 then 'received'
                       when 7 then 'cancelled' when 8 then 'cancelled' else 'draft' end::flow.delivery_status
$$;

create or replace function flow.sync_purchase_orders(p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_run uuid; v_ins int := 0; v_upd int := 0; v_l_ins int := 0; v_l_upd int := 0; v_received int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('flow.sync_purchase_orders')) then
    return jsonb_build_object('ok', true, 'skipped', 'another sync_purchase_orders run is in progress');
  end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('sync_purchase_orders', p_triggered_by) returning id into v_run;

  begin
    with src as (
      select p.*, flow.po_delivery_status(p.status) as ds from public.purchase_orders p
      where p.date_raised > now() - interval '60 days'
         or exists (select 1 from flow.purchase_orders f where f.deco_po_id = p.id)
    ), up as (
      insert into flow.purchase_orders as f (
        deco_po_id, po_number, supplier, supplier_id, deco_status, delivery_status, date_raised, expected_date,
        received_date, qty_expected, qty_received, receipt_status, is_active)
      select id, po_number, vendor, vendor_id, status, ds, date_raised, date_delivery, date_received,
             qty_ordered, qty_received,
             case when coalesce(qty_received,0) = 0 then 'none'
                  when coalesce(qty_received,0) >= coalesce(qty_ordered,0) then 'complete' else 'partial' end,
             ds in ('expected','partially_received')
      from src
      on conflict (deco_po_id) do update set
        po_number = excluded.po_number, supplier = excluded.supplier, deco_status = excluded.deco_status,
        delivery_status = excluded.delivery_status, expected_date = excluded.expected_date,
        received_date = excluded.received_date, qty_expected = excluded.qty_expected,
        qty_received = excluded.qty_received, receipt_status = excluded.receipt_status,
        is_active = excluded.is_active
      where (f.po_number, f.supplier, f.deco_status, f.delivery_status, f.expected_date, f.received_date,
             f.qty_expected, f.qty_received, f.receipt_status, f.is_active)
        is distinct from
            (excluded.po_number, excluded.supplier, excluded.deco_status, excluded.delivery_status,
             excluded.expected_date, excluded.received_date, excluded.qty_expected, excluded.qty_received,
             excluded.receipt_status, excluded.is_active)
      returning (xmax = 0) as inserted, delivery_status)
    select count(*) filter (where inserted), count(*) filter (where not inserted),
           count(*) filter (where delivery_status = 'received')
      into v_ins, v_upd, v_received from up;

    -- lines: garment lines only (decoration/service lines have an empty SKU and are not stock)
    with src as (
      select f.id as po_id, x.ord::int as line_no, x.line->>'sku' as sku, x.line->>'product_name' as product_name,
             coalesce((x.line->>'qty_ordered')::numeric, 0)::int as qe,
             coalesce((x.line->>'qty_received')::numeric, 0)::int as qr
      from public.purchase_orders p
      join flow.purchase_orders f on f.deco_po_id = p.id
      cross join lateral jsonb_array_elements(coalesce(p.lines, '[]'::jsonb)) with ordinality as x(line, ord)
      where coalesce(x.line->>'sku', '') <> ''
    ), up as (
      insert into flow.po_lines as l (po_id, line_no, sku, product_name, qty_expected, qty_received)
      select po_id, line_no, sku, product_name, qe, qr from src
      on conflict (po_id, line_no) do update set
        sku = excluded.sku, product_name = excluded.product_name,
        qty_expected = excluded.qty_expected, qty_received = excluded.qty_received
      where (l.sku, l.product_name, l.qty_expected, l.qty_received)
        is distinct from (excluded.sku, excluded.product_name, excluded.qty_expected, excluded.qty_received)
      returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_l_ins, v_l_upd from up;

    update flow.flow_runs set status = 'success', finished_at = now(),
      summary = jsonb_build_object('pos_inserted', v_ins, 'pos_updated', v_upd, 'pos_received', v_received,
                                   'lines_inserted', v_l_ins, 'lines_updated', v_l_upd)
    where id = v_run;
    return jsonb_build_object('ok', true, 'run_id', v_run, 'pos_inserted', v_ins, 'pos_updated', v_upd,
      'lines_inserted', v_l_ins, 'lines_updated', v_l_upd,
      'stock_received_changes', v_received > 0 or v_l_upd > 0);   -- n8n uses this to trigger allocation
  exception when others then
    update flow.flow_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'error', sqlerrm);
  end;
end $$;
