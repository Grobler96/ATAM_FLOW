-- Warehouse flows: bins (create / suggest / assign / move / release / status), stock locations,
-- label generation + print audit, bin search and read models. Every consequential action is audited.

-- ---------------------------------------------------------------------------
-- Label table: a free reference per target (SKU, movement code…) and print detail.
-- ---------------------------------------------------------------------------
alter table flow.labels add column if not exists ref text;
alter table flow.label_prints add column if not exists format text;
alter table flow.label_prints add column if not exists copies int not null default 1;
alter table flow.label_prints add column if not exists is_reprint boolean not null default false;
drop index if exists flow.labels_one_per_target;
create unique index if not exists labels_one_per_target on flow.labels
  (label_type, coalesce(order_id, '00000000-0000-0000-0000-000000000000'::uuid),
               coalesce(bin_id,   '00000000-0000-0000-0000-000000000000'::uuid), coalesce(ref, ''));
create index if not exists labels_pending on flow.labels (created_at) where print_status <> 'printed';
create index if not exists bin_assignments_order on flow.bin_assignments (order_id) where released_at is null;

create or replace function flow.wh_audit(p_actor text, p_action text, p_entity text, p_id text, p_before jsonb, p_after jsonb, p_reason text)
returns void language sql security definer set search_path = flow, public as $$
  insert into flow.audit_log (actor, action, entity, entity_id, before, after, reason) values (p_actor, p_action, p_entity, p_id, p_before, p_after, p_reason)
$$;

create or replace function flow.wh_base_url() returns text language sql stable set search_path = flow, public as $$
  select coalesce((select value #>> '{}' from flow.flow_settings where key = 'labels.base_url'),
                  (select value->>'base_url' from flow.flow_settings where key = 'labels.defaults'), '')
$$;

-- ---------------------------------------------------------------------------
-- Bins
-- ---------------------------------------------------------------------------
create or replace function flow.wh_create_bins(p_zone text, p_prefix text, p_count int, p_type text default 'bin_bay',
                                               p_capacity int default null, p_actor text default 'system')
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_start int; v_made int; v_pfx text := upper(btrim(coalesce(p_prefix, '')));
begin
  if v_pfx !~ '^[A-Z0-9]{1,8}$' then return jsonb_build_object('ok', false, 'error', 'Prefix must be 1–8 letters or digits.'); end if;
  if p_count is null or p_count < 1 or p_count > 200 then return jsonb_build_object('ok', false, 'error', 'Create between 1 and 200 bins at a time.'); end if;
  if p_capacity is not null and p_capacity < 1 then return jsonb_build_object('ok', false, 'error', 'Capacity must be a positive number of units, or blank for no limit.'); end if;
  if not exists (select 1 from flow.bin_zones where code = p_zone and is_active) then return jsonb_build_object('ok', false, 'error', 'Unknown zone ' || coalesce(p_zone, '(none)')); end if;
  select coalesce(max((regexp_match(bin_code, '^' || v_pfx || '-(\d+)$'))[1]::int), 0) + 1 into v_start from flow.bins where bin_code ~ ('^' || v_pfx || '-\d+$');
  v_made := flow.generate_bins(p_zone, v_pfx, p_count, p_type::flow.location_type, p_capacity, v_start);
  perform flow.wh_audit(p_actor, 'bins_created', 'bin', v_pfx, null, jsonb_build_object('zone', p_zone, 'count', v_made, 'first', v_pfx || '-' || lpad(v_start::text, 2, '0'), 'capacity', p_capacity), 'Created ' || v_made || ' bins');
  return jsonb_build_object('ok', true, 'created', v_made, 'first_code', v_pfx || '-' || lpad(v_start::text, 2, '0'));
end $$;

-- Suggest the best bin for an order and say why. Honest about the rules it applied.
create or replace function flow.wh_suggest_bin(p_order uuid, p_units int default null)
returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare o flow.orders; v_units int; v_rules jsonb; v_zone text; v_one boolean; v_best jsonb; v_alts jsonb;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'order not found'); end if;
  v_units := coalesce(p_units, nullif(o.total_units, 0), 1);
  select value into v_rules from flow.flow_settings where key = 'bins.rules';
  v_zone := coalesce(v_rules->>'prefer_zone', 'STG');
  v_one := coalesce((v_rules->>'max_orders_per_bin')::int, 1) <= 1;
  with cand as (
    select b.bin_code, z.code zone_code, b.capacity_units, coalesce(u.units, 0) used, coalesce(u.mine, false) has_mine,
           row_number() over (order by coalesce(u.mine, false) desc, (z.code = v_zone) desc nulls last, (b.capacity_units is null),
                                       b.capacity_units - coalesce(u.units, 0) - v_units, b.bin_code) rn
    from flow.bins b left join flow.bin_zones z on z.id = b.zone_id
    left join (select ba.bin_id, sum(ba.units)::int units, count(*)::int orders, bool_or(ba.order_id = p_order) mine
               from flow.bin_assignments ba where ba.released_at is null group by 1) u on u.bin_id = b.id
    where b.is_active and b.status in ('available', 'allocated')
      and (b.capacity_units is null or coalesce(u.units, 0) + v_units <= b.capacity_units)
      and (not v_one or coalesce(u.orders, 0) = 0 or coalesce(u.mine, false)))
  select (select jsonb_build_object('bin_code', c.bin_code, 'zone', c.zone_code, 'free', case when c.capacity_units is null then null else c.capacity_units - c.used end,
            'why', case when c.has_mine then 'Already holds part of this order, so the order stays together.'
                        when c.zone_code = v_zone then 'Free ' || c.zone_code || ' bin with room for ' || v_units || ' units; tightest fit first.'
                        else 'No free ' || v_zone || ' bin fits, so the tightest fit in ' || coalesce(c.zone_code, 'another zone') || '.' end)
          from cand c where c.rn = 1),
         coalesce((select jsonb_agg(jsonb_build_object('bin_code', c.bin_code, 'zone', c.zone_code, 'free', case when c.capacity_units is null then null else c.capacity_units - c.used end) order by c.rn)
                   from cand c where c.rn between 2 and 4), '[]'::jsonb)
    into v_best, v_alts;
  if v_best is null then
    return jsonb_build_object('ok', true, 'suggestion', null, 'alternatives', '[]'::jsonb, 'units', v_units,
      'message', 'No active bin has room for ' || v_units || ' units under the current rules. Create bins or free one up.');
  end if;
  return jsonb_build_object('ok', true, 'suggestion', v_best, 'alternatives', v_alts, 'units', v_units);
end $$;

-- Assign (put away) an order into a bin. Rule breaks need an override with a reason.
create or replace function flow.wh_assign_bin(p_order uuid, p_bin_code text, p_units int, p_actor text default 'system',
                                              p_override boolean default false, p_reason text default null, p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; b flow.bins; v_rules jsonb; v_one boolean; v_used int; v_others int; v_asg flow.bin_assignments; v_warn text[] := '{}'; v_total int; l jsonb;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'order not found'); end if;
  select * into b from flow.bins where bin_code = upper(btrim(p_bin_code));
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'No bin called ' || coalesce(p_bin_code, '(blank)')); end if;
  if p_units is null or p_units < 1 then return jsonb_build_object('ok', false, 'error', 'Enter how many units are going into the bin.'); end if;
  if not b.is_active then return jsonb_build_object('ok', false, 'error', b.bin_code || ' is retired and cannot take stock.'); end if;
  if b.status in ('needs_emptying', 'reserved') and not p_override then return jsonb_build_object('ok', false, 'needs_override', true, 'error', b.bin_code || ' is marked ' || replace(b.status::text, '_', ' ') || '.'); end if;
  select value into v_rules from flow.flow_settings where key = 'bins.rules';
  v_one := coalesce((v_rules->>'max_orders_per_bin')::int, 1) <= 1;
  select coalesce(sum(units), 0)::int, count(*) filter (where order_id <> p_order) into v_used, v_others from flow.bin_assignments where bin_id = b.id and released_at is null;
  if v_one and v_others > 0 then v_warn := v_warn || (b.bin_code || ' already holds another order (rule: one order per bin).'); end if;
  if b.capacity_units is not null and v_used + p_units > b.capacity_units then
    v_warn := v_warn || (b.bin_code || ' would hold ' || (v_used + p_units) || ' units; capacity is ' || b.capacity_units || '.'); end if;
  if array_length(v_warn, 1) > 0 then
    if not coalesce(p_override, false) then return jsonb_build_object('ok', false, 'needs_override', true, 'error', array_to_string(v_warn, ' '), 'warnings', to_jsonb(v_warn)); end if;
    if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'An override needs a reason (at least a few words).'); end if;
  end if;
  insert into flow.bin_assignments (bin_id, order_id, units, assigned_by) values (b.id, p_order, p_units, p_actor)
  on conflict (bin_id, order_id) where released_at is null do update set units = flow.bin_assignments.units + excluded.units
  returning * into v_asg;
  if p_lines is not null and jsonb_typeof(p_lines) = 'array' then
    for l in select * from jsonb_array_elements(p_lines) loop
      if (l->>'qty')::int > 0 then insert into flow.bin_contents (assignment_id, order_line_id, qty) values (v_asg.id, nullif(l->>'order_line_id', '')::uuid, (l->>'qty')::int); end if;
    end loop;
  end if;
  v_total := v_used + p_units;
  update flow.bins set status = case when capacity_units is not null and v_total >= capacity_units then 'full'::flow.bin_status else 'allocated'::flow.bin_status end where id = b.id;
  perform flow.wh_audit(p_actor, case when array_length(v_warn, 1) > 0 then 'bin_assigned_override' else 'bin_assigned' end, 'bin', b.bin_code,
     jsonb_build_object('units_in_bin', v_used), jsonb_build_object('order', o.order_ref, 'units_added', p_units, 'units_in_bin', v_total, 'warnings', to_jsonb(v_warn)), p_reason);
  return jsonb_build_object('ok', true, 'bin_code', b.bin_code, 'order_ref', o.order_ref, 'units_in_bin', v_total, 'overridden', array_length(v_warn, 1) > 0, 'warnings', to_jsonb(v_warn));
end $$;

-- Release an order from a bin (order dispatched, moved, or put back). Never deletes history.
create or replace function flow.wh_release_bin(p_bin_code text, p_order uuid default null, p_actor text default 'system', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare b flow.bins; v_n int; v_units int; v_left int;
begin
  select * into b from flow.bins where bin_code = upper(btrim(p_bin_code));
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'No bin called ' || coalesce(p_bin_code, '(blank)')); end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the bin is being released (for example “dispatched”).'); end if;
  select count(*), coalesce(sum(units), 0) into v_n, v_units from flow.bin_assignments where bin_id = b.id and released_at is null and (p_order is null or order_id = p_order);
  if v_n = 0 then return jsonb_build_object('ok', true, 'released', 0, 'message', b.bin_code || ' had nothing to release.'); end if;
  update flow.bin_assignments set released_at = now() where bin_id = b.id and released_at is null and (p_order is null or order_id = p_order);
  select coalesce(sum(units), 0) into v_left from flow.bin_assignments where bin_id = b.id and released_at is null;
  update flow.bins set status = case when v_left = 0 then (case when status = 'reserved' then 'reserved' else 'available' end)::flow.bin_status
                                      when capacity_units is not null and v_left >= capacity_units then 'full'::flow.bin_status else 'allocated'::flow.bin_status end where id = b.id;
  perform flow.wh_audit(p_actor, case when p_order is null then 'bin_emptied' else 'bin_released' end, 'bin', b.bin_code,
     jsonb_build_object('assignments', v_n, 'units', v_units), jsonb_build_object('units_left', v_left), p_reason);
  return jsonb_build_object('ok', true, 'bin_code', b.bin_code, 'released', v_n, 'units_released', v_units, 'units_left', v_left);
end $$;

-- Move an order from one bin to another in a single audited step.
create or replace function flow.wh_move_order(p_order uuid, p_from text, p_to text, p_actor text default 'system', p_override boolean default false, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_units int; v_res jsonb; fb flow.bins;
begin
  select * into fb from flow.bins where bin_code = upper(btrim(p_from));
  select units into v_units from flow.bin_assignments where bin_id = fb.id and order_id = p_order and released_at is null;
  if v_units is null then return jsonb_build_object('ok', false, 'error', 'That order is not in ' || coalesce(p_from, '(blank)') || '.'); end if;
  v_res := flow.wh_assign_bin(p_order, p_to, v_units, p_actor, p_override, p_reason);
  if not (v_res->>'ok')::boolean then return v_res; end if;
  perform flow.wh_release_bin(p_from, p_order, p_actor, coalesce(nullif(btrim(p_reason), ''), 'Moved to ' || upper(btrim(p_to))));
  return v_res || jsonb_build_object('moved_from', fb.bin_code);
end $$;

create or replace function flow.wh_set_bin_status(p_bin_code text, p_status text, p_actor text default 'system', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare b flow.bins; v_units int;
begin
  select * into b from flow.bins where bin_code = upper(btrim(p_bin_code));
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'No bin called ' || coalesce(p_bin_code, '(blank)')); end if;
  if p_status not in ('available', 'reserved', 'needs_emptying', 'retired') then return jsonb_build_object('ok', false, 'error', 'Status must be available, reserved, needs_emptying or retired.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Give a short reason for the status change.'); end if;
  select coalesce(sum(units), 0) into v_units from flow.bin_assignments where bin_id = b.id and released_at is null;
  if p_status in ('available', 'retired') and v_units > 0 then return jsonb_build_object('ok', false, 'error', b.bin_code || ' still holds ' || v_units || ' units. Release them first.'); end if;
  if p_status = 'retired' then update flow.bins set is_active = false where id = b.id;
  else update flow.bins set status = p_status::flow.bin_status, is_active = true where id = b.id; end if;
  perform flow.wh_audit(p_actor, 'bin_status', 'bin', b.bin_code, jsonb_build_object('status', b.status, 'active', b.is_active), jsonb_build_object('status', p_status), p_reason);
  return jsonb_build_object('ok', true, 'bin_code', b.bin_code, 'status', p_status);
end $$;

create or replace function flow.wh_set_stock_location(p_sku text, p_location text, p_actor text default 'system')
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare s flow.stock_items;
begin
  select * into s from flow.stock_items where sku = btrim(p_sku);
  if s.id is null then return jsonb_build_object('ok', false, 'error', 'No stock item with SKU ' || coalesce(p_sku, '(blank)')); end if;
  update flow.stock_items set storage_location = nullif(btrim(p_location), '') where id = s.id;
  perform flow.wh_audit(p_actor, 'stock_location', 'stock_item', s.sku, jsonb_build_object('location', s.storage_location), jsonb_build_object('location', nullif(btrim(p_location), '')), null);
  return jsonb_build_object('ok', true, 'sku', s.sku, 'location', nullif(btrim(p_location), ''));
end $$;

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------
create or replace function flow.wh_label_payload(p_type text, p_ref text)
returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare o flow.orders; b flow.bins; s flow.stock_items; v_base text := flow.wh_base_url(); v_lines jsonb; v_bins jsonb; v_prio text; m jsonb;
begin
  if p_type in ('order', 'pick', 'dispatch') then
    select * into o from flow.orders where order_ref = p_ref or deco_order_id = p_ref or id::text = p_ref order by (order_ref = p_ref) desc limit 1;
    if o.id is null then return jsonb_build_object('ok', false, 'error', 'order not found: ' || coalesce(p_ref, '')); end if;
    v_prio := case o.priority when 3 then 'CRITICAL' when 2 then 'RUSH' when 1 then 'HIGH' else 'NORMAL' end;
    select coalesce(jsonb_agg(jsonb_build_object('bin_code', x.bin_code, 'units', x.units) order by x.bin_code), '[]'::jsonb) into v_bins
      from (select bn.bin_code, ba.units from flow.bin_assignments ba join flow.bins bn on bn.id = ba.bin_id where ba.order_id = o.id and ba.released_at is null) x;
    select coalesce(jsonb_agg(jsonb_build_object('sku', l.sku, 'product', l.product_name, 'colour', l.colour, 'size', l.size, 'qty', l.qty_required, 'methods', l.decoration_methods, 'placement', l.decoration_placement)
                    order by l.product_name, l.colour, l.size), '[]'::jsonb) into v_lines
      from flow.order_lines l where l.order_id = o.id and l.is_active;
    return jsonb_build_object('ok', true, 'order_id', o.id, 'ref', o.order_ref,
      'qr_payload', case when v_base <> '' then v_base || '/#/orders/' || replace(o.order_ref, '#', '') else 'order:' || o.order_ref end,
      'payload', jsonb_build_object('title', case p_type when 'order' then 'ORDER' when 'pick' then 'PICK LIST' else 'DISPATCH' end,
         'order_ref', o.order_ref, 'customer', o.customer_name, 'due_date', o.due_date::date, 'total_units', o.total_units, 'priority', v_prio,
         'methods', to_jsonb(o.decoration_methods), 'shipping_method', o.shipping_method, 'customer_po', o.customer_po, 'notes', o.production_notes,
         'bins', v_bins, 'lines', v_lines));
  elsif p_type = 'bin' then
    select * into b from flow.bins where bin_code = upper(btrim(p_ref));
    if b.id is null then return jsonb_build_object('ok', false, 'error', 'bin not found: ' || coalesce(p_ref, '')); end if;
    return jsonb_build_object('ok', true, 'bin_id', b.id, 'ref', b.bin_code, 'qr_payload', coalesce(b.qr_value, 'bin:' || b.bin_code),
      'payload', jsonb_build_object('title', 'BIN', 'bin_code', b.bin_code, 'zone', (select code from flow.bin_zones where id = b.zone_id), 'location_type', b.location_type, 'capacity_units', b.capacity_units));
  elsif p_type = 'stock' then
    select * into s from flow.stock_items where sku = btrim(p_ref);
    if s.id is null then return jsonb_build_object('ok', false, 'error', 'stock item not found: ' || coalesce(p_ref, '')); end if;
    return jsonb_build_object('ok', true, 'ref', s.sku, 'qr_payload', 'sku:' || s.sku,
      'payload', jsonb_build_object('title', 'STOCK', 'sku', s.sku, 'product', s.product_name, 'colour', s.colour, 'size', s.size, 'brand', s.brand, 'supplier', s.supplier, 'location', s.storage_location));
  elsif p_type = 'producer' then
    m := flow.tp_label_payloads(p_ref);
    if not coalesce((m->>'ok')::boolean, false) then return m; end if;
    return jsonb_build_object('ok', true, 'ref', p_ref, 'qr_payload', m->>'qr_payload', 'payload', (m->'outbound_label') || jsonb_build_object('title', 'OUTBOUND TO PRODUCER', 'consignment', m->'consignment_label'));
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown label type ' || coalesce(p_type, ''));
end $$;

-- Create or refresh one label. Unchanged content keeps the existing label; changed content that was already printed
-- bumps the version and flags the label (and its order) for reprint.
create or replace function flow.wh_generate_label(p_type text, p_ref text, p_actor text default 'system')
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare g jsonb; l flow.labels; v_oid uuid; v_bid uuid; v_code text; v_ref text; v_state text;
begin
  g := flow.wh_label_payload(p_type, p_ref);
  if not coalesce((g->>'ok')::boolean, false) then return g; end if;
  v_oid := case when p_type in ('order', 'pick', 'dispatch') then (g->>'order_id')::uuid end;
  v_bid := case when p_type = 'bin' then (g->>'bin_id')::uuid end;
  v_ref := case when p_type in ('stock', 'producer') then g->>'ref' end;
  select * into l from flow.labels where label_type = p_type::flow.label_type
     and coalesce(order_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(v_oid, '00000000-0000-0000-0000-000000000000'::uuid)
     and coalesce(bin_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(v_bid, '00000000-0000-0000-0000-000000000000'::uuid)
     and coalesce(ref, '') = coalesce(v_ref, '');
  if l.id is null then
    v_code := upper(left(p_type, 3)) || '-' || upper(replace(replace(coalesce(g->>'ref', ''), '#', ''), ' ', '')) || '-' || to_char(now(), 'YYMMDD');
    if exists (select 1 from flow.labels where label_code = v_code) then v_code := v_code || '-' || substr(gen_random_uuid()::text, 1, 4); end if;
    insert into flow.labels (label_code, label_type, order_id, bin_id, ref, payload, qr_payload) values (v_code, p_type::flow.label_type, v_oid, v_bid, v_ref, g->'payload', g->>'qr_payload')
    returning * into l;
    v_state := 'created';
  elsif l.payload is distinct from (g->'payload') or l.qr_payload is distinct from (g->>'qr_payload') then
    update flow.labels set payload = g->'payload', qr_payload = g->>'qr_payload', version = version + 1,
           print_status = 'pending', updated_at = now() where id = l.id returning * into l;
    v_state := case when l.print_count > 0 then 'changed_reprint_needed' else 'updated' end;
  else
    v_state := 'unchanged';
  end if;
  if v_oid is not null then
    update flow.orders set label_status = case when v_state = 'changed_reprint_needed' then 'reprint_needed'
                                               when label_status in ('none', 'printed') and l.print_status <> 'printed' and v_state in ('created', 'updated') then 'pending' else label_status end
     where id = v_oid;
  end if;
  if v_state <> 'unchanged' then perform flow.wh_audit(p_actor, 'label_' || v_state, 'label', l.label_code, null, jsonb_build_object('type', p_type, 'version', l.version), null); end if;
  return jsonb_build_object('ok', true, 'label_code', l.label_code, 'label_type', p_type, 'state', v_state, 'version', l.version, 'print_status', l.print_status);
end $$;

-- Everything an order needs: order label, pick list and a label for each bin it sits in. Dispatch label on request.
create or replace function flow.wh_generate_order_labels(p_order uuid, p_actor text default 'system', p_include_dispatch boolean default false)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_res jsonb := '[]'::jsonb; r record; t text;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'order not found'); end if;
  foreach t in array case when p_include_dispatch then array['order', 'pick', 'dispatch'] else array['order', 'pick'] end loop
    v_res := v_res || jsonb_build_array(flow.wh_generate_label(t, o.order_ref, p_actor));
  end loop;
  for r in select distinct bn.bin_code from flow.bin_assignments ba join flow.bins bn on bn.id = ba.bin_id where ba.order_id = o.id and ba.released_at is null loop
    v_res := v_res || jsonb_build_array(flow.wh_generate_label('bin', r.bin_code, p_actor));
  end loop;
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'labels', v_res);
end $$;

create or replace function flow.wh_generate_labels_batch(p_type text, p_refs text[], p_actor text default 'system')
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_res jsonb := '[]'::jsonb; x text;
begin
  if p_refs is null or cardinality(p_refs) = 0 then return jsonb_build_object('ok', false, 'error', 'Pick at least one item.'); end if;
  if cardinality(p_refs) > 200 then return jsonb_build_object('ok', false, 'error', 'Batch is limited to 200 labels.'); end if;
  foreach x in array p_refs loop v_res := v_res || jsonb_build_array(jsonb_build_object('ref', x) || flow.wh_generate_label(p_type, x, p_actor)); end loop;
  return jsonb_build_object('ok', true, 'results', v_res, 'created', (select count(*) from jsonb_array_elements(v_res) e where e->>'state' = 'created'),
                            'failed', (select count(*) from jsonb_array_elements(v_res) e where not (e->>'ok')::boolean));
end $$;

-- Record that labels were sent to a printer. Printing a label that was already printed is a reprint and needs a reason.
create or replace function flow.wh_mark_printed(p_codes text[], p_actor text default 'system', p_reason text default null, p_format text default 'A4', p_copies int default 1)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare l flow.labels; v_done int := 0; v_re int := 0; v_missing text[] := '{}'; c text; v_need boolean := false;
begin
  if p_codes is null or cardinality(p_codes) = 0 then return jsonb_build_object('ok', false, 'error', 'No labels selected.'); end if;
  if p_format not in ('A4', 'thermal') then return jsonb_build_object('ok', false, 'error', 'Format must be A4 or thermal.'); end if;
  select bool_or(print_count > 0) into v_need from flow.labels where label_code = any (p_codes) and print_status = 'printed';
  if coalesce(v_need, false) and length(btrim(coalesce(p_reason, ''))) < 3 then
    return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Some of these labels were already printed. Give a reason for reprinting (for example “label damaged”).');
  end if;
  foreach c in array p_codes loop
    select * into l from flow.labels where label_code = c;
    if l.id is null then v_missing := v_missing || c; continue; end if;
    insert into flow.label_prints (label_id, printed_by, reason, format, copies, is_reprint)
      values (l.id, p_actor, nullif(btrim(p_reason), ''), p_format, greatest(coalesce(p_copies, 1), 1), l.print_status = 'printed');
    if l.print_status = 'printed' then v_re := v_re + 1; end if;
    update flow.labels set print_status = 'printed', print_count = print_count + 1, printed_by = p_actor, printed_at = now() where id = l.id;
    if l.bin_id is not null then update flow.bins set label_printed = true where id = l.bin_id; end if;
    if l.order_id is not null then
      update flow.orders o set label_status = 'printed' where o.id = l.order_id
        and not exists (select 1 from flow.labels x where x.order_id = o.id and x.print_status <> 'printed');
    end if;
    v_done := v_done + 1;
  end loop;
  perform flow.wh_audit(p_actor, case when v_re > 0 then 'labels_reprinted' else 'labels_printed' end, 'label', array_to_string(p_codes[1:5], ','), null,
     jsonb_build_object('printed', v_done, 'reprints', v_re, 'format', p_format), p_reason);
  return jsonb_build_object('ok', true, 'printed', v_done, 'reprints', v_re, 'missing', to_jsonb(v_missing));
end $$;

create or replace function flow.wh_mark_print_failed(p_codes text[], p_actor text default 'system', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_n int;
begin
  update flow.labels set print_status = 'failed' where label_code = any (p_codes) and print_status <> 'printed';
  get diagnostics v_n = row_count;
  perform flow.wh_audit(p_actor, 'labels_print_failed', 'label', array_to_string(p_codes[1:5], ','), null, jsonb_build_object('count', v_n), p_reason);
  return jsonb_build_object('ok', true, 'marked', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------
create or replace view flow.v_bin_assignments with (security_invoker = true) as
select ba.id, bn.bin_code, bn.id as bin_id, o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.order_status, ba.units, ba.assigned_at, ba.assigned_by, ba.released_at,
       (ba.released_at is null) as is_active,
       (select coalesce(jsonb_agg(jsonb_build_object('sku', l.sku, 'product', l.product_name, 'colour', l.colour, 'size', l.size, 'qty', c.qty) order by l.sku), '[]'::jsonb)
          from flow.bin_contents c join flow.order_lines l on l.id = c.order_line_id where c.assignment_id = ba.id) as contents
from flow.bin_assignments ba join flow.bins bn on bn.id = ba.bin_id join flow.orders o on o.id = ba.order_id;

-- Orders that have stock secured (or are in progress) but are not in any bin yet.
create or replace view flow.v_orders_to_bin with (security_invoker = true) as
select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.priority, o.order_status, o.total_units,
       (select string_agg(bin_code, ', ') from flow.v_bin_assignments a where a.order_id = o.id and a.is_active) as bins
from flow.orders o
where o.shipped_at is null and o.order_status in ('stock_allocated', 'ready_for_production', 'in_production', 'quality_check', 'ready_for_dispatch')
  and not exists (select 1 from flow.bin_assignments ba where ba.order_id = o.id and ba.released_at is null);

create or replace view public.ui_bin_assignments with (security_invoker = true) as select * from flow.v_bin_assignments;
create or replace view public.ui_orders_to_bin with (security_invoker = true) as select * from flow.v_orders_to_bin;
create or replace view public.ui_label_prints with (security_invoker = true) as
select p.id, l.label_code, l.label_type, o.order_ref, b.bin_code, l.ref, p.printed_by, p.printed_at, p.reason, p.format, p.copies, p.is_reprint
from flow.label_prints p join flow.labels l on l.id = p.label_id left join flow.orders o on o.id = l.order_id left join flow.bins b on b.id = l.bin_id;
create or replace view public.ui_bins with (security_invoker = true) as
select v.*, b.notes, (select max(ba.assigned_at) from flow.bin_assignments ba where ba.bin_id = v.bin_id) as last_activity
from flow.v_bins_live v join flow.bins b on b.id = v.bin_id;
create or replace view public.ui_labels with (security_invoker = true) as
select l.id, l.label_code, l.label_type, l.order_id, o.order_ref, l.bin_id, b.bin_code, l.print_status, l.print_count, l.printed_by, l.printed_at, l.version, l.created_at, l.qr_payload,
       l.payload, l.ref, l.updated_at
from flow.labels l left join flow.orders o on o.id = l.order_id left join flow.bins b on b.id = l.bin_id;
create or replace view public.ui_stock_locations with (security_invoker = true) as
select sku, product_name, colour, size, qty_on_hand, storage_location from flow.stock_items where not is_placeholder;

-- Find anything physical: bin, order, customer, SKU, producer movement, label.
create or replace function public.ui_wh_find(p_q text) returns table (kind text, id text, label text, sub text, route text)
language sql stable security definer set search_path = flow, public as $$
  with q as (select '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pat, length(btrim(p_q)) as n)
  select * from (
    select 'bin', b.bin_code, b.bin_code, coalesce(z.name, '') || ' · ' || b.status::text, '#/warehouse?bin=' || b.bin_code
      from flow.bins b left join flow.bin_zones z on z.id = b.zone_id, q where q.n >= 2 and flow.is_member() and b.bin_code ilike q.pat
    union all
    select 'order in bin', a.order_id::text, a.order_ref || ' → ' || a.bin_code, a.units || ' units · ' || coalesce(a.customer_name, ''), '#/warehouse?bin=' || a.bin_code
      from flow.v_bin_assignments a, q where q.n >= 2 and flow.is_member() and a.is_active and (a.order_ref ilike q.pat or a.customer_name ilike q.pat)
    union all
    select 'sku in bin', l.sku, l.sku || ' → ' || a.bin_code, a.order_ref || ' · ' || (c->>'qty') || ' × ' || coalesce(l.colour, '') || ' ' || coalesce(l.size, ''), '#/warehouse?bin=' || a.bin_code
      from flow.v_bin_assignments a cross join lateral jsonb_array_elements(a.contents) c join flow.order_lines l on l.sku = c->>'sku' and l.order_id = a.order_id, q
      where q.n >= 2 and flow.is_member() and a.is_active and l.sku ilike q.pat
    union all
    select 'stock location', s.sku, s.sku, coalesce(s.storage_location, 'no location set') || ' · ' || s.qty_on_hand || ' on hand', '#/warehouse?q=' || s.sku
      from flow.stock_items s, q where q.n >= 2 and flow.is_member() and s.storage_location is not null and (s.sku ilike q.pat or s.storage_location ilike q.pat)
    union all
    select 'producer movement', m.movement_code, m.movement_code, p.name || ' · ' || m.status::text, '#/producers?q=' || m.movement_code
      from flow.tp_movements m join flow.producers p on p.id = m.producer_id, q where q.n >= 2 and flow.is_member() and m.movement_code ilike q.pat
    union all
    select 'label', l.label_code, l.label_code, l.label_type::text || ' · ' || l.print_status::text, '#/labels?q=' || l.label_code
      from flow.labels l, q where q.n >= 2 and flow.is_member() and l.label_code ilike q.pat
  ) r limit 60
$$;

-- ---------------------------------------------------------------------------
-- Grants. Browser reads views only; every action goes through n8n (service_role wrappers).
-- ---------------------------------------------------------------------------
create or replace function public.flow_wh_create_bins(p_zone text, p_prefix text, p_count int, p_type text, p_capacity int, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_create_bins(p_zone, p_prefix, p_count, p_type, p_capacity, p_actor) $$;
create or replace function public.flow_wh_suggest_bin(p_order uuid, p_units int) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_suggest_bin(p_order, p_units) $$;
create or replace function public.flow_wh_assign_bin(p_order uuid, p_bin_code text, p_units int, p_actor text, p_override boolean, p_reason text, p_lines jsonb) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_assign_bin(p_order, p_bin_code, p_units, p_actor, p_override, p_reason, p_lines) $$;
create or replace function public.flow_wh_release_bin(p_bin_code text, p_order uuid, p_actor text, p_reason text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_release_bin(p_bin_code, p_order, p_actor, p_reason) $$;
create or replace function public.flow_wh_move_order(p_order uuid, p_from text, p_to text, p_actor text, p_override boolean, p_reason text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_move_order(p_order, p_from, p_to, p_actor, p_override, p_reason) $$;
create or replace function public.flow_wh_set_bin_status(p_bin_code text, p_status text, p_actor text, p_reason text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_set_bin_status(p_bin_code, p_status, p_actor, p_reason) $$;
create or replace function public.flow_wh_set_stock_location(p_sku text, p_location text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_set_stock_location(p_sku, p_location, p_actor) $$;
create or replace function public.flow_wh_generate_label(p_type text, p_ref text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_generate_label(p_type, p_ref, p_actor) $$;
create or replace function public.flow_wh_generate_order_labels(p_order uuid, p_actor text, p_include_dispatch boolean) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_generate_order_labels(p_order, p_actor, p_include_dispatch) $$;
create or replace function public.flow_wh_generate_labels_batch(p_type text, p_refs text[], p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_generate_labels_batch(p_type, p_refs, p_actor) $$;
create or replace function public.flow_wh_mark_printed(p_codes text[], p_actor text, p_reason text, p_format text, p_copies int) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_mark_printed(p_codes, p_actor, p_reason, p_format, p_copies) $$;
create or replace function public.flow_wh_mark_print_failed(p_codes text[], p_actor text, p_reason text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.wh_mark_print_failed(p_codes, p_actor, p_reason) $$;

do $$
declare f text; v text;
begin
  foreach f in array array['public.flow_wh_create_bins(text,text,int,text,int,text)', 'public.flow_wh_suggest_bin(uuid,int)',
    'public.flow_wh_assign_bin(uuid,text,int,text,boolean,text,jsonb)', 'public.flow_wh_release_bin(text,uuid,text,text)',
    'public.flow_wh_move_order(uuid,text,text,text,boolean,text)', 'public.flow_wh_set_bin_status(text,text,text,text)',
    'public.flow_wh_set_stock_location(text,text,text)', 'public.flow_wh_generate_label(text,text,text)',
    'public.flow_wh_generate_order_labels(uuid,text,boolean)', 'public.flow_wh_generate_labels_batch(text,text[],text)',
    'public.flow_wh_mark_printed(text[],text,text,text,int)', 'public.flow_wh_mark_print_failed(text[],text,text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['flow.wh_audit(text,text,text,text,jsonb,jsonb,text)', 'flow.wh_create_bins(text,text,int,text,int,text)', 'flow.wh_suggest_bin(uuid,int)',
    'flow.wh_assign_bin(uuid,text,int,text,boolean,text,jsonb)', 'flow.wh_release_bin(text,uuid,text,text)', 'flow.wh_move_order(uuid,text,text,text,boolean,text)',
    'flow.wh_set_bin_status(text,text,text,text)', 'flow.wh_set_stock_location(text,text,text)', 'flow.wh_label_payload(text,text)', 'flow.wh_generate_label(text,text,text)',
    'flow.wh_generate_order_labels(uuid,text,boolean)', 'flow.wh_generate_labels_batch(text,text[],text)', 'flow.wh_mark_printed(text[],text,text,text,int)',
    'flow.wh_mark_print_failed(text[],text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach v in array array['ui_bin_assignments', 'ui_orders_to_bin', 'ui_label_prints', 'ui_bins', 'ui_labels', 'ui_stock_locations'] loop
    execute format('revoke all on public.%I from public, anon', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
revoke all on function public.ui_wh_find(text) from public, anon;
grant execute on function public.ui_wh_find(text) to authenticated;
