-- Seed configuration. Everything here is a tunable DEFAULT, not a fact about the business.
-- Items marked ASSUMPTION are listed in docs/assumptions-and-open-questions.md. All inserts are re-runnable.

-- DecoNetwork status codes: inferred from data (code 3: every row has a ship date). Confirm in Settings.
insert into flow.deco_status_map (code, label, is_open, is_assumed, notes) values
  (1, 'Unknown (1)',            true,  true,  'ASSUMPTION: open. 28 rows seen, none shipped.'),
  (2, 'Unknown (2)',            true,  true,  'ASSUMPTION: open. 2 rows seen, produced but not shipped.'),
  (3, 'Shipped / complete',     false, false, 'Evidence: all 1,490 rows have date_shipped.'),
  (4, 'Cancelled / closed?',    false, true,  'ASSUMPTION: closed. 32 of 36 rows were dismissed in ATAM GO.'),
  (6, 'Unknown (6)',            false, true,  'ASSUMPTION: closed. Single row, no dates.'),
  (7, 'In progress (7)',        true,  true,  'ASSUMPTION: open. Future due dates, never shipped.'),
  (8, 'In progress (8)',        true,  true,  'ASSUMPTION: open.'),
  (9, 'In progress (9)',        true,  true,  'ASSUMPTION: open. Future due dates, never shipped.')
on conflict (code) do nothing;

insert into flow.production_methods (code, name, setup_minutes, minutes_per_unit, sort_order) values
  ('embroidery',   'Embroidery',      15, 6.0, 10),
  ('dtf',          'DTF',             10, 1.5, 20),
  ('dtg',          'DTG',             10, 3.0, 30),
  ('uv',           'UV print',        10, 2.0, 40),
  ('screen_print', 'Screen print',    30, 1.0, 50),
  ('vinyl',        'Vinyl',           10, 2.5, 60),
  ('heat_press',   'Heat press',       5, 1.0, 70),
  ('packing',      'Packing',          0, 1.0, 90)
on conflict (code) do nothing;

-- Process codes observed in DecoNetwork data: WEMB, DTF, UV, DTG (more can be added in Settings)
insert into flow.process_code_map (code, method_code) values
  ('WEMB','embroidery'), ('DTF','dtf'), ('UV','uv'), ('DTG','dtg')
on conflict (code) do nothing;

-- ASSUMPTION: one placeholder machine per active method so the scheduler has capacity to plan against.
insert into flow.machines (code, name, method_code, units_per_hour, notes) values
  ('EMB-1', 'Embroidery (placeholder)', 'embroidery', 10, 'Placeholder. Replace with real machines/heads.'),
  ('DTF-1', 'DTF (placeholder)',        'dtf',        40, 'Placeholder.'),
  ('DTG-1', 'DTG (placeholder)',        'dtg',        20, 'Placeholder.'),
  ('UV-1',  'UV print (placeholder)',   'uv',         30, 'Placeholder.'),
  ('HP-1',  'Heat press (placeholder)', 'heat_press', 60, 'Placeholder.'),
  ('PACK-1','Packing (placeholder)',    'packing',    60, 'Placeholder.')
on conflict (code) do nothing;

-- ASSUMPTION: Mon-Fri 08:00-17:00 default shift for all machines.
insert into flow.machine_shifts (machine_id, weekday, start_time, end_time)
select null, d, time '08:00', time '17:00' from generate_series(1,5) d
where not exists (select 1 from flow.machine_shifts where machine_id is null);

-- ASSUMPTION: placeholder changeover minutes. Tune in Settings.
insert into flow.changeover_rules (method_code, change_type, minutes) values
  ('embroidery','thread_colour', 8), ('embroidery','design', 15), ('embroidery','garment_type', 5),
  ('dtf','ink_colour', 5), ('dtf','design', 5),
  ('dtg','garment_colour', 10), ('dtg','design', 5)
on conflict (method_code, change_type) do nothing;

insert into flow.bin_zones (code, name, description, sort_order) values
  ('RECV', 'Receiving',  'Stock received but not yet allocated', 10),
  ('STG',  'Staging',    'Allocated orders ready for production', 20),
  ('WIP',  'In production', 'Work in progress', 30),
  ('DISP', 'Dispatch',   'Finished, awaiting dispatch', 40)
on conflict (code) do nothing;

-- Garment type rules: copied from the existing ATAM GO table when present (kept independent afterwards).
do $$
declare v_n int := 0;
begin
  if exists (select 1 from flow.garment_type_rules) then return; end if;   -- re-run safe
  if to_regclass('public.product_type_rules') is not null then
    execute 'insert into flow.garment_type_rules (priority, pattern, garment_type)
             select priority, pattern, product_type from public.product_type_rules';
    get diagnostics v_n = row_count;
  end if;
  if v_n = 0 then                                                          -- fallback defaults
    insert into flow.garment_type_rules (priority, pattern, garment_type) values
      (70, '(hood|sweatshirt|\msweat\M|jumper)', 'Sweatshirts & hoodies'),
      (80, '(polo|piqu)', 'Polos'),
      (90, '(t-?shirt|\mtee\M)', 'T-shirts');
  end if;
end $$;

-- Tunable scoring weights. See docs/scoring-and-sequencing.md for how each term is used.
insert into flow.flow_settings (key, value, description) values
 ('allocation.weights', '{
    "due_date":            {"weight": 30, "horizon_days": 14, "note": "0..1 score, 1 = due today, 0 = beyond horizon"},
    "overdue_penalty":     {"weight": 25, "per_day": 2, "cap": 25},
    "customer_vip":        {"weight": 15},
    "manual_priority":     {"high": 8, "rush": 20, "critical": 40},
    "order_value":         {"weight": 10, "cap_value": 2000},
    "order_age":           {"weight": 5,  "cap_days": 30},
    "completable_bonus":   {"weight": 20, "note": "allocation completes the whole order"},
    "completion_pct":      {"weight": 10, "note": "share of order coverable from stock"},
    "stock_scarcity":      {"weight": 8,  "note": "bonus when stock is scarce relative to demand"},
    "production_feasibility": {"weight": 10, "note": "artwork/approval ready, machine available"},
    "complexity_penalty":  {"weight": 5,  "per_stitches": 10000}
  }'::jsonb, 'Priority score weights for stock allocation (transparent, tunable without rebuilding workflows).'),
 ('allocation.thresholds', '{
    "hold_if_completable_pct_below": 50,
    "hold_for_urgent_within_days": 2,
    "allow_partial": true,
    "min_partial_units": 1
  }'::jsonb, 'When to hold stock for a more urgent order versus allocate partially.'),
 ('scheduling.weights', '{
    "due_date": {"weight": 30, "horizon_days": 14},
    "overdue_bonus": 30,
    "rush_bonus": 20,
    "stock_ready_bonus": 15,
    "same_colour_bonus": 6,
    "same_design_bonus": 8,
    "batch_compat_bonus": 5,
    "changeover_penalty_per_min": 0.3,
    "long_job_early_start": {"weight": 10, "hours": 4},
    "blocked_penalty": 100
  }'::jsonb, 'Weights for the heuristic production sequencer.'),
 ('scheduling.horizon_days', '14'::jsonb, 'Days ahead the scheduler plans.'),
 ('app.timezone', '"Europe/London"'::jsonb, 'Business timezone for due dates and shifts.'),
 ('labels.defaults', '{"paper": "A4", "thermal": "100x150", "base_url": null}'::jsonb,
   'Label sizes and the dashboard base URL used in QR codes (set base_url once the Pages URL is final).'),
 ('bins.rules', '{"keep_order_together": true, "prefer_zone": "STG", "max_orders_per_bin": 1}'::jsonb,
   'Bin allocation preferences.')
on conflict (key) do nothing;

-- Convenience: generate bins for a zone, e.g. select flow.generate_bins('STG','B12',24);  -> B12-01 .. B12-24
create or replace function flow.generate_bins(
  p_zone text, p_prefix text, p_count int,
  p_type flow.location_type default 'bin_bay', p_capacity int default null, p_start int default 1
) returns int language plpgsql as $$
declare v_zone uuid; v_n int := 0; v_code text; i int;
begin
  select id into v_zone from flow.bin_zones where code = p_zone;
  if v_zone is null then raise exception 'unknown zone %', p_zone; end if;
  for i in p_start .. p_start + p_count - 1 loop
    v_code := p_prefix || '-' || lpad(i::text, 2, '0');
    insert into flow.bins (bin_code, zone_id, location_type, capacity_units, qr_value)
    values (v_code, v_zone, p_type, p_capacity, 'bin:' || v_code)
    on conflict (bin_code) do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;                                   -- bins actually created (idempotent)
end $$;
