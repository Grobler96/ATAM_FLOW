-- Producer risk (R4): suspend / resume, limits and contacts, a risk score with the reasons, exposure and recovery options,
-- silence checkpoints, and the producer job-sheet email (review-first draft).

alter table flow.producers add column if not exists is_suspended boolean not null default false;
alter table flow.producers add column if not exists suspended_reason text;
alter table flow.producers add column if not exists suspended_at timestamptz;
alter table flow.producers add column if not exists suspended_by text;
alter table flow.producers add column if not exists emergency_contact text;
alter table flow.producers add column if not exists emergency_phone text;
alter table flow.producers add column if not exists backup_producer_ids uuid[] not null default '{}';
alter table flow.producers add column if not exists max_concurrent_jobs int check (max_concurrent_jobs is null or max_concurrent_jobs > 0);
alter table flow.producers add column if not exists last_contact_at timestamptz;
alter table flow.producers add column if not exists last_contact_note text;

insert into flow.flow_settings (key, value, description) values
 ('producer.risk', '{"medium": 20, "high": 40, "critical": 60, "no_update_days": 3, "silence_days": 14}'::jsonb,
  'PLACEHOLDER: producer risk score thresholds (higher = riskier), days without a status update before a checkpoint issue, and days without contact while holding our goods.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- A suspended producer, or one at its job limit, cannot be given new work. Enforced where movements are created.
-- ---------------------------------------------------------------------------
create or replace function flow.guard_new_movement() returns trigger language plpgsql set search_path = flow, public as $$
declare p flow.producers; v_open int;
begin
  if new.movement_type not in ('outbound_to_producer', 'direct_dispatch_to_customer') then return new; end if;
  select * into p from flow.producers where id = new.producer_id;
  if p.is_suspended then raise exception '% is suspended (%). Resume them before sending new work.', p.name, coalesce(p.suspended_reason, 'no reason recorded'); end if;
  if p.max_concurrent_jobs is not null then
    select count(*) into v_open from flow.tp_movements where producer_id = p.id and movement_type in ('outbound_to_producer', 'direct_dispatch_to_customer') and status not in ('closed', 'cancelled', 'checked');
    if v_open >= p.max_concurrent_jobs then raise exception '% is already at its limit of % open job(s).', p.name, p.max_concurrent_jobs; end if;
  end if;
  return new;
end $$;
create trigger tp_movements_guard before insert on flow.tp_movements for each row execute function flow.guard_new_movement();

create or replace function flow.pr_suspend(p_producer uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.producers; v_held int;
begin
  select * into p from flow.producers where id = p_producer;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  if p.is_suspended then return jsonb_build_object('ok', false, 'error', p.name || ' is already suspended.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why work is being stopped for this producer (at least a few words).'); end if;
  update flow.producers set is_suspended = true, suspended_reason = btrim(p_reason), suspended_at = now(), suspended_by = p_actor where id = p_producer;
  select coalesce(units_held, 0) into v_held from flow.producer_stats where producer_id = p_producer;
  perform flow.wh_audit(p_actor, 'producer_suspended', 'producer', p.code, null, jsonb_build_object('reason', p_reason), p_reason);
  return jsonb_build_object('ok', true, 'name', p.name, 'units_held', coalesce(v_held, 0), 'message', case when coalesce(v_held, 0) > 0 then 'No new work can be sent. They still hold ' || v_held || ' unit(s): see the recovery options.' else 'No new work can be sent to them.' end);
end $$;

create or replace function flow.pr_resume(p_producer uuid, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.producers;
begin
  select * into p from flow.producers where id = p_producer;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  if not p.is_suspended then return jsonb_build_object('ok', false, 'error', p.name || ' is not suspended.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why they are being allowed to take work again.'); end if;
  update flow.producers set is_suspended = false, suspended_reason = null, suspended_at = null, suspended_by = null where id = p_producer;
  perform flow.wh_audit(p_actor, 'producer_resumed', 'producer', p.code, jsonb_build_object('was_suspended_for', p.suspended_reason), null, p_note);
  return jsonb_build_object('ok', true, 'name', p.name);
end $$;

create or replace function flow.pr_record_contact(p_producer uuid, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.producers;
begin
  select * into p from flow.producers where id = p_producer;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Note what was said or agreed.'); end if;
  update flow.producers set last_contact_at = now(), last_contact_note = btrim(p_note) where id = p_producer;
  perform flow.wh_audit(p_actor, 'producer_contact', 'producer', p.code, null, null, p_note);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.pr_set_limits(p_producer uuid, p_emergency_contact text, p_emergency_phone text, p_backup_codes text[], p_max_jobs int, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.producers; v_ids uuid[];
begin
  select * into p from flow.producers where id = p_producer;
  if p.id is null then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  if p_max_jobs is not null and p_max_jobs < 1 then return jsonb_build_object('ok', false, 'error', 'The job limit must be at least 1, or blank for no limit.'); end if;
  select coalesce(array_agg(id), '{}') into v_ids from flow.producers where code = any (select upper(btrim(x)) from unnest(coalesce(p_backup_codes, '{}')) x) and id <> p_producer;
  update flow.producers set emergency_contact = nullif(btrim(coalesce(p_emergency_contact, '')), ''), emergency_phone = nullif(btrim(coalesce(p_emergency_phone, '')), ''), backup_producer_ids = v_ids, max_concurrent_jobs = p_max_jobs where id = p_producer;
  perform flow.wh_audit(p_actor, 'producer_limits', 'producer', p.code, null, jsonb_build_object('max_jobs', p_max_jobs, 'backups', p_backup_codes), null);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Risk score (0 = safe, 100 = very risky) with the reasons it is made of
-- ---------------------------------------------------------------------------
create or replace view flow.v_producer_risk with (security_invoker = true) as
with cfg as (select coalesce((select value from flow.flow_settings where key = 'producer.risk'), '{}'::jsonb) c),
mv as (select producer_id, count(*) filter (where is_overdue)::int as overdue, count(*) filter (where status = 'dispatched' and received_by_producer_at is null and dispatch_date < current_date - 1)::int as unconfirmed,
              count(*)::int as open_movements
       from flow.v_tp_movements_live where status not in ('closed', 'cancelled', 'checked') and movement_type in ('outbound_to_producer', 'direct_dispatch_to_customer') group by 1),
f as (
  select p.id as producer_id, p.name, p.code, p.is_active, p.is_suspended, p.suspended_reason, p.suspended_at, p.max_concurrent_jobs, p.emergency_contact, p.emergency_phone, p.last_contact_at, p.last_contact_note, p.backup_producer_ids,
         coalesce(s.units_held, 0) as units_held, coalesce(s.units_in_transit, 0) as units_in_transit, coalesce(s.value_held, 0) as value_held, coalesce(s.open_jobs, 0) as open_jobs,
         s.on_time_rate, s.discrepancy_rate, q.pass_rate, coalesce(mv.overdue, 0) as overdue_returns, coalesce(mv.unconfirmed, 0) as unconfirmed_receipts, coalesce(mv.open_movements, 0) as open_movements,
         least(30, case when s.on_time_rate is null then 5 else round((100 - s.on_time_rate) * 0.3) end)::int as pts_late,
         least(20, round(coalesce(s.discrepancy_rate, 0) * 1.5))::int as pts_discrepancy,
         least(20, coalesce(mv.overdue, 0) * 8)::int as pts_overdue,
         least(15, coalesce(mv.unconfirmed, 0) * 10)::int as pts_receipt,
         least(15, case when q.pass_rate is null then 0 else round((100 - q.pass_rate) * 0.5) end)::int as pts_quality,
         case when coalesce(s.units_held, 0) > 0 and (p.last_contact_at is null or p.last_contact_at < now() - make_interval(days => coalesce((cfg.c->>'silence_days')::int, 14))) and exists (select 1 from flow.tp_movements m where m.producer_id = p.id and m.status in ('dispatched', 'received_by_producer', 'in_production', 'production_complete', 'in_transit_back', 'partially_returned') and m.updated_at < now() - make_interval(days => coalesce((cfg.c->>'silence_days')::int, 14))) then 5 else 0 end as pts_silence,
         cfg.c as cfg
  from flow.producers p cross join cfg left join flow.producer_stats s on s.producer_id = p.id left join flow.v_producer_quality q on q.producer_id = p.id left join mv on mv.producer_id = p.id)
select f.*, least(100, f.pts_late + f.pts_discrepancy + f.pts_overdue + f.pts_receipt + f.pts_quality + f.pts_silence) as risk_score,
       case when least(100, f.pts_late + f.pts_discrepancy + f.pts_overdue + f.pts_receipt + f.pts_quality + f.pts_silence) >= coalesce((f.cfg->>'critical')::int, 60) then 'critical'
            when least(100, f.pts_late + f.pts_discrepancy + f.pts_overdue + f.pts_receipt + f.pts_quality + f.pts_silence) >= coalesce((f.cfg->>'high')::int, 40) then 'high'
            when least(100, f.pts_late + f.pts_discrepancy + f.pts_overdue + f.pts_receipt + f.pts_quality + f.pts_silence) >= coalesce((f.cfg->>'medium')::int, 20) then 'medium' else 'low' end as risk_rating,
       array_remove(array[
         case when f.pts_late >= 6 then case when f.on_time_rate is null then 'No on-time history yet' else format('On time only %s%% of the time', round(f.on_time_rate)) end end,
         case when f.pts_discrepancy > 0 then format('Discrepancy rate %s%%', round(f.discrepancy_rate)) end,
         case when f.pts_overdue > 0 then format('%s return(s) overdue', f.overdue_returns) end,
         case when f.pts_receipt > 0 then format('%s consignment(s) dispatched more than a day ago with no receipt confirmed', f.unconfirmed_receipts) end,
         case when f.pts_quality > 0 then format('Quality pass rate %s%%', round(f.pass_rate)) end,
         case when f.pts_silence > 0 then 'Holding our goods with no contact or update for a while' end], null) as reasons
from f;

-- Exposure and what to do about it if this producer fails
create or replace function flow.pr_recovery(p_producer uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare r record; v_held jsonb; v_alts jsonb; v_opts jsonb := '[]'::jsonb; v_methods text[];
begin
  select * into r from flow.v_producer_risk where producer_id = p_producer;
  if r.producer_id is null then return jsonb_build_object('ok', false, 'error', 'Producer not found.'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('movement_code', m.movement_code, 'status', m.status, 'units', m.units_outstanding, 'orders', m.order_refs, 'expected_back', m.expected_return_date, 'is_overdue', m.is_overdue) order by m.expected_return_date nulls last), '[]'::jsonb) into v_held
    from flow.v_tp_movements_live m where m.producer_id = p_producer and m.status not in ('closed', 'cancelled', 'checked', 'draft', 'picked', 'packed') and m.units_outstanding > 0;
  select coalesce(array_agg(distinct x), '{}') into v_methods from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id join flow.order_lines l on l.id = i.order_line_id, unnest(l.decoration_methods) x where m.producer_id = p_producer and m.status not in ('closed', 'cancelled', 'checked');
  select coalesce(jsonb_agg(jsonb_build_object('producer_id', p.id, 'name', p.name, 'turnaround_days', p.turnaround_days, 'is_backup', p.id = any (r.backup_producer_ids), 'has_rate', exists (select 1 from flow.producer_rates pr where pr.producer_id = p.id)) order by (p.id = any (r.backup_producer_ids)) desc, p.turnaround_days), '[]'::jsonb) into v_alts
    from flow.producers p where p.id <> p_producer and p.is_active and not p.is_suspended and (cardinality(v_methods) = 0 or p.capable_methods && v_methods);
  if r.units_held > 0 or jsonb_array_length(v_held) > 0 then
    v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'contact', 'text', case when r.emergency_contact is not null then format('Call %s on %s today and ask for a firm return date and a photo of the goods.', r.emergency_contact, coalesce(r.emergency_phone, 'the number on file')) else 'Call the producer today and ask for a firm return date and a photo of the goods. No emergency contact is recorded: add one.' end));
    v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'collect', 'text', format('Consider arranging collection of the %s unit(s) held (about £%s of garments) so the work is not lost.', r.units_held, round(r.value_held))));
    if jsonb_array_length(v_alts) > 0 then
      v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'resource', 'text', format('Re-source new work to: %s.', (select string_agg(a->>'name' || case when (a->>'is_backup')::boolean then ' (backup)' else '' end || ', ' || (a->>'turnaround_days') || ' day turnaround' || case when (a->>'has_rate')::boolean then '' else ', no rate card yet' end, '; ') from jsonb_array_elements(v_alts) a))));
    else v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'no_alternative', 'text', 'No other active producer can do the same work. Decide whether to bring it in-house or tell the customers.')); end if;
  else
    v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'none', 'text', 'They hold none of our goods right now, so there is nothing to recover.'));
  end if;
  if not r.is_suspended and r.risk_rating in ('high', 'critical') then v_opts := v_opts || jsonb_build_array(jsonb_build_object('kind', 'suspend', 'text', 'Consider suspending them so no new work is sent until the problem is understood.')); end if;
  return jsonb_build_object('ok', true, 'producer_id', p_producer, 'name', r.name, 'risk_score', r.risk_score, 'risk_rating', r.risk_rating, 'reasons', to_jsonb(r.reasons), 'units_held', r.units_held, 'value_held', r.value_held,
    'held', v_held, 'alternatives', v_alts, 'options', v_opts, 'is_suspended', r.is_suspended);
end $$;

-- ---------------------------------------------------------------------------
-- Exceptions: no status update on goods the producer has; high-risk producers holding our goods
-- ---------------------------------------------------------------------------
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('producer_no_update', 'Producer has gone quiet', 'producer', 'medium', '{}', 'manager', 'Ask the producer for a status update and a photo of the work; check the expected return date still holds.'),
 ('producer_at_risk', 'Producer at high risk', 'producer', 'high', '{}', 'manager', 'Look at the risk reasons, contact the producer, and decide whether to suspend them or move work to a backup.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_producer_risk() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'producer_no_update', 'key', 'tpnu:' || m.id,
      'description', format('%s: %s has had no update for %s days (status: %s)', m.movement_code, p.name, extract(day from now() - coalesce(e.last_at, m.updated_at))::int, replace(m.status::text, '_', ' ')),
      'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id), jsonb_build_object('type', 'producer', 'id', p.id)),
      'opts', jsonb_build_object('severity', 'medium', 'status', 'awaiting_producer', 'root_cause', 'producer', 'detected_by', 'automation', 'source_type', 'tp_movement', 'source_id', m.id::text)) x
    from flow.tp_movements m join flow.producers p on p.id = m.producer_id left join lateral (select max(at) as last_at from flow.tp_movement_events where movement_id = m.id) e on true
    where m.status in ('received_by_producer', 'in_production') and coalesce(e.last_at, m.updated_at) < now() - make_interval(days => coalesce((flow.setting('producer.risk')->>'no_update_days')::int, 3))
    union all
    select jsonb_build_object('type', 'producer_at_risk', 'key', 'prisk:' || r.producer_id,
      'description', format('%s is %s risk (score %s): %s', r.name, r.risk_rating, r.risk_score, coalesce(array_to_string(r.reasons, '; '), 'see the scorecard')),
      'links', jsonb_build_array(jsonb_build_object('type', 'producer', 'id', r.producer_id)),
      'opts', jsonb_build_object('severity', case when r.risk_rating = 'critical' then 'critical' else 'high' end, 'root_cause', 'producer', 'detected_by', 'automation', 'financial_impact', round(r.value_held, 2), 'source_type', 'producer', 'source_id', r.producer_id::text))
    from flow.v_producer_risk r where r.is_active and r.risk_rating in ('high', 'critical') and (r.units_held > 0 or r.open_jobs > 0)) q
$$;

create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime','quality','producer_risk'] loop
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
-- ---------------------------------------------------------------------------
-- Job sheet email to the producer: a review-first draft, never sent automatically
-- ---------------------------------------------------------------------------
create or replace function flow.mv_job_sheet_draft(p_movement text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; p flow.producers; j jsonb; v_lines text; v_body text; v_id uuid; v_units int; v_set jsonb := coalesce(flow.setting('comms.settings'), '{}'::jsonb); v_subject text;
begin
  m := flow.tp_find(p_movement);
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Movement not found.'); end if;
  if m.status = 'cancelled' then return jsonb_build_object('ok', false, 'error', m.movement_code || ' was cancelled.'); end if;
  if m.movement_type <> 'outbound_to_producer' and m.movement_type <> 'direct_dispatch_to_customer' then return jsonb_build_object('ok', false, 'error', 'Job sheets are only sent for outbound work.'); end if;
  select * into p from flow.producers where id = m.producer_id;
  if exists (select 1 from flow.communications c where c.entity_type = 'movement' and c.entity_id = m.id and c.kind = 'producer_job' and c.status in ('draft', 'pending_review', 'approved', 'sending')) then
    return jsonb_build_object('ok', true, 'already_queued', true, 'message', 'A job sheet for ' || m.movement_code || ' is already waiting in the review queue.');
  end if;
  j := flow.tp_label_payloads(m.movement_code)->'job_sheet';
  select string_agg(format('  - %s x %s%s%s%s  (order %s)', l->>'qty', coalesce(l->>'sku', l->>'product'), coalesce(' ' || nullif(concat_ws(' ', l->>'colour', l->>'size'), ''), ''),
           case when jsonb_array_length(coalesce(l->'methods', '[]'::jsonb)) > 0 then ', ' || (select string_agg(x, ' + ') from jsonb_array_elements_text(l->'methods') x) else '' end,
           case when nullif(l->>'stitches_per_piece', '') is not null then ', ' || (l->>'stitches_per_piece') || ' stitches' else '' end, l->>'order_ref'), E'\n'),
         coalesce(sum((l->>'qty')::int), 0)::int into v_lines, v_units from jsonb_array_elements(coalesce(j->'lines', '[]'::jsonb)) l;
  v_subject := format('Job sheet: %s (%s units, due back %s)', m.movement_code, v_units, coalesce(to_char((j->>'due_back')::date, 'DD Mon'), 'to be confirmed'));
  v_body := format(E'Hello%s,\n\nPlease find the job sheet for consignment %s.\n\nSent: %s%s\nDue back: %s%s\n\nWork required:\n%s\n%s%s\nPlease confirm receipt as soon as the goods arrive, and tell us straight away if anything is missing, damaged or cannot be done.\n\nThank you,\n%s',
    coalesce(' ' || p.contact_name, ''), m.movement_code, coalesce(to_char(m.dispatch_date, 'DD Mon YYYY'), 'not yet dispatched'), case when m.carrier is not null then format(' by %s%s', m.carrier, coalesce(' (' || m.tracking_ref || ')', '')) else '' end,
    coalesce(to_char((j->>'due_back')::date, 'DD Mon YYYY'), 'to be confirmed'), case when (j->>'due_back_is_tentative')::boolean then ' (tentative until you confirm receipt)' else '' end, coalesce(v_lines, '  (see the attached job sheet)'),
    case when nullif(j->>'special_instructions', '') is not null then E'\nSpecial instructions: ' || (j->>'special_instructions') || E'\n' else '' end,
    case when nullif(j->>'quality_notes', '') is not null then E'Quality notes: ' || (j->>'quality_notes') || E'\n' else '' end, coalesce(v_set->>'signature', 'ATAM FLOW Production Control'));
  v_id := flow.queue_comm('producer_job', case when p.email is not null then array[p.email] else '{}'::text[] end, v_subject, v_body, null, 'movement', m.id, null, p.id, p_actor);
  perform flow.tp_log(m.id, 'job_sheet_drafted', p_actor, jsonb_build_object('comm_id', v_id));
  perform flow.wh_audit(p_actor, 'job_sheet_drafted', 'tp_movement', m.movement_code, null, jsonb_build_object('comm_id', v_id), null);
  return jsonb_build_object('ok', true, 'comm_id', v_id, 'movement_code', m.movement_code, 'no_recipient', p.email is null);
end $$;

-- ---------------------------------------------------------------------------
-- Read models, wrappers, grants
-- ---------------------------------------------------------------------------
create or replace view public.ui_producer_risk with (security_invoker = true) as
select producer_id, name, code, is_active, is_suspended, suspended_reason, suspended_at, max_concurrent_jobs, emergency_contact, emergency_phone, last_contact_at, last_contact_note, units_held, units_in_transit, value_held, open_jobs, open_movements,
       on_time_rate, discrepancy_rate, pass_rate, overdue_returns, unconfirmed_receipts, risk_score, risk_rating, reasons,
       (select array_agg(b.code order by b.code) from flow.producers b where b.id = any (v_producer_risk.backup_producer_ids)) as backup_codes
from flow.v_producer_risk;
create or replace function public.ui_pr_recovery(p_producer uuid) returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when flow.is_member() then flow.pr_recovery(p_producer) else '{}'::jsonb end $$;
create or replace function public.flow_pr_suspend(p_producer uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pr_suspend(p_producer, p_reason, p_actor) $$;
create or replace function public.flow_pr_resume(p_producer uuid, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pr_resume(p_producer, p_note, p_actor) $$;
create or replace function public.flow_pr_record_contact(p_producer uuid, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pr_record_contact(p_producer, p_note, p_actor) $$;
create or replace function public.flow_pr_set_limits(p_producer uuid, p_emergency_contact text, p_emergency_phone text, p_backup_codes text[], p_max_jobs int, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.pr_set_limits(p_producer, p_emergency_contact, p_emergency_phone, p_backup_codes, p_max_jobs, p_actor) $$;
create or replace function public.flow_mv_job_sheet_draft(p_movement text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.mv_job_sheet_draft(p_movement, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_pr_suspend(uuid,text,text)', 'public.flow_pr_resume(uuid,text,text)', 'public.flow_pr_record_contact(uuid,text,text)', 'public.flow_pr_set_limits(uuid,text,text,text[],int,text)', 'public.flow_mv_job_sheet_draft(text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.pr_suspend(uuid,text,text)', 'flow.pr_resume(uuid,text,text)', 'flow.pr_record_contact(uuid,text,text)', 'flow.pr_set_limits(uuid,text,text,text[],int,text)', 'flow.pr_recovery(uuid)', 'flow.mv_job_sheet_draft(text,text)', 'flow.exc_detect_producer_risk()', 'flow.guard_new_movement()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  revoke all on public.ui_producer_risk from public, anon; grant select on public.ui_producer_risk to authenticated;
  revoke all on function public.ui_pr_recovery(uuid) from public, anon; grant execute on function public.ui_pr_recovery(uuid) to authenticated;
end $$;
