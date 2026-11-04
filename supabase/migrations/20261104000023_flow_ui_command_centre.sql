-- Read models for the main internal UI (command centre). Everything is a security_invoker view in the public schema (the signed-in person's own access applies),
-- or a function that checks flow.is_member() itself. Nothing here writes data; actions go through n8n.

create or replace view public.ui_orders with (security_invoker = true) as select * from flow.v_orders_live where is_active;
create or replace view public.ui_order_lines with (security_invoker = true) as
  select l.id, l.order_id, l.sku, l.product_name, l.garment_type, l.brand, l.colour, l.size, l.qty_required, l.qty_produced, l.qty_shipped, l.decoration_methods, l.decoration_placement,
         l.stitches_per_piece, l.emb_areas, l.deco_line_id, l.production_status::text as production_status,
         coalesce(a.qty_allocated_on_hand, 0) as qty_allocated_on_hand, coalesce(a.qty_allocated_incoming, 0) as qty_allocated_incoming, coalesce(a.qty_shortage, 0) as qty_shortage
  from flow.order_lines l left join flow.v_order_line_alloc a on a.order_line_id = l.id where l.is_active;
create or replace view public.ui_allocation with (security_invoker = true) as select * from flow.v_allocation_board;
create or replace view public.ui_allocation_decisions with (security_invoker = true) as
  select distinct on (d.order_id) d.order_id, d.decision, d.reason, d.score, d.score_breakdown, d.qty_required, d.qty_allocated, d.created_at
  from flow.allocation_decisions d where d.order_line_id is null order by d.order_id, d.created_at desc;
create or replace view public.ui_production_queue with (security_invoker = true) as select * from flow.v_production_queue;
create or replace view public.ui_machines with (security_invoker = true) as
  select m.id, m.code, m.name, m.method_code, m.units_per_hour, m.is_active, m.notes,
         count(js.id) filter (where js.status in ('pending','ready'))::int as queued_jobs, count(js.id) filter (where js.status = 'in_progress')::int as in_progress_jobs,
         coalesce(sum(js.units) filter (where js.status in ('pending','ready','in_progress')), 0)::int as queued_units,
         coalesce(sum(js.est_minutes + coalesce(js.setup_minutes, 0)) filter (where js.status in ('pending','ready','in_progress')), 0)::numeric as queued_minutes,
         max(js.planned_end) filter (where js.status in ('pending','ready','in_progress')) as busy_until,
         count(js.id) filter (where js.is_late and js.status <> 'complete')::int as late_jobs
  from flow.machines m left join flow.job_steps js on js.machine_id = m.id group by m.id;
create or replace view public.ui_stock with (security_invoker = true) as select * from flow.v_stock_position;
create or replace view public.ui_shortages with (security_invoker = true) as select * from flow.v_shortages;
create or replace view public.ui_purchase_orders with (security_invoker = true) as select * from flow.v_purchase_orders_live;
create or replace view public.ui_po_lines with (security_invoker = true) as
  select l.id, l.po_id, l.line_no, l.sku, l.product_name, l.colour, l.size, l.qty_expected, greatest(l.qty_received, l.qty_received_af) as qty_received, l.qty_outstanding_eff as qty_outstanding,
         l.qty_short, l.qty_damaged, l.qty_incorrect, l.qty_replacement_due, l.unit_cost, l.line_total, l.expected_date, l.received_date, l.discrepancy_status
  from flow.po_lines l;
create or replace view public.ui_overdue_pos with (security_invoker = true) as select * from flow.v_overdue_pos;
create or replace view public.ui_supplier_discrepancies with (security_invoker = true) as select * from flow.v_supplier_discrepancies_open;
create or replace view public.ui_suppliers with (security_invoker = true) as
  select id, code, name, email, phone, contact_name, lead_time_days, delivery_cost, free_delivery_over, min_order_value, payment_terms, can_deliver_to_producer, quality_rating, on_time_rate, is_active from flow.suppliers;
create or replace view public.ui_selection with (security_invoker = true) as select * from flow.v_selection_latest;
create or replace view public.ui_producers with (security_invoker = true) as
  select p.id, p.code, p.name, p.contact_name, p.email, p.phone, p.address, p.is_active, p.capable_methods, p.preferred_methods, p.daily_capacity_units, p.weekly_capacity_units, p.turnaround_days,
         p.can_direct_dispatch, p.quality_notes, p.special_instructions, p.cost_out, p.cost_back,
         coalesce(s.open_jobs, 0) as open_jobs, coalesce(s.units_in_transit, 0) as units_in_transit, coalesce(s.units_held, 0) as units_held, coalesce(s.value_held, 0) as value_held,
         s.on_time_rate, s.avg_turnaround_days, coalesce(s.late_returns, 0) as late_returns, s.discrepancy_rate, s.return_accuracy, coalesce(s.orders_blocked, 0) as orders_blocked
  from flow.producers p left join flow.producer_stats s on s.producer_id = p.id;
create or replace view public.ui_tp_movements with (security_invoker = true) as select * from flow.v_tp_movements_live;
create or replace view public.ui_tp_orders with (security_invoker = true) as select * from flow.v_tp_orders;
create or replace view public.ui_tp_discrepancies with (security_invoker = true) as select * from flow.v_tp_open_discrepancies;
create or replace view public.ui_producer_held_stock with (security_invoker = true) as select * from flow.v_producer_held_stock;
create or replace view public.ui_custody with (security_invoker = true) as select * from flow.v_custody_summary;
create or replace view public.ui_unit_trace with (security_invoker = true) as select * from flow.v_unit_trace;
create or replace view public.ui_bins with (security_invoker = true) as select * from flow.v_bins_live;
create or replace view public.ui_artwork_status with (security_invoker = true) as select * from flow.v_artwork_status;
create or replace view public.ui_artwork_versions with (security_invoker = true) as select * from flow.v_artwork_versions;
create or replace view public.ui_job_packs with (security_invoker = true) as select * from flow.v_job_packs;
create or replace view public.ui_communications with (security_invoker = true) as select * from flow.v_communications_queue;
create or replace view public.ui_labels with (security_invoker = true) as
  select l.id, l.label_code, l.label_type, l.order_id, o.order_ref, l.bin_id, b.bin_code, l.print_status, l.print_count, l.printed_by, l.printed_at, l.version, l.created_at, l.qr_payload
  from flow.labels l left join flow.orders o on o.id = l.order_id left join flow.bins b on b.id = l.bin_id;
create or replace view public.ui_settings with (security_invoker = true) as select key, value, description, updated_at from flow.flow_settings;

-- Global search across everything a person might type into the command palette.
create or replace function public.ui_search(p_q text) returns table (kind text, id text, label text, sub text, route text)
language sql stable security definer set search_path = flow, public as $$
  with q as (select '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pat, length(btrim(p_q)) as n)
  select * from (
    select 'order', o.order_ref, o.order_ref, coalesce(o.customer_name, '') || ' · due ' || coalesce(to_char(o.due_date, 'DD Mon'), 'no date'), '/orders/' || o.order_ref
      from flow.orders o, q where o.is_active and (o.order_ref ilike q.pat or o.customer_name ilike q.pat or o.customer_po ilike q.pat) order by o.due_date nulls last limit 8
  ) a where flow.is_member() and (select n from (select length(btrim(p_q)) n) z) >= 2
  union all select * from (
    select 'stock', s.sku, s.sku, coalesce(s.product_name, '') || ' ' || coalesce(s.colour, '') || ' ' || coalesce(s.size, ''), '/stock/' || s.sku
      from flow.stock_items s, q where s.sku ilike q.pat or s.product_name ilike q.pat order by s.sku limit 8
  ) b where flow.is_member() and length(btrim(p_q)) >= 2
  union all select * from (
    select 'po', p.id::text, coalesce(p.af_po_ref, p.po_number), coalesce(p.supplier, '') || ' · ' || coalesce(p.po_status::text, p.delivery_status::text), '/purchasing/' || p.id
      from flow.purchase_orders p, q where p.po_number ilike q.pat or p.af_po_ref ilike q.pat or p.supplier ilike q.pat order by p.date_raised desc nulls last limit 6
  ) c where flow.is_member() and length(btrim(p_q)) >= 2
  union all select * from (
    select 'producer', pr.id::text, pr.name, 'Producer · ' || pr.code, '/producers/' || pr.id from flow.producers pr, q where pr.name ilike q.pat or pr.code ilike q.pat limit 5
  ) d where flow.is_member() and length(btrim(p_q)) >= 2
  union all select * from (
    select 'bin', b.bin_code, b.bin_code, 'Bin · ' || b.status::text, '/warehouse/' || b.bin_code from flow.bins b, q where b.bin_code ilike q.pat limit 5
  ) e where flow.is_member() and length(btrim(p_q)) >= 2
  union all select * from (
    select 'movement', m.id::text, m.movement_code, 'Producer movement · ' || m.status::text, '/producers/movement/' || m.movement_code from flow.tp_movements m, q where m.movement_code ilike q.pat limit 5
  ) f where flow.is_member() and length(btrim(p_q)) >= 2
  union all select * from (
    select 'exception', e.exc_ref, e.exc_ref, left(e.description, 90), '/exceptions/' || e.exc_ref from flow.exceptions e, q where e.exc_ref ilike q.pat or e.description ilike q.pat order by e.detected_at desc limit 5
  ) g where flow.is_member() and length(btrim(p_q)) >= 2
  union all select * from (
    select 'label', l.label_code, l.label_code, 'Label · ' || l.label_type, '/labels' from flow.labels l, q where l.label_code ilike q.pat limit 5
  ) h where flow.is_member() and length(btrim(p_q)) >= 2
$$;

-- Live operational feed (newest first).
create or replace function public.ui_activity(p_limit int default 40) returns table (at timestamptz, kind text, title text, detail text, actor text, route text)
language sql stable security definer set search_path = flow, public as $$
  select * from (
    select a.at, 'audit'::text, replace(a.action, '_', ' '), coalesce(a.reason, a.entity || ' ' || coalesce(a.entity_id, '')), a.actor, null::text from flow.audit_log a
    union all select r.started_at, 'sync', replace(r.workflow, '_', ' ') || ' ' || r.status::text, left(coalesce(r.error, r.summary::text), 160), r.triggered_by, null from flow.flow_runs r
    union all select x.at, 'exception', replace(x.action, '_', ' ') || ' · ' || e.exc_ref, left(coalesce(x.note, e.description), 160), x.actor, '/exceptions/' || e.exc_ref
      from flow.exception_actions x join flow.exceptions e on e.id = x.exception_id where x.action in ('detected','resolved','auto_resolved','escalated','reopened','written_off')
    union all select sr.received_at, 'receipt', 'stock received · ' || sr.receipt_code, 'against ' || coalesce(p.af_po_ref, p.po_number), sr.received_by, '/purchasing/' || p.id
      from flow.stock_receipts sr join flow.purchase_orders p on p.id = sr.po_id
    union all select m.created_at, 'movement', 'producer movement ' || m.movement_code, m.status::text, m.created_by, '/producers/movement/' || m.movement_code from flow.tp_movements m
  ) t where flow.is_member() order by 1 desc limit least(greatest(p_limit, 1), 200)
$$;

-- Everything that has happened to one order: audit entries, allocation decisions, exception activity and every custody move of its garments.
create or replace function public.ui_order_history(p_order uuid) returns table (at timestamptz, kind text, title text, detail text, actor text)
language sql stable security definer set search_path = flow, public as $$
  select * from (
    select a.at, 'audit'::text, replace(a.action, '_', ' '), coalesce(a.reason, ''), a.actor from flow.audit_log a where a.entity = 'order' and a.entity_id = p_order::text
    union all select d.created_at, 'allocation', 'allocation: ' || d.decision, d.reason, 'allocation engine' from flow.allocation_decisions d where d.order_id = p_order and d.order_line_id is null
    union all select x.at, 'exception', replace(x.action, '_', ' ') || ' · ' || e.exc_ref, coalesce(x.note, ''), x.actor
      from flow.exception_links l join flow.exceptions e on e.id = l.exception_id join flow.exception_actions x on x.exception_id = e.id where l.link_type = 'order' and l.ref_id = p_order
    union all select c.at, 'custody', coalesce(replace(c.from_state::text, '_', ' '), 'new') || ' → ' || replace(c.to_state::text, '_', ' '), c.qty || ' x ' || coalesce(l.sku, 'item') || coalesce(' · ' || c.reason, ''), c.actor
      from flow.custody_events c join flow.order_lines l on l.id = c.order_line_id where l.order_id = p_order
  ) t where flow.is_member() order by 1 desc limit 200
$$;

do $$
declare v text;
begin
  foreach v in array array['ui_orders','ui_order_lines','ui_allocation','ui_allocation_decisions','ui_production_queue','ui_machines','ui_stock','ui_shortages','ui_purchase_orders','ui_po_lines','ui_overdue_pos',
    'ui_supplier_discrepancies','ui_suppliers','ui_selection','ui_producers','ui_tp_movements','ui_tp_orders','ui_tp_discrepancies','ui_producer_held_stock','ui_custody','ui_unit_trace','ui_bins',
    'ui_artwork_status','ui_artwork_versions','ui_job_packs','ui_communications','ui_labels','ui_settings'] loop
    execute format('revoke all on public.%I from public, anon', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
revoke all on function public.ui_search(text), public.ui_activity(int), public.ui_order_history(uuid) from public, anon;
grant execute on function public.ui_search(text), public.ui_activity(int), public.ui_order_history(uuid) to authenticated;
