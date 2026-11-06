-- Courier and delivery monitoring (R9), done by hand: there is no courier API. Someone records what happened to a
-- parcel; the system keeps the history, raises an exception for problems that are still open, and tracks claims.

create table flow.courier_events (
  id          uuid primary key default gen_random_uuid(),
  movement_id uuid not null references flow.tp_movements(id),
  direction   text not null default 'outbound' check (direction in ('outbound', 'return', 'customer')),
  event       text not null check (event in ('collected', 'delivered', 'failed_attempt', 'delayed', 'lost', 'damaged', 'wrong_address', 'partial', 'note')),
  at          timestamptz not null default now(),
  note        text,
  recorded_by text
);
create index courier_events_mv on flow.courier_events (movement_id, at desc);
alter table flow.courier_events enable row level security;
create policy courier_events_read on flow.courier_events for select to authenticated using (flow.is_member());

create table flow.courier_claims (
  id          uuid primary key default gen_random_uuid(),
  claim_ref   text not null unique,
  movement_id uuid not null references flow.tp_movements(id),
  kind        text not null check (kind in ('lost', 'damaged', 'late', 'partial')),
  carrier     text,
  tracking_ref text,
  value_claimed numeric(10,2),
  amount_recovered numeric(10,2),
  status      text not null default 'open' check (status in ('open', 'submitted', 'paid', 'rejected', 'closed')),
  note        text,
  opened_by   text,
  opened_at   timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_note text
);
create index courier_claims_mv on flow.courier_claims (movement_id);
alter table flow.courier_claims enable row level security;
create policy courier_claims_read on flow.courier_claims for select to authenticated using (flow.is_member());

create or replace function flow.cr_record_event(p_movement text, p_event text, p_direction text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements;
begin
  select * into m from flow.tp_movements where movement_code = p_movement;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Consignment not found.'); end if;
  if p_event not in ('collected', 'delivered', 'failed_attempt', 'delayed', 'lost', 'damaged', 'wrong_address', 'partial', 'note') then return jsonb_build_object('ok', false, 'error', 'Unknown courier event.'); end if;
  if coalesce(p_direction, 'outbound') not in ('outbound', 'return', 'customer') then return jsonb_build_object('ok', false, 'error', 'Direction must be outbound, return or customer.'); end if;
  if p_event not in ('collected', 'delivered') and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what the courier reported (at least a few words).'); end if;
  if m.status in ('cancelled') then return jsonb_build_object('ok', false, 'error', 'That consignment was cancelled.'); end if;
  insert into flow.courier_events (movement_id, direction, event, note, recorded_by) values (m.id, coalesce(p_direction, 'outbound'), p_event, nullif(btrim(coalesce(p_note, '')), ''), p_actor);
  perform flow.tp_log(m.id, 'courier_' || p_event, p_actor, jsonb_build_object('direction', coalesce(p_direction, 'outbound')), p_note);
  perform flow.wh_audit(p_actor, 'courier_' || p_event, 'movement', m.movement_code, null, jsonb_build_object('direction', coalesce(p_direction, 'outbound')), p_note);
  return jsonb_build_object('ok', true, 'movement_code', m.movement_code, 'claim_suggested', p_event in ('lost', 'damaged', 'partial'));
end $$;

create or replace function flow.cr_open_claim(p_movement text, p_kind text, p_value numeric, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; v_ref text; v_id uuid;
begin
  select * into m from flow.tp_movements where movement_code = p_movement;
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Consignment not found.'); end if;
  if p_kind not in ('lost', 'damaged', 'late', 'partial') then return jsonb_build_object('ok', false, 'error', 'Claim kind must be lost, damaged, late or partial.'); end if;
  if p_value is null or p_value <= 0 then return jsonb_build_object('ok', false, 'error', 'Enter the value being claimed.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what is being claimed for (at least a few words).'); end if;
  if exists (select 1 from flow.courier_claims where movement_id = m.id and kind = p_kind and status in ('open', 'submitted')) then return jsonb_build_object('ok', false, 'error', 'There is already an open ' || p_kind || ' claim on this consignment.'); end if;
  v_ref := 'CLM-' || to_char(now(), 'YYMMDD') || '-' || lpad((select count(*) + 1 from flow.courier_claims)::text, 3, '0');
  insert into flow.courier_claims (claim_ref, movement_id, kind, carrier, tracking_ref, value_claimed, note, opened_by) values (v_ref, m.id, p_kind, m.carrier, coalesce(m.tracking_ref, m.return_tracking_ref, m.customer_tracking_ref), p_value, btrim(p_note), p_actor) returning id into v_id;
  perform flow.tp_log(m.id, 'courier_claim_opened', p_actor, jsonb_build_object('claim', v_ref, 'kind', p_kind, 'value', p_value), p_note);
  perform flow.wh_audit(p_actor, 'courier_claim_opened', 'movement', m.movement_code, null, jsonb_build_object('claim', v_ref, 'kind', p_kind, 'value', p_value), p_note);
  return jsonb_build_object('ok', true, 'claim_ref', v_ref);
end $$;

create or replace function flow.cr_claim_update(p_claim text, p_status text, p_recovered numeric, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.courier_claims;
begin
  select * into c from flow.courier_claims where claim_ref = p_claim;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'Claim not found.'); end if;
  if p_status not in ('submitted', 'paid', 'rejected', 'closed') then return jsonb_build_object('ok', false, 'error', 'Status must be submitted, paid, rejected or closed.'); end if;
  if c.status in ('paid', 'rejected', 'closed') then return jsonb_build_object('ok', false, 'error', 'That claim is already finished.'); end if;
  if p_status = 'paid' and (p_recovered is null or p_recovered < 0) then return jsonb_build_object('ok', false, 'error', 'Enter the amount recovered.'); end if;
  if p_status in ('rejected', 'closed') and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the claim is being ' || p_status || '.'); end if;
  update flow.courier_claims set status = p_status, amount_recovered = coalesce(p_recovered, amount_recovered), closed_note = case when p_status in ('paid', 'rejected', 'closed') then nullif(btrim(coalesce(p_note, '')), '') else closed_note end, updated_at = now() where id = c.id;
  perform flow.wh_audit(p_actor, 'courier_claim_' || p_status, 'claim', c.claim_ref, jsonb_build_object('status', c.status), jsonb_build_object('status', p_status, 'recovered', p_recovered), p_note);
  return jsonb_build_object('ok', true, 'claim_ref', c.claim_ref);
end $$;

-- Problems still open: the latest event on a consignment is a problem (not followed by delivered or collected), or a claim has sat unresolved for two weeks.
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('courier_problem', 'Courier problem on a consignment', 'logistics', 'high', '{}', 'manager', 'Contact the courier, find the parcel or arrange a redelivery, and open a claim if it is lost or damaged.'),
 ('courier_claim_stale', 'Courier claim not resolved', 'logistics', 'medium', '{}', 'manager', 'Chase the courier for a decision on the claim, or close it with a reason.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_courier() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'courier_problem', 'key', 'courier:' || m.movement_code,
      'description', format('%s: courier reported %s%s', m.movement_code, replace(e.event, '_', ' '), case when e.note is not null then ' (' || e.note || ')' end),
      'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)),
      'opts', jsonb_build_object('severity', case when e.event in ('lost', 'damaged') then 'critical' else 'high' end, 'root_cause', 'courier', 'detected_by', 'automation', 'source_type', 'courier_event', 'source_id', e.id::text)) as x
    from flow.tp_movements m
    join lateral (select * from flow.courier_events ce where ce.movement_id = m.id and ce.event <> 'note' order by ce.at desc, ce.id desc limit 1) e on true
    where e.event in ('failed_attempt', 'delayed', 'lost', 'damaged', 'wrong_address', 'partial') and m.status not in ('closed', 'cancelled')
    union all
    select jsonb_build_object('type', 'courier_claim_stale', 'key', 'claim:' || c.claim_ref,
      'description', format('Claim %s (%s, £%s) has been %s for %s days', c.claim_ref, c.kind, c.value_claimed, c.status, (current_date - c.opened_at::date)),
      'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', c.movement_id)),
      'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'courier', 'detected_by', 'automation', 'source_type', 'courier_claim', 'source_id', c.id::text))
    from flow.courier_claims c where c.status in ('open', 'submitted') and c.opened_at < now() - interval '14 days'
  ) q
$$;

create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime','quality','producer_risk','order_changes','courier'] loop
    begin
      execute format('select flow.exc_detect_%s()', d) into v_rows;
      v_res := v_res || jsonb_build_array(flow.exc_sync('detector:' || d, v_rows));
    exception when others then
      v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:' || d, 'error', sqlerrm));
      perform flow.notify('detector_failed', 'warning', 'Exception detector failed: ' || d, sqlerrm, null, null);
    end;
  end loop;
  begin
    v_res := v_res || jsonb_build_array(flow.exc_sync('detector:completed_open', flow.exc_detect_completed_open()));
  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:completed_open', 'error', sqlerrm));
  end;
  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? 'error');
  v_out := jsonb_build_object('ok', v_ok, 'at', now(), 'detectors', v_res,
    'open_now', (select count(*) from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')),
    'critical_open', (select count(*) from flow.exceptions where severity = 'critical' and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')));
  insert into flow.flow_runs (workflow, status, triggered_by, started_at, finished_at, summary, error)
  values ('exceptions', case when v_ok then 'success' else 'partial' end::flow.run_status, 'detector', v_start, clock_timestamp(),
          jsonb_build_object('open_now', v_out->'open_now', 'critical_open', v_out->'critical_open'),
          (select string_agg(x->>'detector' || ': ' || (x->>'error'), '; ') from jsonb_array_elements(v_res) x where x ? 'error'));
  return v_out;
end $$;

create or replace view public.ui_courier_events with (security_invoker = true) as
select e.id, m.movement_code, m.carrier, e.direction, e.event, e.at, e.note, e.recorded_by from flow.courier_events e join flow.tp_movements m on m.id = e.movement_id;
create or replace view public.ui_courier_claims with (security_invoker = true) as
select c.id, c.claim_ref, m.movement_code, c.kind, c.carrier, c.tracking_ref, c.value_claimed, c.amount_recovered, c.status, c.note, c.opened_by, c.opened_at, c.updated_at, c.closed_note, (current_date - c.opened_at::date) as age_days
from flow.courier_claims c join flow.tp_movements m on m.id = c.movement_id;

create or replace function public.flow_cr_record_event(p_movement text, p_event text, p_direction text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.cr_record_event(p_movement, p_event, p_direction, p_note, p_actor) $$;
create or replace function public.flow_cr_open_claim(p_movement text, p_kind text, p_value numeric, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.cr_open_claim(p_movement, p_kind, p_value, p_note, p_actor) $$;
create or replace function public.flow_cr_claim_update(p_claim text, p_status text, p_recovered numeric, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.cr_claim_update(p_claim, p_status, p_recovered, p_note, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_cr_record_event(text,text,text,text,text)', 'public.flow_cr_open_claim(text,text,numeric,text,text)', 'public.flow_cr_claim_update(text,text,numeric,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.cr_record_event(text,text,text,text,text)', 'flow.cr_open_claim(text,text,numeric,text,text)', 'flow.cr_claim_update(text,text,numeric,text,text)', 'flow.exc_detect_courier()', 'flow.exceptions_detect_all()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  revoke all on public.ui_courier_events, public.ui_courier_claims from public, anon;
  grant select on public.ui_courier_events, public.ui_courier_claims to authenticated;
end $$;
