-- Waste and loss ledger. Kept separate from stock because DecoNetwork overwrites stock on every sync.
-- Capture (manual or suggested by the system and confirmed by a person), approval above a threshold, recovery from a decorator,
-- supplier or courier, a waste-rate target per decorator, and an exception when a rate or an approval is overdue.
create sequence if not exists flow.waste_seq;

create table if not exists flow.waste_causes (
  code text primary key, label text not null, default_party text not null check (default_party in ('us','decorator','supplier','courier','artwork','customer')),
  is_active boolean not null default true, sort_order int not null default 0
);
insert into flow.waste_causes (code, label, default_party, sort_order) values
 ('damaged_in_handling', 'Damaged in handling', 'us', 10), ('stain_or_mark', 'Stain or mark', 'us', 20),
 ('wrong_decoration', 'Wrong or poor decoration', 'us', 30), ('misprint', 'Misprint or machine fault', 'us', 40),
 ('artwork_error', 'Artwork error', 'artwork', 50), ('supplier_fault', 'Faulty from supplier', 'supplier', 60),
 ('decorator_spoilage', 'Spoiled by decorator', 'decorator', 70), ('courier_lost', 'Lost by courier', 'courier', 80),
 ('courier_damaged', 'Damaged by courier', 'courier', 90), ('customer_change', 'Customer changed or cancelled', 'customer', 100),
 ('other', 'Other (say why)', 'us', 999)
on conflict (code) do nothing;

create table if not exists flow.waste_events (
  id uuid primary key default gen_random_uuid(),
  waste_ref text not null unique,
  occurred_at timestamptz not null default now(),
  stage text not null check (stage in ('warehouse', 'in_house', 'decorator', 'qc', 'courier')),
  cause_code text not null references flow.waste_causes(code),
  party text not null check (party in ('us', 'decorator', 'supplier', 'courier', 'artwork', 'customer')),
  qty int not null check (qty > 0),
  sku text, product_name text,
  unit_cost numeric(12,4) not null default 0,
  value numeric(12,2) generated always as (round(qty * unit_cost, 2)) stored,
  order_id uuid references flow.orders(id), order_ref text,
  producer_id uuid references flow.producers(id),
  movement_id uuid references flow.tp_movements(id),
  machine_id uuid references flow.machines(id),
  operator_id uuid references flow.operators(id),
  source text not null default 'manual' check (source in ('manual', 'qc', 'receipt', 'courier')),
  source_key text unique,                       -- makes automatic suggestions idempotent
  status text not null default 'pending_approval' check (status in ('suggested', 'pending_approval', 'approved', 'rejected')),
  reason text not null,
  evidence_path text,
  recorded_by text, approved_by text, decided_at timestamptz, decision_note text,
  replacement_requested boolean not null default false,
  recovered_value numeric(12,2) not null default 0 check (recovered_value >= 0),
  claim_ref text, recovery_note text,
  created_at timestamptz not null default now()
);
create index if not exists waste_events_when on flow.waste_events (occurred_at desc);
create index if not exists waste_events_producer on flow.waste_events (producer_id) where producer_id is not null;
alter table flow.waste_causes enable row level security;
alter table flow.waste_events enable row level security;
create policy waste_causes_read on flow.waste_causes for select to authenticated using (flow.is_member());
create policy waste_events_read on flow.waste_events for select to authenticated using (flow.is_member());

insert into flow.flow_settings (key, value) values
 ('waste.approval', '{"value_over": 100, "units_over": 25}'::jsonb),
 ('waste.targets', '{"default_rate_pct": 3, "min_units": 50, "window_days": 90}'::jsonb)
on conflict (key) do nothing;

-- Cost per unit from the stock cost table (0 when the SKU has no cost, which the screen flags).
create or replace function flow.waste_cost(p_sku text) returns numeric language plpgsql stable security definer set search_path = flow, public as $$
declare v numeric;
begin
  if p_sku is null then return 0; end if;
  begin execute 'select unit_cost from public.sku_costs where sku = $1' using p_sku into v;
  exception when others then v := null; end;
  return coalesce(v, 0);
end $$;

create or replace function flow.waste_needs_approval(p_qty int, p_value numeric) returns boolean language sql stable security definer set search_path = flow, public as $$
  select p_qty > coalesce((select (value->>'units_over')::numeric from flow.flow_settings where key = 'waste.approval'), 25)
      or p_value > coalesce((select (value->>'value_over')::numeric from flow.flow_settings where key = 'waste.approval'), 100)
$$;

-- p: {stage, cause, qty, sku?, product_name?, order_ref?, producer_code?, movement_code?, machine_code?, operator_name?, reason, occurred_at?, evidence_path?, unit_cost?, replacement?}
create or replace function flow.waste_record(p jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.waste_causes; o flow.orders; pr flow.producers; mv flow.tp_movements; mc flow.machines; op flow.operators;
        v_qty int; v_cost numeric; v_ref text; v_status text; v_id uuid; v_party text;
begin
  select * into c from flow.waste_causes where code = p->>'cause' and is_active;
  if c.code is null then return jsonb_build_object('ok', false, 'error', 'Pick a cause.'); end if;
  if coalesce(p->>'stage', '') not in ('warehouse', 'in_house', 'decorator', 'qc', 'courier') then return jsonb_build_object('ok', false, 'error', 'Pick where it happened.'); end if;
  v_qty := nullif(p->>'qty', '')::int;
  if v_qty is null or v_qty <= 0 then return jsonb_build_object('ok', false, 'error', 'Enter how many units.'); end if;
  if length(btrim(coalesce(p->>'reason', ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what happened (at least a few words).'); end if;
  if nullif(p->>'order_ref', '') is not null then
    select * into o from flow.orders where order_ref = btrim(p->>'order_ref');
    if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order ' || (p->>'order_ref') || ' was not found.'); end if;
  end if;
  if nullif(p->>'producer_code', '') is not null then
    select * into pr from flow.producers where code = p->>'producer_code';
    if pr.id is null then return jsonb_build_object('ok', false, 'error', 'Decorator not found.'); end if;
  end if;
  if nullif(p->>'movement_code', '') is not null then
    select * into mv from flow.tp_movements where movement_code = p->>'movement_code';
    if mv.id is null then return jsonb_build_object('ok', false, 'error', 'Consignment not found.'); end if;
    if pr.id is null then select * into pr from flow.producers where id = mv.producer_id; end if;
  end if;
  if nullif(p->>'machine_code', '') is not null then
    select * into mc from flow.machines where code = p->>'machine_code';
    if mc.id is null then return jsonb_build_object('ok', false, 'error', 'Machine not found.'); end if;
  end if;
  if nullif(p->>'operator_name', '') is not null then
    select * into op from flow.operators where lower(name) = lower(p->>'operator_name');
    if op.id is null then return jsonb_build_object('ok', false, 'error', 'Operator not found.'); end if;
  end if;
  v_cost := coalesce(nullif(p->>'unit_cost', '')::numeric, flow.waste_cost(nullif(p->>'sku', '')));
  v_party := coalesce(nullif(p->>'party', ''), c.default_party);
  if v_party not in ('us', 'decorator', 'supplier', 'courier', 'artwork', 'customer') then return jsonb_build_object('ok', false, 'error', 'Pick who was responsible.'); end if;
  v_status := case when flow.waste_needs_approval(v_qty, round(v_qty * v_cost, 2)) then 'pending_approval' else 'approved' end;
  v_ref := 'WST-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('flow.waste_seq')::text, 4, '0');
  insert into flow.waste_events (waste_ref, occurred_at, stage, cause_code, party, qty, sku, product_name, unit_cost, order_id, order_ref, producer_id, movement_id, machine_id, operator_id,
      source, status, reason, evidence_path, recorded_by, approved_by, decided_at, replacement_requested)
  values (v_ref, coalesce(nullif(p->>'occurred_at', '')::timestamptz, now()), p->>'stage', c.code, v_party, v_qty, nullif(p->>'sku', ''), nullif(p->>'product_name', ''), v_cost, o.id, o.order_ref, pr.id, mv.id, mc.id, op.id,
      'manual', v_status, btrim(p->>'reason'), nullif(p->>'evidence_path', ''), p_actor, case when v_status = 'approved' then p_actor end, case when v_status = 'approved' then now() end,
      coalesce((p->>'replacement')::boolean, false))
  returning id into v_id;
  perform flow.wh_audit(p_actor, 'waste_recorded', 'waste', v_ref, null, jsonb_build_object('qty', v_qty, 'cause', c.code, 'stage', p->>'stage', 'status', v_status, 'value', round(v_qty * v_cost, 2)), p->>'reason');
  return jsonb_build_object('ok', true, 'waste_ref', v_ref, 'status', v_status, 'needs_approval', v_status = 'pending_approval', 'value', round(v_qty * v_cost, 2), 'no_cost', v_cost = 0);
end $$;

-- A person confirms a system suggestion (it then follows the normal approval rule) or dismisses it.
create or replace function flow.waste_confirm(p_ref text, p_confirm boolean, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare w flow.waste_events; v_status text;
begin
  select * into w from flow.waste_events where waste_ref = p_ref;
  if w.id is null then return jsonb_build_object('ok', false, 'error', 'Waste record not found.'); end if;
  if w.status <> 'suggested' then return jsonb_build_object('ok', false, 'error', 'That record is not a suggestion.'); end if;
  if not p_confirm and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why this is not waste (at least a few words).'); end if;
  v_status := case when not p_confirm then 'rejected' when flow.waste_needs_approval(w.qty, w.value) then 'pending_approval' else 'approved' end;
  update flow.waste_events set status = v_status, decision_note = nullif(btrim(coalesce(p_note, '')), ''),
      approved_by = case when v_status = 'approved' then p_actor end, decided_at = case when v_status in ('approved', 'rejected') then now() end where id = w.id;
  perform flow.wh_audit(p_actor, case when p_confirm then 'waste_confirmed' else 'waste_dismissed' end, 'waste', w.waste_ref, jsonb_build_object('status', w.status), jsonb_build_object('status', v_status), p_note);
  return jsonb_build_object('ok', true, 'waste_ref', w.waste_ref, 'status', v_status);
end $$;

-- Manager decision on a record waiting for approval. Rejecting needs a reason.
create or replace function flow.waste_decide(p_ref text, p_approve boolean, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare w flow.waste_events;
begin
  select * into w from flow.waste_events where waste_ref = p_ref;
  if w.id is null then return jsonb_build_object('ok', false, 'error', 'Waste record not found.'); end if;
  if w.status <> 'pending_approval' then return jsonb_build_object('ok', false, 'error', 'That record is not waiting for approval.'); end if;
  if not p_approve and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why it is rejected (at least a few words).'); end if;
  update flow.waste_events set status = case when p_approve then 'approved' else 'rejected' end, approved_by = p_actor, decided_at = now(), decision_note = nullif(btrim(coalesce(p_note, '')), '') where id = w.id;
  perform flow.wh_audit(p_actor, case when p_approve then 'waste_approved' else 'waste_rejected' end, 'waste', w.waste_ref, jsonb_build_object('status', w.status), jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end), p_note);
  return jsonb_build_object('ok', true, 'waste_ref', w.waste_ref);
end $$;

-- Money got back from a decorator, supplier or courier, optionally against a claim.
create or replace function flow.waste_recover(p_ref text, p_amount numeric, p_claim text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare w flow.waste_events;
begin
  select * into w from flow.waste_events where waste_ref = p_ref;
  if w.id is null then return jsonb_build_object('ok', false, 'error', 'Waste record not found.'); end if;
  if w.status <> 'approved' then return jsonb_build_object('ok', false, 'error', 'Only approved waste can have a recovery recorded.'); end if;
  if p_amount is null or p_amount < 0 then return jsonb_build_object('ok', false, 'error', 'Enter the amount recovered.'); end if;
  if p_amount > w.value then return jsonb_build_object('ok', false, 'error', 'The recovery cannot be more than the waste value (£' || w.value || ').'); end if;
  if nullif(btrim(coalesce(p_claim, '')), '') is not null and not exists (select 1 from flow.courier_claims where claim_ref = btrim(p_claim)) then
    return jsonb_build_object('ok', false, 'error', 'Claim ' || p_claim || ' was not found.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say where the money came from (at least a few words).'); end if;
  update flow.waste_events set recovered_value = p_amount, claim_ref = coalesce(nullif(btrim(coalesce(p_claim, '')), ''), claim_ref), recovery_note = btrim(p_note) where id = w.id;
  perform flow.wh_audit(p_actor, 'waste_recovered', 'waste', w.waste_ref, jsonb_build_object('recovered', w.recovered_value), jsonb_build_object('recovered', p_amount, 'claim', p_claim), p_note);
  return jsonb_build_object('ok', true, 'waste_ref', w.waste_ref);
end $$;

-- Ask for replacement stock for the order the waste came from.
create or replace function flow.waste_replacement(p_ref text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare w flow.waste_events;
begin
  select * into w from flow.waste_events where waste_ref = p_ref;
  if w.id is null then return jsonb_build_object('ok', false, 'error', 'Waste record not found.'); end if;
  if w.status not in ('pending_approval', 'approved') then return jsonb_build_object('ok', false, 'error', 'Only live waste records can ask for a replacement.'); end if;
  if w.order_id is null then return jsonb_build_object('ok', false, 'error', 'This record is not linked to an order, so there is nothing to replace.'); end if;
  if w.replacement_requested then return jsonb_build_object('ok', false, 'error', 'A replacement was already requested.'); end if;
  update flow.waste_events set replacement_requested = true where id = w.id;
  perform flow.wh_audit(p_actor, 'waste_replacement_requested', 'order', w.order_ref, null, jsonb_build_object('waste', w.waste_ref, 'qty', w.qty, 'sku', w.sku), null);
  return jsonb_build_object('ok', true, 'order_ref', w.order_ref);
end $$;

-- System suggestions from things already recorded. Nothing counts as waste until a person confirms it. Safe to run any number of times.
create or replace function flow.waste_suggest() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare n_qc int := 0; n_rc int := 0; n_cr int := 0;
begin
  with ins as (
    insert into flow.waste_events (waste_ref, occurred_at, stage, cause_code, party, qty, sku, unit_cost, order_id, order_ref, producer_id, movement_id, source, source_key, status, reason, recorded_by)
    select 'WST-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('flow.waste_seq')::text, 4, '0'), coalesce(r.completed_at, r.created_at), case when r.producer_id is not null then 'decorator' else 'qc' end,
           case r.cause when 'producer' then 'decorator_spoilage' when 'supplier' then 'supplier_fault' when 'artwork' then 'artwork_error' when 'operator' then 'wrong_decoration' when 'machine' then 'misprint' else 'other' end,
           case r.cause when 'producer' then 'decorator' when 'supplier' then 'supplier' when 'artwork' then 'artwork' else 'us' end,
           r.units_scrapped, l.sku, flow.waste_cost(l.sku), r.order_id, o.order_ref, r.producer_id, r.movement_id, 'qc', 'qc:' || r.id, 'suggested',
           'Scrapped in rework ' || r.rework_ref || ' (' || r.defect_type || ')', 'system'
    from flow.rework_jobs r join flow.orders o on o.id = r.order_id left join flow.order_lines l on l.id = r.order_line_id
    where r.units_scrapped > 0
    on conflict (source_key) do nothing returning 1) select count(*) into n_qc from ins;
  with ins as (
    insert into flow.waste_events (waste_ref, occurred_at, stage, cause_code, party, qty, sku, unit_cost, order_id, order_ref, producer_id, movement_id, source, source_key, status, reason, recorded_by)
    select 'WST-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('flow.waste_seq')::text, 4, '0'), t.received_at, 'decorator', 'decorator_spoilage', 'decorator', t.qty_damaged, i.sku, flow.waste_cost(i.sku),
           i.order_id, o.order_ref, m.producer_id, m.id, 'receipt', 'receipt:' || t.id, 'suggested',
           'Decorator reported ' || t.qty_damaged || ' damaged on check-in of ' || m.movement_code || coalesce(' (' || t.note || ')', ''), 'system'
    from flow.tp_receipts t join flow.tp_movements m on m.id = t.movement_id join flow.tp_movement_items i on i.id = t.item_id join flow.orders o on o.id = i.order_id
    where t.qty_damaged > 0
    on conflict (source_key) do nothing returning 1) select count(*) into n_rc from ins;
  with ins as (
    insert into flow.waste_events (waste_ref, occurred_at, stage, cause_code, party, qty, sku, unit_cost, order_id, order_ref, producer_id, movement_id, source, source_key, status, reason, recorded_by)
    select 'WST-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('flow.waste_seq')::text, 4, '0'), c.opened_at, 'courier', case c.kind when 'lost' then 'courier_lost' else 'courier_damaged' end, 'courier',
           greatest((select coalesce(sum(i.qty_sent), 1) from flow.tp_movement_items i where i.movement_id = c.movement_id), 1), null,
           round(coalesce(c.value_claimed, 0) / greatest((select coalesce(sum(i.qty_sent), 1) from flow.tp_movement_items i where i.movement_id = c.movement_id), 1), 4),
           null, null, m.producer_id, m.id, 'courier', 'claim:' || c.id, 'suggested', 'Courier claim ' || c.claim_ref || ' (' || c.kind || ')' || coalesce(': ' || c.note, ''), 'system'
    from flow.courier_claims c join flow.tp_movements m on m.id = c.movement_id
    where c.kind in ('lost', 'damaged') and coalesce(c.value_claimed, 0) > 0
    on conflict (source_key) do nothing returning 1) select count(*) into n_cr from ins;
  return jsonb_build_object('qc', n_qc, 'receipts', n_rc, 'courier', n_cr);
end $$;

-- Waste per decorator against units sent, over the configured window.
create or replace view flow.v_waste_rates with (security_invoker = true) as
with cfg as (
  select coalesce((select (value->>'window_days')::int from flow.flow_settings where key = 'waste.targets'), 90) as win,
         coalesce((select (value->>'default_rate_pct')::numeric from flow.flow_settings where key = 'waste.targets'), 3) as target,
         coalesce((select (value->>'min_units')::int from flow.flow_settings where key = 'waste.targets'), 50) as min_units
), sent as (
  select m.producer_id, sum(i.qty_sent)::int as units_sent
  from flow.tp_movements m join flow.tp_movement_items i on i.movement_id = m.id, cfg
  where m.status <> 'cancelled' and coalesce(m.dispatch_date, m.created_at::date) >= current_date - cfg.win group by m.producer_id
), wst as (
  select w.producer_id, sum(w.qty)::int as waste_units, sum(w.value) as waste_value, sum(w.recovered_value) as recovered
  from flow.waste_events w, cfg where w.status = 'approved' and w.producer_id is not null and w.occurred_at >= now() - (cfg.win || ' days')::interval group by w.producer_id
)
select p.id as producer_id, p.code, p.name, coalesce(s.units_sent, 0) as units_sent, coalesce(x.waste_units, 0) as waste_units,
       coalesce(x.waste_value, 0) as waste_value, coalesce(x.recovered, 0) as recovered,
       case when coalesce(s.units_sent, 0) > 0 then round(100.0 * coalesce(x.waste_units, 0) / s.units_sent, 1) end as rate_pct,
       cfg.target as target_pct, (coalesce(s.units_sent, 0) >= cfg.min_units and 100.0 * coalesce(x.waste_units, 0) / nullif(s.units_sent, 0) > cfg.target) as over_target
from flow.producers p cross join cfg left join sent s on s.producer_id = p.id left join wst x on x.producer_id = p.id
where coalesce(s.units_sent, 0) > 0 or coalesce(x.waste_units, 0) > 0;

create or replace view public.ui_waste_events with (security_invoker = true) as
select w.*, c.label as cause_label, pr.name as producer_name, mc.name as machine_name, op.name as operator_name,
       (w.unit_cost = 0) as no_cost, (w.value - w.recovered_value) as net_loss
from flow.waste_events w join flow.waste_causes c on c.code = w.cause_code
left join flow.producers pr on pr.id = w.producer_id left join flow.machines mc on mc.id = w.machine_id left join flow.operators op on op.id = w.operator_id;
create or replace view public.ui_waste_rates with (security_invoker = true) as select * from flow.v_waste_rates;
create or replace view public.ui_waste_causes with (security_invoker = true) as select * from flow.waste_causes where is_active order by sort_order;

insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('waste_rate_high', 'Waste rate over target', 'quality', 'high', '{}', 'manager', 'Look at the waste records for this decorator, agree what went wrong, and record any recovery.'),
 ('waste_approval_overdue', 'Waste waiting for approval', 'quality', 'medium', '{}', 'manager', 'Approve or reject the waste records waiting in the Waste page.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_waste() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'waste_rate_high', 'key', 'waste_rate:' || r.code,
      'description', format('%s: waste is %s%% of units sent (target %s%%): %s units, £%s', r.name, r.rate_pct, r.target_pct, r.waste_units, r.waste_value),
      'links', jsonb_build_array(jsonb_build_object('type', 'producer', 'id', r.producer_id)),
      'opts', jsonb_build_object('severity', 'high', 'root_cause', 'producer', 'detected_by', 'automation', 'source_type', 'waste_rate', 'source_id', r.producer_id::text)) as x
    from flow.v_waste_rates r where r.over_target
    union all
    select jsonb_build_object('type', 'waste_approval_overdue', 'key', 'waste_pending',
      'description', format('%s waste record(s) have been waiting for approval for more than 2 days (£%s)', count(*), coalesce(sum(w.value), 0)),
      'links', '[]'::jsonb,
      'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'quality', 'detected_by', 'automation', 'source_type', 'waste_pending', 'source_id', 'all'))
    from flow.waste_events w where w.status = 'pending_approval' and w.created_at < now() - interval '2 days' having count(*) > 0
  ) q
$$;

-- Add the waste detector to the run list without rewriting the rest of the function.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%''waste''%' then
    v_def := replace(v_def, '''order_changes'',''courier''', '''order_changes'',''courier'',''waste''');
    if v_def not like '%''waste''%' then raise exception 'detector list anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- Public wrappers (service role only, called from n8n) and read grants.
create or replace function public.flow_waste_record(p jsonb, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.waste_record(p, p_actor) $$;
create or replace function public.flow_waste_confirm(p_ref text, p_confirm boolean, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.waste_confirm(p_ref, p_confirm, p_note, p_actor) $$;
create or replace function public.flow_waste_decide(p_ref text, p_approve boolean, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.waste_decide(p_ref, p_approve, p_note, p_actor) $$;
create or replace function public.flow_waste_recover(p_ref text, p_amount numeric, p_claim text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.waste_recover(p_ref, p_amount, p_claim, p_note, p_actor) $$;
create or replace function public.flow_waste_replacement(p_ref text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.waste_replacement(p_ref, p_actor) $$;
create or replace function public.flow_waste_suggest() returns jsonb language sql security definer set search_path = flow, public as $$ select flow.waste_suggest() $$;

do $$
begin
  revoke all on function public.flow_waste_record(jsonb,text), public.flow_waste_confirm(text,boolean,text,text), public.flow_waste_decide(text,boolean,text,text),
    public.flow_waste_recover(text,numeric,text,text,text), public.flow_waste_replacement(text,text), public.flow_waste_suggest() from public, anon, authenticated;
  grant execute on function public.flow_waste_record(jsonb,text), public.flow_waste_confirm(text,boolean,text,text), public.flow_waste_decide(text,boolean,text,text),
    public.flow_waste_recover(text,numeric,text,text,text), public.flow_waste_replacement(text,text), public.flow_waste_suggest() to service_role;
  revoke all on function flow.waste_record(jsonb,text), flow.waste_confirm(text,boolean,text,text), flow.waste_decide(text,boolean,text,text), flow.waste_recover(text,numeric,text,text,text),
    flow.waste_replacement(text,text), flow.waste_suggest(), flow.waste_cost(text), flow.waste_needs_approval(int,numeric), flow.exc_detect_waste() from public, anon, authenticated;
  revoke all on public.ui_waste_events, public.ui_waste_rates, public.ui_waste_causes from public, anon;
  grant select on public.ui_waste_events, public.ui_waste_rates, public.ui_waste_causes to authenticated;
end $$;
