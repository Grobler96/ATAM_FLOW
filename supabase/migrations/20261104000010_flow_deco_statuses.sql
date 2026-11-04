-- Real DecoNetwork order-status meanings (confirmed by the business, 4 Nov 2026) replace the earlier assumptions.
-- DecoNetwork removes stock when an order is placed if the item is in stock, so orders at status 1/2 already have their
-- garments secured; only 8/9 (awaiting PO / awaiting stock) need allocation. 7 = on hold, 10 = awaiting artwork.

alter table flow.deco_status_map
  add column maps_to flow.order_status,
  add column blocks_production boolean not null default false,
  add column block_reason text,
  add column stock_secured boolean not null default false,
  add column artwork_status text;
alter table flow.orders add column stock_secured boolean not null default false;

insert into flow.deco_status_map (code, label, is_open, is_assumed, notes, maps_to, blocks_production, block_reason, stock_secured, artwork_status) values
  (1,  'Ready for production',     true,  false, 'Stock already taken by DecoNetwork.',      'ready_for_production', false, null, true,  null),
  (2,  'Ready for shipping',       true,  false, 'Production complete.',                      'ready_for_dispatch',   false, null, true,  null),
  (3,  'Shipped',                  false, false, null,                                        'dispatched',           false, null, true,  null),
  (4,  'Cancelled',                false, false, null,                                        null,                   false, null, false, null),
  (6,  'Removed in DecoNetwork',   false, false, 'Order removed from DecoNetwork.',           null,                   false, null, false, null),
  (7,  'On hold',                  true,  false, 'Held in DecoNetwork.',                      'on_hold',              true,  'order is on hold in DecoNetwork', false, null),
  (8,  'Awaiting purchase order',  true,  false, 'Needs allocation / a PO to arrive.',        'awaiting_stock',       true,  'awaiting purchase order (DecoNetwork status)', false, null),
  (9,  'Awaiting stock',           true,  false, 'Needs allocation / stock to arrive.',       'awaiting_stock',       true,  'awaiting stock (DecoNetwork status)', false, null),
  (10, 'Awaiting artwork',         true,  false, 'Cannot be produced until artwork is in.',   'blocked',              true,  'awaiting artwork (DecoNetwork status)', false, 'awaiting')
on conflict (code) do update set
  label = excluded.label, is_open = excluded.is_open, is_assumed = excluded.is_assumed, notes = excluded.notes,
  maps_to = excluded.maps_to, blocks_production = excluded.blocks_production, block_reason = excluded.block_reason,
  stock_secured = excluded.stock_secured, artwork_status = excluded.artwork_status;

-- One-off backfill for orders already synced under the old assumptions (only touches pre-production states).
update flow.orders o set
  order_status  = m.maps_to,
  stock_secured = m.stock_secured,
  artwork_status = case when m.artwork_status is not null then m.artwork_status else o.artwork_status end
from flow.deco_status_map m
where m.code = o.deco_status and m.maps_to is not null and o.is_active
  and o.order_status in ('awaiting_stock','stock_allocated','ready_for_production','on_hold','blocked','ready_for_dispatch');

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
  (coalesce(m.is_open, false) and u.date_shipped is null and u.dismissed_at is null) as is_active,
  m.maps_to, coalesce(m.stock_secured, false) as stock_secured, m.artwork_status as map_artwork_status
from public.upcoming_orders u
left join flow.deco_status_map m on m.code = u.order_status;

-- sync_orders: DecoNetwork status now drives order_status / stock_secured / artwork_status while an order is still pre-production.
-- It only changes order_status when the DecoNetwork status itself CHANGES, so a manual hold or later ATAM_FLOW stage is never overwritten.
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
    with up as (
      insert into flow.orders as o (
        deco_order_id, order_ref, customer_id, customer_name, store_name, order_date, due_date, scheduled_date,
        shipped_at, deco_status, deco_payment_status, order_value, total_units, decoration_methods,
        shipping_method, customer_po, assigned_to, order_status, stock_secured, artwork_status, source_synced_at, is_active)
      select s.order_id, '#' || s.order_id, s.customer_id, s.customer_name, s.store_name, s.date_ordered, s.date_due,
             s.date_scheduled, s.date_shipped, s.order_status, s.payment_status, s.billable_amount, s.total_quantity,
             s.methods, s.shipping_method, s.customer_po_number, s.assigned_to,
             case when s.is_production_complete and s.order_status = 1 then 'ready_for_dispatch'::flow.order_status
                  else coalesce(s.maps_to, 'awaiting_stock'::flow.order_status) end,
             s.stock_secured, s.map_artwork_status, s.synced_at, true
      from flow.v_src_orders s where s.is_active
      on conflict (deco_order_id) do update set
        customer_id = excluded.customer_id, customer_name = excluded.customer_name, store_name = excluded.store_name,
        order_date = excluded.order_date, due_date = excluded.due_date, scheduled_date = excluded.scheduled_date,
        shipped_at = excluded.shipped_at, deco_status = excluded.deco_status,
        deco_payment_status = excluded.deco_payment_status, order_value = excluded.order_value,
        total_units = excluded.total_units, decoration_methods = excluded.decoration_methods,
        shipping_method = excluded.shipping_method, customer_po = excluded.customer_po,
        assigned_to = excluded.assigned_to, is_active = true, source_synced_at = excluded.source_synced_at,
        stock_secured = excluded.stock_secured,
        artwork_status = case when excluded.artwork_status is not null then excluded.artwork_status
                              when o.artwork_status = 'awaiting' then null else o.artwork_status end,
        order_status = case when o.deco_status is distinct from excluded.deco_status
                             and (o.order_status in ('awaiting_stock','stock_allocated','ready_for_production','on_hold','blocked','ready_for_dispatch')
                                  or excluded.deco_status = 2)
                            then excluded.order_status else o.order_status end
      where (o.customer_id, o.customer_name, o.store_name, o.order_date, o.due_date, o.scheduled_date, o.shipped_at,
             o.deco_status, o.deco_payment_status, o.order_value, o.total_units, o.decoration_methods,
             o.shipping_method, o.customer_po, o.assigned_to, o.is_active, o.stock_secured, (o.artwork_status = 'awaiting'))
        is distinct from
            (excluded.customer_id, excluded.customer_name, excluded.store_name, excluded.order_date, excluded.due_date,
             excluded.scheduled_date, excluded.shipped_at, excluded.deco_status, excluded.deco_payment_status,
             excluded.order_value, excluded.total_units, excluded.decoration_methods, excluded.shipping_method,
             excluded.customer_po, excluded.assigned_to, true, excluded.stock_secured, (excluded.artwork_status = 'awaiting'))
      returning (xmax = 0) as inserted)
    select count(*) filter (where inserted), count(*) filter (where not inserted) into v_ins, v_upd from up;

    with cl as (
      update flow.orders o set
        is_active = false,
        shipped_at = coalesce(s.date_shipped, o.shipped_at),
        order_status = case when s.date_shipped is not null then 'dispatched'::flow.order_status else o.order_status end
      from flow.v_src_orders s
      where s.order_id = o.deco_order_id and o.is_active and not s.is_active
      returning 1)
    select count(*) into v_closed from cl;

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

    with off as (
      update flow.order_lines ol set is_active = false
      where ol.is_active
        and exists (select 1 from flow.orders o where o.id = ol.order_id and o.is_active)
        and exists (select 1 from public.sales_order_lines x
                    join flow.orders o2 on o2.deco_order_id = x.order_id where o2.id = ol.order_id)
        and not exists (select 1 from public.sales_order_lines x where x.workflow_item_id = ol.deco_workflow_item_id)
      returning 1)
    select count(*) into v_l_off from off;

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
