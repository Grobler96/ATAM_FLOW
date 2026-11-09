-- Stock-takes. Count what is physically on the shelves and compare it with what the system says.
-- DecoNetwork owns on-hand quantities and overwrites them on every sync, so a stock-take NEVER edits stock. It keeps its own record of what was counted and what the gap is,
-- turns accepted shortfalls into suggested waste records, and stays flagged until someone has put the correction right in DecoNetwork.
-- Controls: counting is blind (the expected quantity is hidden from the counter until counting is finished); a count far from the expected quantity needs a recount by a
-- DIFFERENT person; every accepted variance needs a reason; a large variance needs a manager or admin; closing needs every difference dealt with.

create sequence if not exists flow.stocktake_seq;

insert into flow.flow_settings (key, value, description) values
 ('stocktake.rules', '{"recount_units": 5, "recount_value": 50, "approve_value": 250, "adjust_chase_days": 3, "stale_days": 7}'::jsonb,
  'Stock-takes: a difference of this many units or this much money needs a recount by someone else; a difference worth more than approve_value needs a manager; days before an unfixed result or an unfinished take is raised')
on conflict (key) do nothing;

insert into flow.waste_causes (code, label, default_party, sort_order) values ('stock_count', 'Stock count shortfall', 'us', 110) on conflict (code) do nothing;

create table flow.stock_takes (
  id            uuid primary key default gen_random_uuid(),
  take_ref      text not null unique,
  name          text not null,
  scope_kind    text not null check (scope_kind in ('all', 'location', 'skus', 'high_value')),
  scope_detail  text,
  status        text not null default 'counting' check (status in ('counting', 'review', 'closed', 'cancelled')),
  created_by    text not null,
  created_at    timestamptz not null default now(),
  review_at     timestamptz, review_by text,
  closed_at     timestamptz, closed_by text, close_note text,
  cancelled_at  timestamptz, cancelled_by text, cancel_reason text,
  dn_adjusted_at timestamptz, dn_adjusted_by text, dn_note text       -- the correction has been made in DecoNetwork
);
create index stock_takes_open on flow.stock_takes (status) where status in ('counting', 'review');

create table flow.stock_take_lines (
  id            uuid primary key default gen_random_uuid(),
  take_id       uuid not null references flow.stock_takes(id),
  stock_item_id uuid not null references flow.stock_items(id),
  sku           text not null, product_name text, colour text, size text, location text,
  expected_qty  int not null,                                  -- on hand when the take started
  unit_cost     numeric(12,4) not null default 0,
  added_in_count boolean not null default false,               -- found on the shelf though it was not on the list
  counted_qty   int check (counted_qty is null or counted_qty >= 0), counted_by text, counted_at timestamptz,
  recount_qty   int check (recount_qty is null or recount_qty >= 0), recount_by text, recount_at timestamptz,
  status        text not null default 'to_count' check (status in ('to_count', 'counted', 'matched', 'recount_needed', 'recounted', 'accepted')),
  accept_reason text, accepted_by text, accepted_at timestamptz,
  unique (take_id, stock_item_id)
);
create index stock_take_lines_take on flow.stock_take_lines (take_id, status);

create table flow.stock_take_counts (                          -- every count ever entered, never changed
  id      bigint generated always as identity primary key,
  line_id uuid not null references flow.stock_take_lines(id),
  at      timestamptz not null default now(),
  kind    text not null check (kind in ('count', 'recount')),
  qty     int not null,
  by      text not null
);
create or replace function flow.block_count_log_mutation() returns trigger language plpgsql as $$ begin raise exception 'flow.stock_take_counts is append-only'; end $$;
create trigger stock_take_counts_immutable before update or delete on flow.stock_take_counts for each row execute function flow.block_count_log_mutation();

alter table flow.stock_takes enable row level security;
alter table flow.stock_take_lines enable row level security;
alter table flow.stock_take_counts enable row level security;
create policy stock_takes_read on flow.stock_takes for select to authenticated using (flow.is_member());
create policy stock_take_lines_read on flow.stock_take_lines for select to authenticated using (flow.is_member());
create policy stock_take_counts_read on flow.stock_take_counts for select to authenticated using (flow.is_member());

create or replace function flow.stocktake_rules() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select '{"recount_units": 5, "recount_value": 50, "approve_value": 250, "adjust_chase_days": 3, "stale_days": 7}'::jsonb || coalesce(flow.setting('stocktake.rules'), '{}'::jsonb)
$$;

-- ---------------------------------------------------------------------------
-- Actions (service role, called by the Operations actions workflow)
-- ---------------------------------------------------------------------------
-- p_scope: {kind:'all'} | {kind:'location', location:'A3'} | {kind:'skus', skus:['X','Y']} | {kind:'high_value', top:50}
create or replace function flow.stocktake_start(p_name text, p_scope jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_kind text := p_scope->>'kind'; v_id uuid; v_ref text; v_detail text; v_n int; v_skipped int := 0; v_unknown text[] := '{}'; v_top int; v_skus text[]; v_loc text; v_ids uuid[];
begin
  if length(btrim(coalesce(p_name, ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Give the stock-take a name (for example "November full count").'); end if;
  if coalesce(v_kind, '') not in ('all', 'location', 'skus', 'high_value') then return jsonb_build_object('ok', false, 'error', 'Choose what to count.'); end if;
  if v_kind = 'all' then
    select array_agg(id) into v_ids from flow.stock_items where not is_placeholder and (qty_on_hand > 0 or coalesce(storage_location, '') <> '');
    v_detail := 'Every item with stock or a shelf location';
  elsif v_kind = 'location' then
    v_loc := btrim(coalesce(p_scope->>'location', '')); if length(v_loc) < 1 then return jsonb_build_object('ok', false, 'error', 'Enter the shelf or area to count.'); end if;
    select array_agg(id) into v_ids from flow.stock_items where not is_placeholder and storage_location ilike replace(replace(v_loc, '%', ''), '_', '') || '%';
    v_detail := 'Shelf or area starting "' || v_loc || '"';
  elsif v_kind = 'skus' then
    select array_agg(distinct upper(btrim(x))) into v_skus from jsonb_array_elements_text(coalesce(p_scope->'skus', '[]'::jsonb)) x where btrim(x) <> '';
    if v_skus is null or cardinality(v_skus) = 0 then return jsonb_build_object('ok', false, 'error', 'Enter at least one SKU.'); end if;
    if cardinality(v_skus) > 500 then return jsonb_build_object('ok', false, 'error', 'Up to 500 SKUs at a time.'); end if;
    select array_agg(id) into v_ids from flow.stock_items where upper(sku) = any (v_skus);
    select coalesce(array_agg(s), '{}') into v_unknown from unnest(v_skus) s where not exists (select 1 from flow.stock_items i where upper(i.sku) = s);
    v_detail := cardinality(v_skus) || ' chosen SKU(s)';
  else
    v_top := least(greatest(coalesce(nullif(p_scope->>'top', '')::int, 50), 1), 500);
    select array_agg(id order by v, sku) into v_ids from (select i.id, i.sku, i.qty_on_hand * flow.waste_cost(i.sku) * -1 as v from flow.stock_items i where not i.is_placeholder and i.qty_on_hand > 0
      and not exists (select 1 from flow.stock_take_lines l join flow.stock_takes t on t.id = l.take_id where l.stock_item_id = i.id and t.status in ('counting', 'review')) order by 3, 2 limit v_top) q;
    v_detail := 'The ' || v_top || ' most valuable items on the shelf';
  end if;
  -- an item is only in one open stock-take at a time
  select count(*) into v_skipped from unnest(coalesce(v_ids, '{}'::uuid[])) c where exists (select 1 from flow.stock_take_lines l join flow.stock_takes t on t.id = l.take_id where l.stock_item_id = c and t.status in ('counting', 'review'));
  select array_agg(c) into v_ids from unnest(coalesce(v_ids, '{}'::uuid[])) c where not exists (select 1 from flow.stock_take_lines l join flow.stock_takes t on t.id = l.take_id where l.stock_item_id = c and t.status in ('counting', 'review'));
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'Nothing matches that. ' || case when v_skipped > 0 then v_skipped || ' item(s) are already in another open stock-take.' else 'Check what you chose to count.' end, 'unknown_skus', to_jsonb(v_unknown)); end if;
  if v_n > 3000 then return jsonb_build_object('ok', false, 'error', v_n || ' items is too many for one stock-take. Count by shelf or choose the most valuable.'); end if;
  v_ref := 'ST-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.stocktake_seq')::text, 4, '0');
  insert into flow.stock_takes (take_ref, name, scope_kind, scope_detail, created_by) values (v_ref, btrim(p_name), v_kind, v_detail, p_actor) returning id into v_id;
  insert into flow.stock_take_lines (take_id, stock_item_id, sku, product_name, colour, size, location, expected_qty, unit_cost)
  select v_id, i.id, i.sku, i.product_name, i.colour, i.size, i.storage_location, i.qty_on_hand, flow.waste_cost(i.sku) from flow.stock_items i where i.id = any (v_ids);
  perform flow.wh_audit(p_actor, 'stocktake_start', 'stocktake', v_ref, null, jsonb_build_object('scope', v_detail, 'lines', v_n, 'skipped_in_other_take', v_skipped), p_name);
  return jsonb_build_object('ok', true, 'take_id', v_id, 'take_ref', v_ref, 'lines', v_n, 'skipped_in_other_take', v_skipped, 'unknown_skus', to_jsonb(v_unknown));
end $$;

-- Enter a count. Blind: the answer never includes the expected quantity.
create or replace function flow.stocktake_count(p_take uuid, p_sku text, p_qty int, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes; l flow.stock_take_lines; i flow.stock_items; v_total int; v_done int;
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status <> 'counting' then return jsonb_build_object('ok', false, 'error', 'Counting has finished on this stock-take.'); end if;
  if p_qty is null or p_qty < 0 or p_qty > 1000000 then return jsonb_build_object('ok', false, 'error', 'Enter how many you counted (0 or more).'); end if;
  select * into l from flow.stock_take_lines where take_id = p_take and upper(sku) = upper(btrim(coalesce(p_sku, '')));
  if l.id is null then
    select * into i from flow.stock_items where upper(sku) = upper(btrim(coalesce(p_sku, '')));
    if i.id is null then return jsonb_build_object('ok', false, 'error', 'That SKU is not in the stock list. Check the code on the shelf label.'); end if;
    if exists (select 1 from flow.stock_take_lines x join flow.stock_takes y on y.id = x.take_id where x.stock_item_id = i.id and y.status in ('counting', 'review') and y.id <> p_take) then
      return jsonb_build_object('ok', false, 'error', 'That SKU is being counted in another stock-take.');
    end if;
    insert into flow.stock_take_lines (take_id, stock_item_id, sku, product_name, colour, size, location, expected_qty, unit_cost, added_in_count)
    values (p_take, i.id, i.sku, i.product_name, i.colour, i.size, i.storage_location, i.qty_on_hand, flow.waste_cost(i.sku), true) returning * into l;
  end if;
  update flow.stock_take_lines set counted_qty = p_qty, counted_by = p_actor, counted_at = now(), status = 'counted' where id = l.id;
  insert into flow.stock_take_counts (line_id, kind, qty, by) values (l.id, 'count', p_qty, p_actor);
  select count(*), count(*) filter (where counted_qty is not null) into v_total, v_done from flow.stock_take_lines where take_id = p_take;
  return jsonb_build_object('ok', true, 'sku', l.sku, 'product_name', l.product_name, 'colour', l.colour, 'size', l.size, 'location', l.location, 'counted_qty', p_qty,
    'added_in_count', l.added_in_count, 'counted_lines', v_done, 'total_lines', v_total, 'recount', l.counted_qty is not null);
end $$;

-- Finish counting: now the expected quantities are revealed and each difference is sorted into matched, needs a recount, or waiting for a decision.
create or replace function flow.stocktake_review(p_take uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes; r jsonb := flow.stocktake_rules(); v_counted int; v_matched int; v_recount int; v_var int; v_left int;
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status <> 'counting' then return jsonb_build_object('ok', false, 'error', 'This stock-take is not being counted.'); end if;
  select count(*) into v_counted from flow.stock_take_lines where take_id = p_take and counted_qty is not null;
  if v_counted = 0 then return jsonb_build_object('ok', false, 'error', 'Nothing has been counted yet.'); end if;
  update flow.stock_take_lines set status = 'matched' where take_id = p_take and counted_qty is not null and counted_qty = expected_qty;
  update flow.stock_take_lines set status = 'recount_needed'
   where take_id = p_take and counted_qty is not null and counted_qty <> expected_qty
     and (abs(counted_qty - expected_qty) >= (r->>'recount_units')::int or abs(counted_qty - expected_qty) * unit_cost >= (r->>'recount_value')::numeric);
  update flow.stock_takes set status = 'review', review_at = now(), review_by = p_actor where id = p_take;
  select count(*) filter (where status = 'matched'), count(*) filter (where status = 'recount_needed'), count(*) filter (where status = 'counted'), count(*) filter (where status = 'to_count')
    into v_matched, v_recount, v_var, v_left from flow.stock_take_lines where take_id = p_take;
  perform flow.wh_audit(p_actor, 'stocktake_review', 'stocktake', t.take_ref, null, jsonb_build_object('counted', v_counted, 'matched', v_matched, 'recount_needed', v_recount, 'differences', v_var, 'not_counted', v_left), null);
  return jsonb_build_object('ok', true, 'take_ref', t.take_ref, 'counted', v_counted, 'matched', v_matched, 'recount_needed', v_recount, 'differences', v_var, 'not_counted', v_left);
end $$;

-- A recount must be done by someone other than the person who counted.
create or replace function flow.stocktake_recount(p_take uuid, p_sku text, p_qty int, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes; l flow.stock_take_lines;
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'Recounts happen after counting has finished.'); end if;
  if p_qty is null or p_qty < 0 or p_qty > 1000000 then return jsonb_build_object('ok', false, 'error', 'Enter how many you counted (0 or more).'); end if;
  select * into l from flow.stock_take_lines where take_id = p_take and upper(sku) = upper(btrim(coalesce(p_sku, '')));
  if l.id is null then return jsonb_build_object('ok', false, 'error', 'That SKU is not in this stock-take.'); end if;
  if l.status not in ('counted', 'recount_needed', 'recounted') then return jsonb_build_object('ok', false, 'error', 'That line does not need a recount (' || replace(l.status, '_', ' ') || ').'); end if;
  if lower(l.counted_by) = lower(p_actor) then return jsonb_build_object('ok', false, 'error', 'A different person has to do the recount, so it is an independent check.'); end if;
  update flow.stock_take_lines set recount_qty = p_qty, recount_by = p_actor, recount_at = now(), status = case when p_qty = expected_qty then 'matched' else 'recounted' end where id = l.id;
  insert into flow.stock_take_counts (line_id, kind, qty, by) values (l.id, 'recount', p_qty, p_actor);
  return jsonb_build_object('ok', true, 'sku', l.sku, 'recount_qty', p_qty, 'status', case when p_qty = l.expected_qty then 'matched' else 'recounted' end);
end $$;

create or replace function flow.stocktake_accept(p_line uuid, p_reason text, p_senior boolean, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare l flow.stock_take_lines; t flow.stock_takes; r jsonb := flow.stocktake_rules(); v_final int; v_val numeric; v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into l from flow.stock_take_lines where id = p_line; if l.id is null then return jsonb_build_object('ok', false, 'error', 'Line not found.'); end if;
  select * into t from flow.stock_takes where id = l.take_id;
  if t.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'Differences are accepted while the stock-take is in review.'); end if;
  if l.status not in ('counted', 'recounted', 'recount_needed') then return jsonb_build_object('ok', false, 'error', 'There is nothing to accept on that line (' || replace(l.status, '_', ' ') || ').'); end if;
  if length(v_reason) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the difference is accepted (at least a few words).'); end if;
  v_final := coalesce(l.recount_qty, l.counted_qty); v_val := abs(v_final - l.expected_qty) * l.unit_cost;
  if l.status = 'recount_needed' and not coalesce(p_senior, false) then return jsonb_build_object('ok', false, 'error', 'This difference is big enough to need a recount by someone else first. A manager can accept it without a recount, with a reason.'); end if;
  if v_val > (r->>'approve_value')::numeric and not coalesce(p_senior, false) then return jsonb_build_object('ok', false, 'error', format('This difference is worth £%s. A manager or admin has to accept anything over £%s.', round(v_val, 2), (r->>'approve_value'))); end if;
  update flow.stock_take_lines set status = 'accepted', accept_reason = v_reason, accepted_by = p_actor, accepted_at = now() where id = l.id;
  perform flow.wh_audit(p_actor, 'stocktake_accept', 'stocktake', t.take_ref, null, jsonb_build_object('sku', l.sku, 'expected', l.expected_qty, 'counted', v_final, 'value', round(v_val, 2)), v_reason);
  return jsonb_build_object('ok', true, 'sku', l.sku, 'variance', v_final - l.expected_qty, 'value', round(v_val, 2));
end $$;

-- One reason for all the small differences that did not need a recount.
create or replace function flow.stocktake_accept_small(p_take uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes; r jsonb := flow.stocktake_rules(); v_reason text := btrim(coalesce(p_reason, '')); v_n int;
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'Differences are accepted while the stock-take is in review.'); end if;
  if length(v_reason) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why these small differences are accepted (at least a few words).'); end if;
  update flow.stock_take_lines set status = 'accepted', accept_reason = v_reason, accepted_by = p_actor, accepted_at = now()
   where take_id = p_take and status in ('counted', 'recounted') and abs(coalesce(recount_qty, counted_qty) - expected_qty) * unit_cost <= (r->>'approve_value')::numeric;
  get diagnostics v_n = row_count;
  perform flow.wh_audit(p_actor, 'stocktake_accept_small', 'stocktake', t.take_ref, null, jsonb_build_object('lines', v_n), v_reason);
  return jsonb_build_object('ok', true, 'accepted', v_n);
end $$;

create or replace function flow.stocktake_close(p_take uuid, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes; v_open int; v_matched int; v_acc int; v_short_u int; v_short_v numeric; v_over_u int; v_over_v numeric; v_unc int; v_waste int := 0;
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status <> 'review' then return jsonb_build_object('ok', false, 'error', 'Only a stock-take in review can be closed.'); end if;
  select count(*) into v_open from flow.stock_take_lines where take_id = p_take and status in ('counted', 'recounted', 'recount_needed');
  if v_open > 0 then return jsonb_build_object('ok', false, 'error', v_open || ' difference(s) still need a recount or a decision before this can be closed.', 'open_lines', v_open); end if;
  -- shortfalls become suggested waste (a person still confirms them on the Waste page)
  with ins as (
    insert into flow.waste_events (waste_ref, stage, cause_code, party, qty, sku, product_name, unit_cost, source, source_key, status, reason, recorded_by)
    select 'WST-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('flow.waste_seq')::text, 4, '0'), 'warehouse', 'stock_count', 'us', l.expected_qty - coalesce(l.recount_qty, l.counted_qty), l.sku, l.product_name, l.unit_cost,
           'manual', 'stocktake:' || l.id, 'suggested', 'Stock-take ' || t.take_ref || ': counted ' || coalesce(l.recount_qty, l.counted_qty) || ', expected ' || l.expected_qty || ' (' || l.accept_reason || ')', p_actor
    from flow.stock_take_lines l where l.take_id = p_take and l.status = 'accepted' and coalesce(l.recount_qty, l.counted_qty) < l.expected_qty
    on conflict (source_key) do nothing returning 1) select count(*) into v_waste from ins;
  update flow.stock_takes set status = 'closed', closed_at = now(), closed_by = p_actor, close_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_take;
  select count(*) filter (where status = 'matched'), count(*) filter (where status = 'accepted'), count(*) filter (where status = 'to_count'),
         coalesce(sum(expected_qty - coalesce(recount_qty, counted_qty)) filter (where status = 'accepted' and coalesce(recount_qty, counted_qty) < expected_qty), 0),
         coalesce(sum((expected_qty - coalesce(recount_qty, counted_qty)) * unit_cost) filter (where status = 'accepted' and coalesce(recount_qty, counted_qty) < expected_qty), 0),
         coalesce(sum(coalesce(recount_qty, counted_qty) - expected_qty) filter (where status = 'accepted' and coalesce(recount_qty, counted_qty) > expected_qty), 0),
         coalesce(sum((coalesce(recount_qty, counted_qty) - expected_qty) * unit_cost) filter (where status = 'accepted' and coalesce(recount_qty, counted_qty) > expected_qty), 0)
    into v_matched, v_acc, v_unc, v_short_u, v_short_v, v_over_u, v_over_v from flow.stock_take_lines where take_id = p_take;
  perform flow.wh_audit(p_actor, 'stocktake_close', 'stocktake', t.take_ref, null, jsonb_build_object('matched', v_matched, 'differences', v_acc, 'shortfall_units', v_short_u, 'shortfall_value', round(v_short_v, 2), 'surplus_units', v_over_u, 'not_counted', v_unc), p_note);
  return jsonb_build_object('ok', true, 'take_ref', t.take_ref, 'matched', v_matched, 'differences', v_acc, 'shortfall_units', v_short_u, 'shortfall_value', round(v_short_v, 2), 'surplus_units', v_over_u, 'surplus_value', round(v_over_v, 2),
    'not_counted', v_unc, 'waste_suggestions', v_waste);
end $$;

create or replace function flow.stocktake_cancel(p_take uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes; v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status not in ('counting', 'review') then return jsonb_build_object('ok', false, 'error', 'Only an open stock-take can be cancelled.'); end if;
  if length(v_reason) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why it is being cancelled (at least a few words).'); end if;
  update flow.stock_takes set status = 'cancelled', cancelled_at = now(), cancelled_by = p_actor, cancel_reason = v_reason where id = p_take;
  perform flow.wh_audit(p_actor, 'stocktake_cancel', 'stocktake', t.take_ref, null, '{}'::jsonb, v_reason);
  return jsonb_build_object('ok', true, 'take_ref', t.take_ref);
end $$;

-- The correction has been made in DecoNetwork.
create or replace function flow.stocktake_mark_adjusted(p_take uuid, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.stock_takes;
begin
  select * into t from flow.stock_takes where id = p_take; if t.id is null then return jsonb_build_object('ok', false, 'error', 'Stock-take not found.'); end if;
  if t.status <> 'closed' then return jsonb_build_object('ok', false, 'error', 'Only a closed stock-take can be marked as corrected.'); end if;
  if t.dn_adjusted_at is not null then return jsonb_build_object('ok', false, 'error', 'It is already marked as corrected.'); end if;
  update flow.stock_takes set dn_adjusted_at = now(), dn_adjusted_by = p_actor, dn_note = nullif(btrim(coalesce(p_note, '')), '') where id = p_take;
  perform flow.wh_audit(p_actor, 'stocktake_adjusted', 'stocktake', t.take_ref, null, '{}'::jsonb, p_note);
  return jsonb_build_object('ok', true, 'take_ref', t.take_ref);
end $$;

-- ---------------------------------------------------------------------------
-- Read models. While counting, the expected quantity and the difference are hidden (blind count).
-- ---------------------------------------------------------------------------
create or replace view public.ui_stock_take_lines with (security_invoker = true) as
select l.id, l.take_id, t.take_ref, t.status as take_status, l.stock_item_id, l.sku, l.product_name, l.colour, l.size, l.location, l.unit_cost, l.added_in_count,
       case when t.status = 'counting' then null else l.expected_qty end as expected_qty,
       l.counted_qty, l.counted_by, l.counted_at, l.recount_qty, l.recount_by, l.recount_at, coalesce(l.recount_qty, l.counted_qty) as final_qty,
       case when t.status = 'counting' or coalesce(l.recount_qty, l.counted_qty) is null then null else coalesce(l.recount_qty, l.counted_qty) - l.expected_qty end as variance,
       case when t.status = 'counting' or coalesce(l.recount_qty, l.counted_qty) is null then null else round((coalesce(l.recount_qty, l.counted_qty) - l.expected_qty) * l.unit_cost, 2) end as variance_value,
       case when t.status = 'counting' then (case when l.counted_qty is null then 'to_count' else 'counted' end) else l.status end as status,
       l.accept_reason, l.accepted_by, l.accepted_at
from flow.stock_take_lines l join flow.stock_takes t on t.id = l.take_id;

create or replace view public.ui_stock_takes with (security_invoker = true) as
select t.id, t.take_ref, t.name, t.scope_kind, t.scope_detail, t.status, t.created_by, t.created_at, t.review_at, t.review_by, t.closed_at, t.closed_by, t.close_note, t.cancelled_at, t.cancelled_by, t.cancel_reason,
       t.dn_adjusted_at, t.dn_adjusted_by, t.dn_note,
       count(l.id) as lines, count(l.id) filter (where l.counted_qty is not null) as counted_lines,
       case when t.status = 'counting' then null else count(l.id) filter (where l.status = 'matched') end as matched_lines,
       case when t.status = 'counting' then null else count(l.id) filter (where l.status in ('counted', 'recounted', 'recount_needed')) end as open_lines,
       case when t.status = 'counting' then null else count(l.id) filter (where l.status = 'recount_needed') end as recount_lines,
       case when t.status in ('counting', 'cancelled') then null else coalesce(sum(coalesce(l.recount_qty, l.counted_qty) - l.expected_qty) filter (where l.counted_qty is not null), 0) end as net_units,
       case when t.status in ('counting', 'cancelled') then null else round(coalesce(sum((coalesce(l.recount_qty, l.counted_qty) - l.expected_qty) * l.unit_cost) filter (where l.counted_qty is not null), 0), 2) end as net_value,
       case when t.status in ('counting', 'cancelled') then null else round(coalesce(sum((l.expected_qty - coalesce(l.recount_qty, l.counted_qty)) * l.unit_cost) filter (where l.counted_qty is not null and coalesce(l.recount_qty, l.counted_qty) < l.expected_qty), 0), 2) end as shortfall_value,
       (t.status = 'closed' and t.dn_adjusted_at is null and exists (select 1 from flow.stock_take_lines x where x.take_id = t.id and x.status = 'accepted')) as needs_correction
from flow.stock_takes t left join flow.stock_take_lines l on l.take_id = t.id
group by t.id;

-- ---------------------------------------------------------------------------
-- Exceptions: a result nobody has put right in DecoNetwork, and a stock-take left open
-- ---------------------------------------------------------------------------
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('stocktake_not_corrected', 'Stock-take result not put right in DecoNetwork', 'stock', 'medium', '{}', 'manager', 'Adjust the stock levels in DecoNetwork for the accepted differences, then mark the stock-take as corrected.'),
 ('stocktake_unfinished', 'Stock-take left open', 'stock', 'medium', '{}', 'warehouse', 'Finish counting, review the differences and close it, or cancel it with a reason.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_stocktakes() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'stocktake_not_corrected', 'key', 'stocktake_fix:' || t.id,
      'description', format('Stock-take %s (%s) was closed %s day(s) ago with %s accepted difference(s) and the stock levels in DecoNetwork have not been marked as corrected', t.take_ref, t.name, floor(extract(epoch from (now() - t.closed_at)) / 86400)::int,
        (select count(*) from flow.stock_take_lines l where l.take_id = t.id and l.status = 'accepted')),
      'links', '[]'::jsonb,
      'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'stock', 'detected_by', 'automation', 'source_type', 'stocktake', 'source_id', t.id::text)) as x
    from flow.stock_takes t
    where t.status = 'closed' and t.dn_adjusted_at is null and t.closed_at < now() - make_interval(days => (flow.stocktake_rules()->>'adjust_chase_days')::int)
      and exists (select 1 from flow.stock_take_lines l where l.take_id = t.id and l.status = 'accepted')
    union all
    select jsonb_build_object('type', 'stocktake_unfinished', 'key', 'stocktake_open:' || t.id,
      'description', format('Stock-take %s (%s) has been %s for %s day(s)', t.take_ref, t.name, case t.status when 'counting' then 'counting' else 'in review' end, floor(extract(epoch from (now() - t.created_at)) / 86400)::int),
      'links', '[]'::jsonb,
      'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'process', 'detected_by', 'automation', 'source_type', 'stocktake', 'source_id', t.id::text))
    from flow.stock_takes t
    where t.status in ('counting', 'review') and t.created_at < now() - make_interval(days => (flow.stocktake_rules()->>'stale_days')::int)
  ) q
$$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%''stocktakes''%' then
    v_def := replace(v_def, '''proofs''] loop', '''proofs'',''stocktakes''] loop');
    if v_def not like '%''stocktakes''%' then raise exception 'detector list anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- Wrappers for n8n (service role only) and grants
create or replace function public.flow_stocktake_start(p_name text, p_scope jsonb, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_start(p_name, p_scope, p_actor) $$;
create or replace function public.flow_stocktake_count(p_take uuid, p_sku text, p_qty int, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_count(p_take, p_sku, p_qty, p_actor) $$;
create or replace function public.flow_stocktake_review(p_take uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_review(p_take, p_actor) $$;
create or replace function public.flow_stocktake_recount(p_take uuid, p_sku text, p_qty int, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_recount(p_take, p_sku, p_qty, p_actor) $$;
create or replace function public.flow_stocktake_accept(p_line uuid, p_reason text, p_senior boolean, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_accept(p_line, p_reason, p_senior, p_actor) $$;
create or replace function public.flow_stocktake_accept_small(p_take uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_accept_small(p_take, p_reason, p_actor) $$;
create or replace function public.flow_stocktake_close(p_take uuid, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_close(p_take, p_note, p_actor) $$;
create or replace function public.flow_stocktake_cancel(p_take uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_cancel(p_take, p_reason, p_actor) $$;
create or replace function public.flow_stocktake_mark_adjusted(p_take uuid, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.stocktake_mark_adjusted(p_take, p_note, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['flow.stocktake_rules()', 'flow.stocktake_start(text,jsonb,text)', 'flow.stocktake_count(uuid,text,int,text)', 'flow.stocktake_review(uuid,text)', 'flow.stocktake_recount(uuid,text,int,text)', 'flow.stocktake_accept(uuid,text,boolean,text)',
      'flow.stocktake_accept_small(uuid,text,text)', 'flow.stocktake_close(uuid,text,text)', 'flow.stocktake_cancel(uuid,text,text)', 'flow.stocktake_mark_adjusted(uuid,text,text)', 'flow.exc_detect_stocktakes()',
      'public.flow_stocktake_start(text,jsonb,text)', 'public.flow_stocktake_count(uuid,text,int,text)', 'public.flow_stocktake_review(uuid,text)', 'public.flow_stocktake_recount(uuid,text,int,text)', 'public.flow_stocktake_accept(uuid,text,boolean,text)',
      'public.flow_stocktake_accept_small(uuid,text,text)', 'public.flow_stocktake_close(uuid,text,text)', 'public.flow_stocktake_cancel(uuid,text,text)', 'public.flow_stocktake_mark_adjusted(uuid,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach f in array array['public.flow_stocktake_start(text,jsonb,text)', 'public.flow_stocktake_count(uuid,text,int,text)', 'public.flow_stocktake_review(uuid,text)', 'public.flow_stocktake_recount(uuid,text,int,text)', 'public.flow_stocktake_accept(uuid,text,boolean,text)',
      'public.flow_stocktake_accept_small(uuid,text,text)', 'public.flow_stocktake_close(uuid,text,text)', 'public.flow_stocktake_cancel(uuid,text,text)', 'public.flow_stocktake_mark_adjusted(uuid,text,text)']
  loop execute format('grant execute on function %s to service_role', f); end loop;
  revoke all on flow.stock_takes, flow.stock_take_lines, flow.stock_take_counts from public, anon;
  grant select on flow.stock_takes, flow.stock_take_lines, flow.stock_take_counts to authenticated;
  revoke all on public.ui_stock_take_lines, public.ui_stock_takes from public, anon;
  grant select on public.ui_stock_take_lines, public.ui_stock_takes to authenticated;
end $$;
