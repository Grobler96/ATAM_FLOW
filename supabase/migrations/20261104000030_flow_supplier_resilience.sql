-- Supplier resilience (R5): reliability stats, Approved Alternatives, shortage advice, and chase drafts for late POs.
-- Everything that sends a message goes through the existing review-first communications queue.

-- ---------------------------------------------------------------------------
-- Reliability stats (also feeds suppliers.on_time_rate, which the selection engine already reads)
-- ---------------------------------------------------------------------------
create table flow.supplier_stats (
  supplier_id     uuid primary key references flow.suppliers(id) on delete cascade,
  pos_considered  int not null default 0,
  pos_on_time     int not null default 0,
  pos_late        int not null default 0,
  on_time_rate    numeric(5,2),
  avg_days_late   numeric(5,1),
  open_late       int not null default 0,
  pos_with_issues int not null default 0,
  issue_rate      numeric(5,2),
  refreshed_at    timestamptz not null default now()
);
alter table flow.supplier_stats enable row level security;
create policy supplier_stats_read on flow.supplier_stats for select to authenticated using (flow.is_member());

-- A PO counts once it has been delivered (actual date known) or is already past its expected date. Fewer than 3 counted POs is "not enough history".
create or replace function flow.refresh_supplier_stats() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_n int;
begin
  insert into flow.supplier_stats (supplier_id, pos_considered, pos_on_time, pos_late, on_time_rate, avg_days_late, open_late, pos_with_issues, issue_rate, refreshed_at)
  select s.id, coalesce(c.considered, 0), coalesce(c.on_time, 0), coalesce(c.late, 0),
         case when coalesce(c.considered, 0) >= 3 then round(100.0 * c.on_time / c.considered, 2) end,
         case when coalesce(c.late, 0) > 0 then round(c.days_late::numeric / c.late, 1) end,
         coalesce(c.open_late, 0), coalesce(c.issues, 0),
         case when coalesce(c.considered, 0) >= 3 then round(100.0 * c.issues / c.considered, 2) end, now()
  from flow.suppliers s
  left join lateral (
    select count(*)::int as considered, count(*) filter (where not is_late)::int as on_time, count(*) filter (where is_late)::int as late,
           coalesce(sum(days_late) filter (where is_late), 0)::int as days_late, count(*) filter (where open_late)::int as open_late,
           count(*) filter (where has_issue)::int as issues
    from (
      select (p.actual_delivery is not null and p.actual_delivery > p.expected_date::date) or (p.actual_delivery is null and p.is_active and p.expected_date::date < current_date) as is_late,
             greatest(coalesce(p.actual_delivery, current_date) - p.expected_date::date, 0) as days_late,
             (p.actual_delivery is null and p.is_active and p.expected_date::date < current_date) as open_late,
             exists (select 1 from flow.supplier_discrepancies d where d.po_id = p.id) as has_issue
      from flow.purchase_orders p
      where (p.supplier_ref_id = s.id or (p.supplier_ref_id is null and lower(btrim(p.supplier)) = lower(btrim(s.name)))) and p.expected_date is not null
        and (p.actual_delivery is not null or (p.is_active and p.expected_date::date < current_date))) q) c on true
  on conflict (supplier_id) do update set pos_considered = excluded.pos_considered, pos_on_time = excluded.pos_on_time, pos_late = excluded.pos_late, on_time_rate = excluded.on_time_rate,
    avg_days_late = excluded.avg_days_late, open_late = excluded.open_late, pos_with_issues = excluded.pos_with_issues, issue_rate = excluded.issue_rate, refreshed_at = now();
  update flow.suppliers s set on_time_rate = st.on_time_rate from flow.supplier_stats st where st.supplier_id = s.id and st.on_time_rate is not null and s.on_time_rate is distinct from st.on_time_rate;
  select count(*) into v_n from flow.supplier_stats where pos_considered > 0;
  return jsonb_build_object('ok', true, 'suppliers_with_history', v_n, 'at', now());
end $$;

-- ---------------------------------------------------------------------------
-- Approved alternatives: a SKU that may stand in for another, optionally needing the customer's OK
-- ---------------------------------------------------------------------------
create table flow.approved_alternatives (
  id              uuid primary key default gen_random_uuid(),
  sku             text not null,                 -- the SKU being replaced
  alt_sku         text not null,                 -- the approved stand-in
  needs_customer_ok boolean not null default true,
  notes           text,
  is_active       boolean not null default true,
  created_by      text,
  created_at      timestamptz not null default now(),
  removed_by      text,
  removed_at      timestamptz,
  removed_reason  text,
  check (sku <> alt_sku)
);
create unique index approved_alternatives_pair on flow.approved_alternatives (sku, alt_sku) where is_active;
create index approved_alternatives_sku on flow.approved_alternatives (sku) where is_active;
alter table flow.approved_alternatives enable row level security;
create policy approved_alternatives_read on flow.approved_alternatives for select to authenticated using (flow.is_member());

create or replace function flow.alt_add(p_sku text, p_alt text, p_needs_ok boolean default true, p_notes text default null, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_id uuid; a flow.stock_items;
begin
  if coalesce(btrim(p_sku), '') = '' or coalesce(btrim(p_alt), '') = '' then return jsonb_build_object('ok', false, 'error', 'Both SKUs are required.'); end if;
  if btrim(p_sku) = btrim(p_alt) then return jsonb_build_object('ok', false, 'error', 'A SKU cannot be its own alternative.'); end if;
  select * into a from flow.stock_items where sku = btrim(p_alt);
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'The alternative ' || btrim(p_alt) || ' is not a known stock item.'); end if;
  if a.is_placeholder then return jsonb_build_object('ok', false, 'error', btrim(p_alt) || ' only appears on orders and is not in your inventory, so it cannot be an alternative.'); end if;
  if not exists (select 1 from flow.stock_items where sku = btrim(p_sku)) then return jsonb_build_object('ok', false, 'error', btrim(p_sku) || ' is not a known stock item.'); end if;
  if exists (select 1 from flow.approved_alternatives where sku = btrim(p_sku) and alt_sku = btrim(p_alt) and is_active) then return jsonb_build_object('ok', false, 'error', 'That alternative is already approved.'); end if;
  insert into flow.approved_alternatives (sku, alt_sku, needs_customer_ok, notes, created_by) values (btrim(p_sku), btrim(p_alt), coalesce(p_needs_ok, true), nullif(btrim(coalesce(p_notes, '')), ''), p_actor) returning id into v_id;
  perform flow.wh_audit(p_actor, 'alternative_approved', 'stock_item', btrim(p_sku), null, jsonb_build_object('alt_sku', btrim(p_alt), 'needs_customer_ok', coalesce(p_needs_ok, true)), p_notes);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function flow.alt_remove(p_id uuid, p_actor text, p_reason text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare a flow.approved_alternatives;
begin
  select * into a from flow.approved_alternatives where id = p_id and is_active;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'That alternative is not active.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why this alternative is being withdrawn.'); end if;
  update flow.approved_alternatives set is_active = false, removed_by = p_actor, removed_at = now(), removed_reason = btrim(p_reason) where id = p_id;
  perform flow.wh_audit(p_actor, 'alternative_withdrawn', 'stock_item', a.sku, jsonb_build_object('alt_sku', a.alt_sku), null, p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Shortage advice: wait, substitute, reorder, split or tell the customer, with the reasons
-- ---------------------------------------------------------------------------
create or replace function flow.shortage_advice(p_sku text) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare s record; v_days int; v_incoming jsonb; v_alts jsonb; v_offers jsonb; v_in_cover int := 0; v_alt_free int := 0; v_best jsonb; v_rec jsonb; v_earliest date;
begin
  select * into s from flow.v_shortages where sku = btrim(p_sku);
  if s.sku is null then return jsonb_build_object('ok', false, 'error', 'There is no shortage on ' || coalesce(p_sku, '(blank)') || '.'); end if;
  v_days := s.earliest_due - current_date;

  select coalesce(jsonb_agg(x order by (x->>'expected_date')), '[]'::jsonb) into v_incoming from (
    select jsonb_build_object('po_id', p.id, 'po_ref', coalesce(p.af_po_ref, p.po_number), 'supplier', p.supplier, 'qty', pl.qty_outstanding_eff, 'expected_date', coalesce(pl.expected_date, p.expected_date::date),
             'on_time_rate', st.on_time_rate, 'is_late', coalesce(pl.expected_date, p.expected_date::date) < current_date,
             'before_due', coalesce(pl.expected_date, p.expected_date::date) < s.earliest_due) x
    from flow.po_lines pl join flow.purchase_orders p on p.id = pl.po_id and p.is_active
    left join flow.suppliers su on su.id = p.supplier_ref_id or (p.supplier_ref_id is null and lower(btrim(su.name)) = lower(btrim(p.supplier)))
    left join flow.supplier_stats st on st.supplier_id = su.id
    where pl.sku = s.sku and pl.qty_outstanding_eff > 0) q;
  select coalesce(sum((x->>'qty')::int) filter (where (x->>'before_due')::boolean and not (x->>'is_late')::boolean and coalesce((x->>'on_time_rate')::numeric, 100) >= 70), 0)::int into v_in_cover from jsonb_array_elements(v_incoming) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'alt_sku', a.alt_sku, 'product', si.product_name, 'colour', si.colour, 'size', si.size, 'on_hand', si.qty_on_hand,
           'free', greatest(si.qty_on_hand - coalesce((select sum(al.qty) from flow.allocations al join flow.order_lines ol on ol.id = al.order_line_id where ol.sku = a.alt_sku and al.status = 'active' and al.source = 'on_hand'), 0), 0),
           'needs_customer_ok', a.needs_customer_ok, 'notes', a.notes) order by si.qty_on_hand desc), '[]'::jsonb) into v_alts
    from flow.approved_alternatives a join flow.stock_items si on si.sku = a.alt_sku where a.sku = s.sku and a.is_active;
  select coalesce(sum((x->>'free')::int), 0)::int into v_alt_free from jsonb_array_elements(v_alts) x;

  select coalesce(jsonb_agg(jsonb_build_object('supplier_id', su.id, 'supplier', su.name, 'unit_cost', o.unit_cost, 'lead_days', coalesce(o.lead_time_days, su.lead_time_days), 'min_qty', o.min_qty, 'stock_available', o.stock_available,
           'on_time_rate', su.on_time_rate, 'has_email', su.email is not null,
           'arrives_before_due', (current_date + ceil(coalesce(o.lead_time_days, su.lead_time_days))::int) < s.earliest_due) order by coalesce(o.lead_time_days, su.lead_time_days), o.unit_cost nulls last), '[]'::jsonb) into v_offers
    from flow.supplier_offers o join flow.suppliers su on su.id = o.supplier_id and su.is_active
    where o.sku = s.sku and (o.stock_available is null or o.stock_available >= least(s.units_short, o.min_qty));
  select x into v_best from jsonb_array_elements(v_offers) x where (x->>'arrives_before_due')::boolean order by coalesce((x->>'on_time_rate')::numeric, 50) desc, (x->>'lead_days')::numeric limit 1;

  if v_in_cover >= s.units_short then
    v_rec := jsonb_build_object('action', 'wait', 'text', format('Wait: %s unit(s) are already on order and due before the earliest order is due (%s). No new buying needed. Chase the supplier if it slips.', v_in_cover, to_char(s.earliest_due, 'DD Mon')));
  elsif v_alt_free >= s.units_short then
    v_rec := jsonb_build_object('action', 'substitute', 'text', format('Substitute: approved alternative stock covers the %s short unit(s) now%s.', s.units_short,
      case when exists (select 1 from jsonb_array_elements(v_alts) x where (x->>'needs_customer_ok')::boolean and (x->>'free')::int > 0) then ' (the customer must agree to the swap first)' else '' end));
  elsif v_best is not null then
    v_rec := jsonb_build_object('action', 'reorder', 'text', format('Reorder %s from %s: lead time %s day(s)%s, lands before the earliest due date (%s).', s.units_short, v_best->>'supplier', v_best->>'lead_days',
      case when (v_best->>'on_time_rate') is not null then format(', on time %s%% of the time', v_best->>'on_time_rate') else ', no delivery history yet' end, to_char(s.earliest_due, 'DD Mon')),
      'supplier_id', v_best->>'supplier_id');
  elsif v_in_cover + v_alt_free > 0 then
    v_rec := jsonb_build_object('action', 'split', 'text', format('Split: %s unit(s) can be covered by incoming stock and %s by alternatives; the rest needs a new supplier or a later date. Agree a split shipment with the customer.', v_in_cover, v_alt_free));
  else
    select min(d) into v_earliest from (select (x->>'expected_date')::date d from jsonb_array_elements(v_incoming) x union all select current_date + ceil((x->>'lead_days')::numeric)::int from jsonb_array_elements(v_offers) x) z;
    v_rec := jsonb_build_object('action', 'tell_customer', 'text', case when v_earliest is not null then format('Tell the customer: nothing covers this before it is due (%s). The earliest stock could be here is about %s.', to_char(s.earliest_due, 'DD Mon'), to_char(v_earliest, 'DD Mon'))
                                                              else 'Tell the customer: nothing is on order, no approved alternative has stock and no supplier is set up for this SKU. Add a supplier offer or an approved alternative, or agree a new date.' end);
  end if;
  return jsonb_build_object('ok', true, 'sku', s.sku, 'product', s.product_name, 'colour', s.colour, 'size', s.size, 'units_short', s.units_short, 'units_demanded', s.units_demanded,
    'orders_affected', s.orders_affected, 'order_refs', to_jsonb(s.order_refs), 'earliest_due', s.earliest_due, 'days_to_due', v_days, 'on_hand', s.on_hand, 'on_order', s.on_order,
    'incoming', v_incoming, 'alternatives', v_alts, 'offers', v_offers, 'recommendation', v_rec);
end $$;

-- ---------------------------------------------------------------------------
-- Chase a supplier about a late or unacknowledged PO. Creates a draft in the review queue; sends nothing itself.
-- ---------------------------------------------------------------------------
create or replace function flow.po_chase_draft(p_po uuid, p_actor text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.purchase_orders; su flow.suppliers; v_ref text; v_lines text; v_set jsonb := coalesce(flow.setting('comms.settings'), '{}'::jsonb); v_days int; v_body text; v_id uuid; v_subject text; v_out int; v_kind text;
begin
  select * into p from flow.purchase_orders where id = p_po;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'Purchase order not found.'); end if;
  if not p.is_active then return jsonb_build_object('ok', false, 'error', 'That purchase order has nothing outstanding.'); end if;
  v_ref := coalesce(p.af_po_ref, p.po_number);
  select * into su from flow.suppliers where id = p.supplier_ref_id or (p.supplier_ref_id is null and lower(btrim(name)) = lower(btrim(p.supplier))) limit 1;
  v_days := greatest(current_date - p.expected_date::date, 0);
  v_kind := case when p.expected_date::date < current_date then 'late' when p.po_status = 'sent' and p.sent_at < now() - interval '24 hours' and p.acknowledged_at is null then 'unacknowledged' end;
  if v_kind is null then return jsonb_build_object('ok', false, 'error', v_ref || ' is not late and has been acknowledged (or was sent less than a day ago), so there is nothing to chase.'); end if;
  if exists (select 1 from flow.communications c where c.entity_type = 'po' and c.entity_id = p.id and c.kind = 'other' and c.subject like 'Chase:%' and c.status in ('draft', 'pending_review', 'approved', 'sending')) then
    return jsonb_build_object('ok', true, 'already_queued', true, 'message', 'A chase for ' || v_ref || ' is already waiting in the review queue.');
  end if;
  if exists (select 1 from flow.communications c where c.entity_type = 'po' and c.entity_id = p.id and c.kind = 'other' and c.subject like 'Chase:%' and c.status = 'sent' and c.sent_at > now() - interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', v_ref || ' was chased less than 24 hours ago. Give the supplier time to answer.');
  end if;
  select string_agg(format('  - %s x %s%s', pl.qty_outstanding_eff, pl.sku, coalesce(' (' || nullif(concat_ws(' ', pl.colour, pl.size), '') || ')', '')), E'\n' order by pl.line_no) into v_lines
    from flow.po_lines pl where pl.po_id = p.id and pl.qty_outstanding_eff > 0;
  select coalesce(sum(qty_outstanding_eff), 0) into v_out from flow.po_lines where po_id = p.id;
  v_subject := format('Chase: purchase order %s%s', v_ref, case when v_kind = 'late' then format(' (%s day%s overdue)', v_days, case when v_days = 1 then '' else 's' end) else ' (please confirm)' end);
  v_body := format(E'Hello%s,\n\n%s\n\nStill outstanding on %s (%s unit(s)):\n%s\n\nCould you please reply today with:\n  1. a confirmed dispatch or delivery date,\n  2. the tracking reference if it has shipped,\n  3. anything you cannot supply, so we can plan around it.\n\nThank you,\n%s',
    coalesce(' ' || su.contact_name, ''),
    case when v_kind = 'late' then format('Our order %s was due on %s and we have not yet received all of it.', v_ref, to_char(p.expected_date, 'DD Mon YYYY')) else format('We sent order %s on %s and have not had an acknowledgement.', v_ref, to_char(p.sent_at, 'DD Mon YYYY')) end,
    v_ref, v_out, coalesce(v_lines, '  (see the purchase order)'), coalesce(v_set->>'signature', 'ATAM FLOW Production Control'));
  v_id := flow.queue_comm('other', case when su.email is not null then array[su.email] else '{}'::text[] end, v_subject, v_body, null, 'po', p.id, su.id, null, p_actor);
  perform flow.wh_audit(p_actor, 'po_chase_drafted', 'purchase_order', v_ref, null, jsonb_build_object('comm_id', v_id, 'reason', v_kind), null);
  return jsonb_build_object('ok', true, 'comm_id', v_id, 'po_ref', v_ref, 'no_recipient', su.email is null or su.id is null, 'reason', v_kind);
end $$;

-- Draft a chase for every PO that is at least p_min_days overdue (or sent and unacknowledged). Drafts only: a person approves each one.
create or replace function flow.po_chase_all_late(p_actor text default 'system', p_min_days int default 2) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r record; v_res jsonb; v_made int := 0; v_skipped int := 0; v_queued int := 0; v_norecip int := 0;
begin
  for r in select p.id from flow.purchase_orders p where p.is_active and ((p.expected_date::date <= current_date - greatest(coalesce(p_min_days, 2), 1)) or (p.po_status = 'sent' and p.acknowledged_at is null and p.sent_at < now() - interval '24 hours'))
           order by p.expected_date loop
    v_res := flow.po_chase_draft(r.id, p_actor);
    if coalesce((v_res->>'already_queued')::boolean, false) then v_queued := v_queued + 1;
    elsif (v_res->>'ok')::boolean then v_made := v_made + 1; if coalesce((v_res->>'no_recipient')::boolean, false) then v_norecip := v_norecip + 1; end if;
    else v_skipped := v_skipped + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'drafted', v_made, 'already_queued', v_queued, 'skipped', v_skipped, 'without_recipient', v_norecip);
end $$;

-- ---------------------------------------------------------------------------
-- Read models, wrappers and grants
-- ---------------------------------------------------------------------------
create or replace view public.ui_suppliers with (security_invoker = true) as
  select s.id, s.code, s.name, s.email, s.phone, s.contact_name, s.lead_time_days, s.delivery_cost, s.free_delivery_over, s.min_order_value, s.payment_terms, s.can_deliver_to_producer, s.quality_rating, s.on_time_rate, s.is_active,
         coalesce(st.pos_considered, 0) as pos_considered, coalesce(st.pos_late, 0) as pos_late, st.avg_days_late, coalesce(st.open_late, 0) as open_late, st.issue_rate, st.refreshed_at as stats_at
  from flow.suppliers s left join flow.supplier_stats st on st.supplier_id = s.id;
create or replace view public.ui_approved_alternatives with (security_invoker = true) as
select a.id, a.sku, a.alt_sku, si.product_name as alt_product, si.colour as alt_colour, si.size as alt_size, si.qty_on_hand as alt_on_hand, a.needs_customer_ok, a.notes, a.created_by, a.created_at
from flow.approved_alternatives a left join flow.stock_items si on si.sku = a.alt_sku where a.is_active;

create or replace function public.ui_shortage_advice(p_sku text) returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when flow.is_member() then flow.shortage_advice(p_sku) else '{}'::jsonb end $$;
create or replace function public.flow_refresh_supplier_stats() returns jsonb language sql security definer set search_path = flow, public as $$ select flow.refresh_supplier_stats() $$;
create or replace function public.flow_alt_add(p_sku text, p_alt text, p_needs_ok boolean, p_notes text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.alt_add(p_sku, p_alt, p_needs_ok, p_notes, p_actor) $$;
create or replace function public.flow_alt_remove(p_id uuid, p_actor text, p_reason text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.alt_remove(p_id, p_actor, p_reason) $$;
create or replace function public.flow_po_chase_draft(p_po uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_chase_draft(p_po, p_actor) $$;
create or replace function public.flow_po_chase_all_late(p_actor text, p_min_days int) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_chase_all_late(p_actor, p_min_days) $$;

do $$
declare f text; v text;
begin
  foreach f in array array['public.flow_refresh_supplier_stats()', 'public.flow_alt_add(text,text,boolean,text,text)', 'public.flow_alt_remove(uuid,text,text)', 'public.flow_po_chase_draft(uuid,text)', 'public.flow_po_chase_all_late(text,int)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.refresh_supplier_stats()', 'flow.alt_add(text,text,boolean,text,text)', 'flow.alt_remove(uuid,text,text)', 'flow.shortage_advice(text)', 'flow.po_chase_draft(uuid,text)', 'flow.po_chase_all_late(text,int)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach v in array array['ui_approved_alternatives', 'ui_suppliers'] loop
    execute format('revoke all on public.%I from public, anon', v); execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
revoke all on function public.ui_shortage_advice(text) from public, anon;
grant execute on function public.ui_shortage_advice(text) to authenticated;
