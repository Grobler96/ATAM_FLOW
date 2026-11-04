-- Supplier and producer selection: rate cards, configuration, saved recommendations and the input builder for packages/engine/selector.js.
-- Nothing here is guessed: with no in-house rate or producer rate card, those routes are reported as incomplete instead of being priced.

alter table flow.producers add column cost_out numeric(10,2), add column cost_back numeric(10,2);   -- transport to / from this producer per consignment
alter table flow.suppliers add column on_time_rate numeric(5,2);                                    -- % of deliveries on time (null = no record yet)

create table flow.producer_rates (
  id             uuid primary key default gen_random_uuid(),
  producer_id    uuid not null references flow.producers(id) on delete cascade,
  method         text not null,                             -- embroidery, dtf, uv, dtg ...
  basis          text not null check (basis in ('per_1000_stitches','per_piece')),   -- per_piece is per piece per decorated area
  unit_price     numeric(10,4) not null check (unit_price >= 0),
  setup_fee      numeric(10,2) not null default 0,          -- per design
  min_job_charge numeric(10,2) not null default 0,
  notes          text,
  updated_at     timestamptz not null default now(),
  unique (producer_id, method)
);
alter table flow.producer_rates enable row level security;
create policy producer_rates_read on flow.producer_rates for select to authenticated using (flow.is_member());
create policy producer_rates_cfg_write on flow.producer_rates for all to authenticated using (flow.has_role('admin','manager')) with check (flow.has_role('admin','manager'));
grant select on flow.producer_rates to authenticated;
grant insert, update on flow.producer_rates to authenticated;
grant all on flow.producer_rates to service_role;
create trigger producer_rates_touch before update on flow.producer_rates for each row execute function flow.touch_updated_at();

create table flow.selection_runs (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references flow.orders(id) on delete cascade,
  input_hash     text not null,
  as_of          date not null,
  result         jsonb not null,
  recommended_key text,
  selected_key   text,
  status         text not null default 'proposed' check (status in ('proposed','confirmed','superseded')),
  confirmed_by   text,
  confirmed_at   timestamptz,
  reason         text,
  created_at     timestamptz not null default now()
);
create unique index selection_runs_current on flow.selection_runs (order_id) where status in ('proposed','confirmed');
create index selection_runs_order on flow.selection_runs (order_id, created_at desc);
alter table flow.selection_runs enable row level security;
create policy selection_runs_read on flow.selection_runs for select to authenticated using (flow.is_member());
grant select on flow.selection_runs to authenticated;
grant all on flow.selection_runs to service_role;

insert into flow.flow_settings (key, value, description) values
 ('selection.config', '{"weights":{"margin":50,"speed":25,"risk":25},
    "thresholds":{"target_margin_pct":40,"min_margin_pct":15,"below_min_margin_penalty":20,"due_buffer_days":2,"restock_days":7,"transit_days_each_way":1,"goods_in_days":1,
                  "comfortable_slack_days":7,"default_stitches":5000,"revenue_includes_vat":false,"vat_rate":0.2,"value_on_hand_at":"replacement"},
    "risk":{"late":40,"tight":15,"tight_slack_days":2,"stock_shortfall":15,"moq_unmet":10,"min_order_unmet":8,"over_capacity":15,"direct_to_producer":5,"unknown_reliability":5,"reliability_weight":0.3}}'::jsonb,
  'Selection engine weights and thresholds. Weights say how much margin, speed and risk count; thresholds are margin targets, buffers and assumptions.'),
 ('selection.internal', '{"enabled":true,"queue_days":2,"units_per_day":150,"weekly_capacity_units":null,"rates":{}}'::jsonb,
  'In-house decoration cost. rates is {"embroidery":{"basis":"per_1000_stitches","unit_price":1.0,"setup_fee":10,"min_job_charge":0}, ...}. Empty = in-house is shown as incomplete, never guessed.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Engine input for one order
-- ---------------------------------------------------------------------------
create or replace function flow.selection_input(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare o flow.orders; v_cfg jsonb := coalesce(flow.setting('selection.config'), '{}'::jsonb); v_int jsonb := coalesce(flow.setting('selection.internal'), '{}'::jsonb);
  v_lines jsonb; v_skus text[]; v_sup jsonb; v_prod jsonb; v_methods text[]; v_designs jsonb;
begin
  select * into o from flow.orders where id = p_order;
  if not found then return jsonb_build_object('ok', false, 'error', 'order not found'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'sku', l.sku, 'qty', greatest(l.qty_required - l.qty_produced, 0),
      'need_buy', coalesce((select r.qty_needed from flow.po_requirements(array[p_order]) r where r.order_line_id = l.id), 0),
      'product_name', l.product_name, 'colour', l.colour, 'size', l.size, 'stitches', l.stitches_per_piece, 'areas', l.emb_areas, 'methods', to_jsonb(l.decoration_methods))
      order by l.sku, l.size, l.id), '[]'::jsonb),
    coalesce(array_agg(distinct l.sku) filter (where l.sku is not null), '{}'),
    coalesce(array_agg(distinct m) filter (where m is not null), '{}')
  into v_lines, v_skus, v_methods
  from flow.order_lines l left join lateral unnest(l.decoration_methods) m on true
  where l.order_id = p_order and l.is_active and l.qty_required - l.qty_produced > 0;
  select coalesce(jsonb_object_agg(m, n), '{}'::jsonb) into v_designs from (
    select m, count(distinct coalesce(l.deco_line_id, l.id::text)) n from flow.order_lines l, unnest(l.decoration_methods) m where l.order_id = p_order and l.is_active group by m) d;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'lead_time_days', s.lead_time_days, 'delivery_cost', s.delivery_cost, 'free_delivery_over', s.free_delivery_over,
      'min_order_value', s.min_order_value, 'on_time_rate', s.on_time_rate, 'quality_rating', s.quality_rating, 'can_deliver_to_producer', s.can_deliver_to_producer,
      'offers', coalesce((
        select jsonb_object_agg(k.sku, jsonb_build_object('unit_cost', k.unit_cost, 'min_qty', k.min_qty, 'stock_available', k.stock_available, 'lead_time_days', k.lead_time_days, 'source', k.source))
        from (select x.sku, x.unit_cost, x.min_qty, x.stock_available, x.lead_time_days, 'supplier_offer' as source
              from flow.supplier_offers x where x.supplier_id = s.id and x.sku = any (v_skus)
              union all
              select h.sku, c.unit_cost, 1, null::int, null::numeric, 'last_paid_cost'
              from (select distinct l.sku from flow.po_lines l join flow.purchase_orders p on p.id = l.po_id where p.supplier_ref_id = s.id and l.sku = any (v_skus)) h
              join public.sku_costs c on c.sku = h.sku
              where not exists (select 1 from flow.supplier_offers y where y.supplier_id = s.id and y.sku = h.sku)) k), '{}'::jsonb))
      order by s.name, s.id), '[]'::jsonb)
  into v_sup from flow.suppliers s where s.is_active;

  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'capable_methods', to_jsonb(p.capable_methods), 'turnaround_days', p.turnaround_days,
      'cost_out', p.cost_out, 'cost_back', p.cost_back, 'on_time_rate', ps.on_time_rate, 'weekly_capacity_units', p.weekly_capacity_units, 'open_units', coalesce(ps.units_held, 0),
      'can_direct_dispatch', p.can_direct_dispatch,
      'rates', coalesce((select jsonb_object_agg(r.method, jsonb_build_object('basis', r.basis, 'unit_price', r.unit_price, 'setup_fee', r.setup_fee, 'min_job_charge', r.min_job_charge))
                         from flow.producer_rates r where r.producer_id = p.id), '{}'::jsonb)) order by p.name, p.id), '[]'::jsonb)
  into v_prod from flow.producers p left join flow.producer_stats ps on ps.producer_id = p.id where p.is_active;

  return jsonb_build_object('ok', true, 'today', (now() at time zone 'Europe/London')::date,
    'config', v_cfg,
    'order', jsonb_build_object('id', o.id, 'order_ref', o.order_ref, 'due_date', (o.due_date at time zone 'Europe/London')::date, 'revenue', coalesce(o.order_value, 0),
      'methods', to_jsonb(v_methods), 'designs', v_designs, 'lines', v_lines),
    'suppliers', v_sup, 'producers', v_prod,
    'internal', jsonb_build_object('enabled', coalesce((v_int->>'enabled')::boolean, true), 'queue_days', coalesce((v_int->>'queue_days')::numeric, 2), 'units_per_day', coalesce((v_int->>'units_per_day')::numeric, 150),
      'weekly_capacity_units', v_int->'weekly_capacity_units', 'rates', coalesce(v_int->'rates', '{}'::jsonb),
      'methods', coalesce((select jsonb_agg(distinct method_code) from flow.machines where is_active), '[]'::jsonb)));
end $$;

-- Save the engine's result for an order. Idempotent: if nothing the engine looks at has changed (ignoring today's date) the existing run is kept.
create or replace function flow.save_selection(p_order uuid, p_result jsonb, p_actor text default 'engine') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_hash text; cur flow.selection_runs; v_id uuid;
begin
  if p_result is null or p_result->>'version' is null then return jsonb_build_object('ok', false, 'error', 'not an engine result'); end if;
  v_hash := md5((flow.selection_input(p_order) - 'today')::text);
  select * into cur from flow.selection_runs where order_id = p_order and status in ('proposed','confirmed');
  if found and cur.input_hash = v_hash then return jsonb_build_object('ok', true, 'unchanged', true, 'run_id', cur.id, 'status', cur.status); end if;
  if found and cur.status = 'confirmed' then
    -- keep the confirmed decision, but say that the picture has moved on underneath it
    perform flow.notify('selection_stale', 'warning', 'Confirmed supplier/producer choice may be out of date', 'Order ' || (select order_ref from flow.orders where id = p_order) || ': costs, stock or rates changed after the choice was confirmed. Review it.', 'order', p_order);
  end if;
  if found then update flow.selection_runs set status = 'superseded' where id = cur.id; end if;
  insert into flow.selection_runs (order_id, input_hash, as_of, result, recommended_key, selected_key, status)
  values (p_order, v_hash, (p_result->>'today')::date, p_result, p_result->>'recommended_key', p_result->>'selected_key', 'proposed') returning id into v_id;
  return jsonb_build_object('ok', true, 'run_id', v_id, 'recommended_key', p_result->>'recommended_key');
end $$;

-- A person confirms a choice. Choosing something other than the recommendation needs a reason. This records the decision; it does not raise POs or move stock.
create or replace function flow.confirm_selection(p_order uuid, p_key text, p_actor text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare cur flow.selection_runs; opt jsonb;
begin
  begin
    select * into cur from flow.selection_runs where order_id = p_order and status in ('proposed','confirmed');
    if not found then raise exception 'no saved recommendation for this order: run the selection first'; end if;
    select x into opt from jsonb_array_elements(cur.result->'options') x where x->>'key' = p_key;
    if opt is null then raise exception 'that option is not in the saved recommendation'; end if;
    if coalesce((opt->>'incomplete')::boolean, false) then raise exception 'that option has missing costs and cannot be confirmed yet'; end if;
    if p_key is distinct from cur.recommended_key and coalesce(p_reason, '') = '' then raise exception 'a reason is required when choosing something other than the recommendation'; end if;
    update flow.selection_runs set status = 'confirmed', selected_key = p_key, confirmed_by = p_actor, confirmed_at = now(), reason = p_reason where id = cur.id;
    insert into flow.audit_log (actor, action, entity, entity_id, after, reason) values (p_actor, 'confirm_selection', 'order', p_order::text,
      jsonb_build_object('key', p_key, 'recommended', cur.recommended_key, 'total_cost', opt->'costs'->'total', 'margin_pct', opt->'margin_pct'), p_reason);
    return jsonb_build_object('ok', true, 'selected', opt->'supplier_plan', 'suppliers', opt->'suppliers', 'route', opt->'route',
      'next', 'Create the purchase order with the chosen supplier(s), then build the job pack for the producer.');
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace view flow.v_selection_latest with (security_invoker = true) as
select r.order_id, o.order_ref, o.customer_name, o.due_date::date as due_date, r.status, r.as_of, r.recommended_key, r.selected_key, r.confirmed_by, r.confirmed_at,
       rec->>'supplier_plan' as supplier_plan, rec->'route'->>'name' as route_name, (rec->'costs'->>'total')::numeric as total_cost, (rec->>'profit')::numeric as profit,
       (rec->>'margin_pct')::numeric as margin_pct, rec->'timeline'->>'ready_date' as ready_date, (rec->'timeline'->>'slack_days')::int as slack_days,
       (rec->'risk'->>'score')::numeric as risk_score, r.result->>'explanation' as explanation, jsonb_array_length(r.result->'options') as options_considered
from flow.selection_runs r join flow.orders o on o.id = r.order_id
left join lateral (select x from jsonb_array_elements(r.result->'options') x where x->>'key' = coalesce(r.selected_key, r.recommended_key) limit 1) k(rec) on true
where r.status in ('proposed','confirmed');

create or replace function public.flow_selection_input(p_order uuid) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.selection_input(p_order) $$;
create or replace function public.flow_save_selection(p_order uuid, p_result jsonb, p_actor text default 'engine') returns jsonb language sql security definer set search_path = flow, public as $$ select flow.save_selection(p_order, p_result, p_actor) $$;
create or replace function public.flow_confirm_selection(p_order uuid, p_key text, p_actor text, p_reason text default null) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.confirm_selection(p_order, p_key, p_actor, p_reason) $$;

do $$
declare f text;
begin
  foreach f in array array['flow.selection_input(uuid)', 'flow.save_selection(uuid,jsonb,text)', 'flow.confirm_selection(uuid,text,text,text)',
    'public.flow_selection_input(uuid)', 'public.flow_save_selection(uuid,jsonb,text)', 'public.flow_confirm_selection(uuid,text,text,text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on flow.v_selection_latest to authenticated;
