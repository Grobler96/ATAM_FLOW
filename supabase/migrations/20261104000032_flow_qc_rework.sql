-- Quality control and rework (R7): checklists per method, QC checks at gates (pre-production, in-line, final, producer return, re-check),
-- defects that open rework jobs, replacement tracking, producer quality figures, and exceptions that block completion while quality is unresolved.

create sequence flow.qc_seq; create sequence flow.rework_seq;

create table flow.qc_criteria (
  id          uuid primary key default gen_random_uuid(),
  method_code text references flow.production_methods(code),        -- null = applies to every method
  name        text not null,
  description text,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_by  text,
  created_at  timestamptz not null default now()
);
create unique index qc_criteria_uq on flow.qc_criteria (coalesce(method_code, ''), lower(name));
alter table flow.qc_criteria enable row level security;
create policy qc_criteria_read on flow.qc_criteria for select to authenticated using (flow.is_member());
insert into flow.qc_criteria (method_code, name, description, sort_order, created_by)
select m, n, d, o, 'seed (placeholder)' from (values
  (null, 'Right garment, colour and size', 'Matches the order line.', 10), (null, 'Quantity correct', 'The count matches what was ordered.', 20), (null, 'Garment clean and undamaged', 'No marks, snags or oil.', 30),
  ('embroidery', 'Stitch quality', 'No puckering, gaps or loose threads.', 40), ('embroidery', 'Logo position and size', 'Within tolerance of the job sheet.', 50), ('embroidery', 'Thread colours match', 'Colours match the approved artwork.', 60),
  ('dtf', 'Print colour and sharpness', 'Colours match the proof; edges are clean.', 40), ('dtf', 'Position and size', 'Within tolerance of the job sheet.', 50), ('dtf', 'Adhesion', 'Fully bonded; no lifting at the edges.', 60),
  ('dtg', 'Print colour and sharpness', 'Colours match the proof; no banding.', 40), ('dtg', 'Position and size', 'Within tolerance of the job sheet.', 50),
  ('uv', 'Print colour and finish', 'Colours match the proof; finish is even.', 40), ('uv', 'Position and size', 'Within tolerance of the job sheet.', 50)
) v(m, n, d, o) where m is null or exists (select 1 from flow.production_methods where code = m) on conflict do nothing;

create table flow.qc_checks (
  id            uuid primary key default gen_random_uuid(),
  check_ref     text not null unique,
  order_id      uuid not null references flow.orders(id),
  order_line_id uuid references flow.order_lines(id),
  movement_id   uuid references flow.tp_movements(id),
  producer_id   uuid references flow.producers(id),
  gate          text not null check (gate in ('pre_production', 'in_line', 'final', 'producer_return', 'recheck')),
  checkpoint_pct int check (checkpoint_pct between 1 and 100),
  status        text not null default 'pending' check (status in ('pending', 'passed', 'failed', 'cancelled')),
  units_checked int check (units_checked >= 0),
  units_failed  int check (units_failed >= 0),
  defect_type   text,
  cause         text,
  results       jsonb not null default '[]'::jsonb,                  -- [{criterion_id, passed, note}]
  notes         text,
  evidence      jsonb not null default '[]'::jsonb,                  -- [{url, name}]
  due_by        timestamptz,
  checked_by    text,
  checked_at    timestamptz,
  created_by    text,
  created_at    timestamptz not null default now(),
  check (units_failed is null or units_checked is null or units_failed <= units_checked)
);
create index qc_checks_order on flow.qc_checks (order_id, created_at desc);
create index qc_checks_open on flow.qc_checks (due_by) where status = 'pending';
alter table flow.qc_checks enable row level security;
create policy qc_checks_read on flow.qc_checks for select to authenticated using (flow.is_member());

create table flow.rework_jobs (
  id            uuid primary key default gen_random_uuid(),
  rework_ref    text not null unique,
  order_id      uuid not null references flow.orders(id),
  order_line_id uuid references flow.order_lines(id),
  qc_check_id   uuid references flow.qc_checks(id),
  movement_id   uuid references flow.tp_movements(id),
  producer_id   uuid references flow.producers(id),
  units         int not null check (units > 0),
  defect_type   text not null,
  cause         text not null check (cause in ('operator', 'machine', 'garment', 'artwork', 'producer', 'supplier', 'unknown')),
  outcome       text not null default 'redo' check (outcome in ('redo', 'replace', 'write_off')),
  status        text not null default 'open' check (status in ('open', 'in_progress', 'complete', 'cancelled')),
  units_fixed   int not null default 0 check (units_fixed >= 0),
  units_scrapped int not null default 0 check (units_scrapped >= 0),
  assigned_to   text,
  replacement_status text not null default 'not_needed' check (replacement_status in ('not_needed', 'needed', 'ordered', 'received')),
  replacement_note text,
  notes         text,
  cancel_reason text,
  created_by    text,
  created_at    timestamptz not null default now(),
  started_at    timestamptz,
  completed_by  text,
  completed_at  timestamptz
);
create index rework_open on flow.rework_jobs (status, created_at) where status in ('open', 'in_progress');
alter table flow.rework_jobs enable row level security;
create policy rework_read on flow.rework_jobs for select to authenticated using (flow.is_member());

insert into flow.flow_settings (key, value, description) values
 ('qc.options', '{"pending_hours": 24, "defect_types": ["stitching", "placement", "colour", "print_quality", "garment_damage", "wrong_garment", "wrong_size", "contamination", "artwork", "other"]}'::jsonb,
  'PLACEHOLDER: how long an order may sit in quality check (or a pending re-check may wait) before it raises an issue, and the defect types offered.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Record a check (new, or completing a pending one). Failed units open a rework job automatically.
-- ---------------------------------------------------------------------------
create or replace function flow.qc_record_check(p_check uuid, p_order uuid, p_gate text, p_checked int, p_failed int, p_results jsonb, p_defect text, p_cause text, p_notes text, p_evidence jsonb,
                                                 p_line uuid, p_movement text, p_checkpoint int, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; c flow.qc_checks; mv flow.tp_movements; v_id uuid; v_ref text; v_status text; v_rw jsonb; v_defects jsonb := coalesce(flow.setting('qc.options')->'defect_types', '[]'::jsonb); v_gate text := p_gate; v_bad int := 0; v_failed int := coalesce(p_failed, 0);
begin
  if p_check is not null then
    select * into c from flow.qc_checks where id = p_check;
    if c.id is null or c.status <> 'pending' then return jsonb_build_object('ok', false, 'error', 'That check is not waiting to be done.'); end if;
    p_order := c.order_id; v_gate := c.gate; p_line := coalesce(p_line, c.order_line_id);
  end if;
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if v_gate not in ('pre_production', 'in_line', 'final', 'producer_return', 'recheck') then return jsonb_build_object('ok', false, 'error', 'Choose the stage of the check.'); end if;
  if p_checked is null or p_checked < 1 then return jsonb_build_object('ok', false, 'error', 'Enter how many units you checked.'); end if;
  if v_failed < 0 or v_failed > p_checked then return jsonb_build_object('ok', false, 'error', 'Failed units cannot be more than the units checked.'); end if;
  if p_results is not null and jsonb_typeof(p_results) = 'array' then
    select count(*) into v_bad from jsonb_array_elements(p_results) e where (e->>'passed')::boolean is false;
  end if;
  if v_bad > 0 and v_failed = 0 then return jsonb_build_object('ok', false, 'error', 'A checklist item failed, so at least one unit must be marked as failed.'); end if;
  if v_failed > 0 then
    if coalesce(p_defect, '') = '' or not v_defects ? p_defect then return jsonb_build_object('ok', false, 'needs_defect', true, 'error', 'Say what is wrong with the failed units.'); end if;
    if coalesce(p_cause, '') not in ('operator', 'machine', 'garment', 'artwork', 'producer', 'supplier', 'unknown') then return jsonb_build_object('ok', false, 'needs_defect', true, 'error', 'Say what you think caused it (operator, machine, garment, artwork, producer, supplier or unknown).'); end if;
  end if;
  if p_line is not null and not exists (select 1 from flow.order_lines where id = p_line and order_id = o.id) then return jsonb_build_object('ok', false, 'error', 'That line is not on this order.'); end if;
  if p_movement is not null and btrim(p_movement) <> '' then mv := flow.tp_find(p_movement); if mv.id is null then return jsonb_build_object('ok', false, 'error', 'Movement not found.'); end if; end if;
  v_status := case when v_failed > 0 then 'failed' else 'passed' end;
  if p_check is not null then
    update flow.qc_checks set status = v_status, units_checked = p_checked, units_failed = v_failed, defect_type = nullif(p_defect, ''), cause = nullif(p_cause, ''), results = coalesce(p_results, '[]'::jsonb),
           notes = nullif(btrim(coalesce(p_notes, '')), ''), evidence = coalesce(p_evidence, '[]'::jsonb), order_line_id = p_line, checked_by = p_actor, checked_at = now() where id = p_check returning check_ref into v_ref;
    v_id := p_check;
  else
    v_ref := 'QC-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.qc_seq')::text, 5, '0');
    insert into flow.qc_checks (check_ref, order_id, order_line_id, movement_id, producer_id, gate, checkpoint_pct, status, units_checked, units_failed, defect_type, cause, results, notes, evidence, checked_by, checked_at, created_by)
    values (v_ref, o.id, p_line, mv.id, mv.producer_id, v_gate, p_checkpoint, v_status, p_checked, v_failed, nullif(p_defect, ''), nullif(p_cause, ''), coalesce(p_results, '[]'::jsonb), nullif(btrim(coalesce(p_notes, '')), ''), coalesce(p_evidence, '[]'::jsonb), p_actor, now(), p_actor)
    returning id into v_id;
  end if;
  if v_failed > 0 then
    v_rw := flow.qc_open_rework(o.id, p_line, v_failed, p_defect, p_cause, case when p_cause in ('garment', 'supplier') then 'replace' else 'redo' end, p_movement, 'From ' || v_ref || coalesce(': ' || nullif(btrim(coalesce(p_notes, '')), ''), ''), p_actor, v_id);
  end if;
  perform flow.wh_audit(p_actor, 'qc_check_' || v_status, 'order', o.order_ref, null, jsonb_build_object('check', v_ref, 'gate', v_gate, 'checked', p_checked, 'failed', v_failed, 'defect', p_defect), p_notes);
  return jsonb_build_object('ok', true, 'check_id', v_id, 'check_ref', v_ref, 'status', v_status, 'order_ref', o.order_ref, 'rework_id', v_rw->>'rework_id', 'rework_ref', v_rw->>'rework_ref');
end $$;

create or replace function flow.qc_open_rework(p_order uuid, p_line uuid, p_units int, p_defect text, p_cause text, p_outcome text, p_movement text, p_notes text, p_actor text, p_check uuid default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; mv flow.tp_movements; v_ref text; v_id uuid; v_out text := coalesce(nullif(p_outcome, ''), 'redo'); v_defects jsonb := coalesce(flow.setting('qc.options')->'defect_types', '[]'::jsonb); v_method text;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if p_units is null or p_units < 1 then return jsonb_build_object('ok', false, 'error', 'Enter how many units need rework.'); end if;
  if coalesce(p_defect, '') = '' or not v_defects ? p_defect then return jsonb_build_object('ok', false, 'needs_defect', true, 'error', 'Say what is wrong with the units.'); end if;
  if coalesce(p_cause, '') not in ('operator', 'machine', 'garment', 'artwork', 'producer', 'supplier', 'unknown') then return jsonb_build_object('ok', false, 'needs_defect', true, 'error', 'Say what you think caused it.'); end if;
  if v_out not in ('redo', 'replace', 'write_off') then return jsonb_build_object('ok', false, 'error', 'Outcome must be redo, replace or write_off.'); end if;
  if p_line is not null then
    if not exists (select 1 from flow.order_lines where id = p_line and order_id = o.id) then return jsonb_build_object('ok', false, 'error', 'That line is not on this order.'); end if;
    select (decoration_methods)[1] into v_method from flow.order_lines where id = p_line;
  end if;
  if p_movement is not null and btrim(p_movement) <> '' then mv := flow.tp_find(p_movement); if mv.id is null then return jsonb_build_object('ok', false, 'error', 'Movement not found.'); end if; end if;
  v_ref := 'RW-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.rework_seq')::text, 5, '0');
  insert into flow.rework_jobs (rework_ref, order_id, order_line_id, qc_check_id, movement_id, producer_id, units, defect_type, cause, outcome, replacement_status, notes, created_by)
  values (v_ref, o.id, p_line, p_check, mv.id, mv.producer_id, p_units, p_defect, p_cause, v_out, case when v_out = 'replace' then 'needed' else 'not_needed' end, nullif(btrim(coalesce(p_notes, '')), ''), p_actor) returning id into v_id;
  perform flow.wh_audit(p_actor, 'rework_opened', 'order', o.order_ref, null, jsonb_build_object('rework', v_ref, 'units', p_units, 'defect', p_defect, 'cause', p_cause, 'outcome', v_out), p_notes);
  return jsonb_build_object('ok', true, 'rework_id', v_id, 'rework_ref', v_ref, 'order_ref', o.order_ref);
end $$;

-- start | complete | cancel | assign | replacement
create or replace function flow.qc_rework_update(p_id uuid, p_action text, p_payload jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r flow.rework_jobs; o flow.orders; v_fixed int; v_scrap int; v_note text := nullif(btrim(coalesce(p_payload->>'note', '')), ''); v_recheck uuid; v_ref text; v_status text;
begin
  select * into r from flow.rework_jobs where id = p_id;
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'Rework job not found.'); end if;
  select * into o from flow.orders where id = r.order_id;
  case p_action
  when 'start' then
    if r.status <> 'open' then return jsonb_build_object('ok', false, 'error', r.rework_ref || ' is ' || r.status || ', not waiting to start.'); end if;
    update flow.rework_jobs set status = 'in_progress', started_at = now(), assigned_to = coalesce(nullif(btrim(coalesce(p_payload->>'assigned_to', '')), ''), assigned_to, p_actor) where id = p_id;
  when 'assign' then
    if r.status not in ('open', 'in_progress') then return jsonb_build_object('ok', false, 'error', 'That job has finished.'); end if;
    if length(btrim(coalesce(p_payload->>'assigned_to', ''))) < 2 then return jsonb_build_object('ok', false, 'error', 'Say who it is assigned to.'); end if;
    update flow.rework_jobs set assigned_to = btrim(p_payload->>'assigned_to') where id = p_id;
  when 'complete' then
    if r.status not in ('open', 'in_progress') then return jsonb_build_object('ok', false, 'error', r.rework_ref || ' has already finished.'); end if;
    v_fixed := coalesce((p_payload->>'units_fixed')::int, 0); v_scrap := coalesce((p_payload->>'units_scrapped')::int, 0);
    if v_fixed < 0 or v_scrap < 0 or v_fixed + v_scrap <> r.units then return jsonb_build_object('ok', false, 'error', format('Fixed (%s) plus scrapped (%s) must add up to the %s unit(s) in this job.', v_fixed, v_scrap, r.units)); end if;
    if v_scrap > 0 and coalesce((p_payload->>'no_replacement')::boolean, false) and v_note is null then return jsonb_build_object('ok', false, 'error', 'If no replacement is needed for the scrapped units, say why.'); end if;
    update flow.rework_jobs set status = 'complete', units_fixed = v_fixed, units_scrapped = v_scrap, completed_by = p_actor, completed_at = now(), started_at = coalesce(started_at, now()),
      replacement_status = case when v_scrap > 0 and not coalesce((p_payload->>'no_replacement')::boolean, false) then 'needed' else replacement_status end,
      notes = coalesce(v_note, notes) where id = p_id;
    if v_fixed > 0 then
      v_ref := 'QC-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.qc_seq')::text, 5, '0');
      insert into flow.qc_checks (check_ref, order_id, order_line_id, movement_id, producer_id, gate, status, units_checked, due_by, created_by, notes)
      values (v_ref, r.order_id, r.order_line_id, r.movement_id, r.producer_id, 'recheck', 'pending', v_fixed, now() + make_interval(hours => coalesce((flow.setting('qc.options')->>'pending_hours')::int, 24)), p_actor, 'Re-check after ' || r.rework_ref) returning id into v_recheck;
    end if;
  when 'cancel' then
    if r.status not in ('open', 'in_progress') then return jsonb_build_object('ok', false, 'error', 'That job has already finished.'); end if;
    if length(btrim(coalesce(p_payload->>'reason', ''))) < 3 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why this rework is being cancelled.'); end if;
    update flow.rework_jobs set status = 'cancelled', cancel_reason = btrim(p_payload->>'reason'), completed_by = p_actor, completed_at = now() where id = p_id;
  when 'replacement' then
    v_status := p_payload->>'status';
    if v_status not in ('not_needed', 'ordered', 'received') then return jsonb_build_object('ok', false, 'error', 'Replacement status must be not_needed, ordered or received.'); end if;
    if r.replacement_status = 'not_needed' and r.status <> 'complete' then return jsonb_build_object('ok', false, 'error', 'No replacement has been called for on this job.'); end if;
    if v_status = 'not_needed' and v_note is null then return jsonb_build_object('ok', false, 'error', 'If no replacement is needed, say why.'); end if;
    update flow.rework_jobs set replacement_status = v_status, replacement_note = coalesce(v_note, replacement_note) where id = p_id;
  else return jsonb_build_object('ok', false, 'error', 'Unknown rework action.');
  end case;
  perform flow.wh_audit(p_actor, 'rework_' || p_action, 'order', o.order_ref, jsonb_build_object('status', r.status, 'replacement', r.replacement_status), p_payload, coalesce(v_note, p_payload->>'reason'));
  return jsonb_build_object('ok', true, 'rework_ref', r.rework_ref, 'recheck_id', v_recheck, 'recheck_ref', v_ref);
end $$;

create or replace function flow.qc_criterion_set(p_id uuid, p_method text, p_name text, p_description text, p_active boolean, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if length(btrim(coalesce(p_name, ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Give the checklist item a name.'); end if;
  if nullif(p_method, '') is not null and not exists (select 1 from flow.production_methods where code = p_method) then return jsonb_build_object('ok', false, 'error', 'Unknown decoration method.'); end if;
  if p_id is null then
    insert into flow.qc_criteria (method_code, name, description, sort_order, created_by) values (nullif(p_method, ''), btrim(p_name), nullif(btrim(coalesce(p_description, '')), ''), coalesce((select max(sort_order) from flow.qc_criteria), 0) + 10, p_actor)
    on conflict do nothing;
    if not found then return jsonb_build_object('ok', false, 'error', 'That checklist item already exists.'); end if;
  else
    update flow.qc_criteria set name = btrim(p_name), description = nullif(btrim(coalesce(p_description, '')), ''), is_active = coalesce(p_active, is_active) where id = p_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'Checklist item not found.'); end if;
  end if;
  perform flow.wh_audit(p_actor, 'qc_criterion_set', 'qc_criteria', coalesce(p_method, 'all'), null, jsonb_build_object('name', p_name, 'active', p_active), null);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Exceptions: failed work awaiting rework, replacements still needed, checks overdue. All clear themselves when resolved.
-- ---------------------------------------------------------------------------
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('qc_failed', 'Failed quality check awaiting rework', 'quality', 'high', '{completion,dispatch}', 'production', 'Rework the failed units (or scrap and replace them), then re-check before the order can finish.'),
 ('qc_replacement', 'Replacement garments needed', 'quality', 'high', '{completion}', 'manager', 'Order the replacement garments (or record why none are needed), then mark the replacement ordered and received.'),
 ('qc_pending', 'Quality check overdue', 'quality', 'medium', '{}', 'production', 'Do the check, or record why it is not needed.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_quality() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'qc_failed', 'key', 'qcf:' || r.id,
      'description', format('%s: %s unit(s) failed quality (%s, %s) on %s%s', r.rework_ref, r.units, replace(r.defect_type, '_', ' '), r.cause, o.order_ref, case when r.status = 'in_progress' then ', rework in progress' else ', rework not started' end),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)) || case when r.producer_id is not null then jsonb_build_array(jsonb_build_object('type', 'producer', 'id', r.producer_id)) else '[]'::jsonb end,
      'opts', jsonb_build_object('severity', case when o.due_date < now() + interval '2 days' then 'critical' else 'high' end, 'root_cause', case when r.cause in ('operator', 'machine') then 'internal_process' when r.cause = 'producer' then 'producer' when r.cause = 'supplier' then 'supplier' when r.cause = 'artwork' then 'artwork' else 'quality' end,
        'detected_by', 'warehouse_user', 'blocks', jsonb_build_array('completion', 'dispatch'), 'customer_impact', format('Order %s due %s', o.order_ref, (o.due_date at time zone 'Europe/London')::date), 'source_type', 'rework', 'source_id', r.id::text)) x
    from flow.rework_jobs r join flow.orders o on o.id = r.order_id where r.status in ('open', 'in_progress')
    union all
    select jsonb_build_object('type', 'qc_replacement', 'key', 'qcr:' || r.id,
      'description', format('%s: %s unit(s) of %s need replacement garments (%s)', r.rework_ref, case when r.status = 'complete' then r.units_scrapped else r.units end, o.order_ref, case r.replacement_status when 'ordered' then 'ordered, not received' else 'not ordered yet' end),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)),
      'opts', jsonb_build_object('severity', 'high', 'root_cause', 'quality', 'detected_by', 'warehouse_user', 'blocks', jsonb_build_array('completion'), 'source_type', 'rework', 'source_id', r.id::text))
    from flow.rework_jobs r join flow.orders o on o.id = r.order_id where r.replacement_status in ('needed', 'ordered') and r.status <> 'cancelled'
    union all
    select jsonb_build_object('type', 'qc_pending', 'key', 'qcp:' || c.id, 'description', format('%s (%s check) on %s is overdue', c.check_ref, replace(c.gate, '_', ' '), o.order_ref),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)), 'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'quality', 'detected_by', 'automation', 'source_type', 'qc_check', 'source_id', c.id::text))
    from flow.qc_checks c join flow.orders o on o.id = c.order_id where c.status = 'pending' and c.due_by is not null and c.due_by < now()
    union all
    select jsonb_build_object('type', 'qc_pending', 'key', 'qcq:' || o.id, 'description', format('%s has been in quality check for over %s hours with no passing check recorded', o.order_ref, coalesce((flow.setting('qc.options')->>'pending_hours')::int, 24)),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)), 'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'quality', 'detected_by', 'automation', 'source_type', 'order', 'source_id', o.id::text))
    from flow.orders o where o.is_active and o.order_status = 'quality_check' and o.updated_at < now() - make_interval(hours => coalesce((flow.setting('qc.options')->>'pending_hours')::int, 24))
      and not exists (select 1 from flow.qc_checks c where c.order_id = o.id and c.status = 'passed' and c.gate in ('final', 'producer_return', 'recheck') and c.checked_at > o.updated_at - interval '1 hour')) q
$$;

create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime','quality'] loop
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
-- Read models
-- ---------------------------------------------------------------------------
create or replace view flow.v_qc_checks with (security_invoker = true) as
select c.id, c.check_ref, c.order_id, o.order_ref, o.customer_name, o.due_date, c.order_line_id, l.sku, c.gate, c.checkpoint_pct, c.status, c.units_checked, c.units_failed, c.defect_type, c.cause,
       c.producer_id, p.name as producer_name, m.movement_code, c.notes, c.evidence, c.due_by, c.checked_by, c.checked_at, c.created_by, c.created_at,
       (select coalesce(jsonb_agg(jsonb_build_object('criterion', coalesce(k.name, 'item'), 'passed', (e->>'passed')::boolean, 'note', e->>'note')), '[]'::jsonb)
          from jsonb_array_elements(c.results) e left join flow.qc_criteria k on k.id = nullif(e->>'criterion_id', '')::uuid) as results,
       (c.status = 'pending' and c.due_by is not null and c.due_by < now()) as is_overdue
from flow.qc_checks c join flow.orders o on o.id = c.order_id left join flow.order_lines l on l.id = c.order_line_id left join flow.producers p on p.id = c.producer_id left join flow.tp_movements m on m.id = c.movement_id;

create or replace view flow.v_rework_jobs with (security_invoker = true) as
select r.id, r.rework_ref, r.order_id, o.order_ref, o.customer_name, o.due_date, r.order_line_id, l.sku, r.units, r.defect_type, r.cause, r.outcome, r.status, r.units_fixed, r.units_scrapped, r.assigned_to,
       r.replacement_status, r.replacement_note, r.notes, r.cancel_reason, r.producer_id, p.name as producer_name, m.movement_code, c.check_ref, r.created_by, r.created_at, r.started_at, r.completed_by, r.completed_at,
       extract(epoch from (coalesce(r.completed_at, now()) - r.created_at)) / 3600.0 as age_hours
from flow.rework_jobs r join flow.orders o on o.id = r.order_id left join flow.order_lines l on l.id = r.order_line_id left join flow.producers p on p.id = r.producer_id
left join flow.tp_movements m on m.id = r.movement_id left join flow.qc_checks c on c.id = r.qc_check_id;

-- Orders that need a quality decision: in quality check, or with a check waiting.
create or replace view flow.v_qc_queue with (security_invoker = true) as
select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.order_status, o.total_units,
       (select count(*) from flow.qc_checks c where c.order_id = o.id and c.status = 'pending')::int as pending_checks,
       (select c.status from flow.qc_checks c where c.order_id = o.id and c.status in ('passed', 'failed') order by c.checked_at desc limit 1) as last_result,
       (select count(*) from flow.rework_jobs r where r.order_id = o.id and r.status in ('open', 'in_progress'))::int as open_rework,
       (select count(*) from flow.rework_jobs r where r.order_id = o.id and r.replacement_status in ('needed', 'ordered'))::int as replacements_open
from flow.orders o
where o.is_active and o.shipped_at is null and (o.order_status = 'quality_check' or exists (select 1 from flow.qc_checks c where c.order_id = o.id and c.status = 'pending')
      or exists (select 1 from flow.rework_jobs r where r.order_id = o.id and (r.status in ('open', 'in_progress') or r.replacement_status in ('needed', 'ordered'))));

create or replace view flow.v_producer_quality with (security_invoker = true) as
select p.id as producer_id, p.name as producer_name, coalesce(q.checks, 0) as checks, coalesce(q.units_checked, 0) as units_checked, coalesce(q.units_failed, 0) as units_failed,
       case when coalesce(q.units_checked, 0) > 0 then round(100.0 * (q.units_checked - q.units_failed) / q.units_checked, 1) end as pass_rate,
       coalesce(r.open_rework, 0) as open_rework, coalesce(r.rework_units, 0) as rework_units
from flow.producers p
left join (select producer_id, count(*)::int as checks, sum(units_checked)::int as units_checked, sum(units_failed)::int as units_failed from flow.qc_checks where status in ('passed', 'failed') and producer_id is not null group by 1) q on q.producer_id = p.id
left join (select producer_id, count(*) filter (where status in ('open', 'in_progress'))::int as open_rework, sum(units)::int as rework_units from flow.rework_jobs where producer_id is not null and status <> 'cancelled' group by 1) r on r.producer_id = p.id;

create or replace view public.ui_qc_checks with (security_invoker = true) as select * from flow.v_qc_checks;
create or replace view public.ui_rework_jobs with (security_invoker = true) as select * from flow.v_rework_jobs;
create or replace view public.ui_qc_queue with (security_invoker = true) as select * from flow.v_qc_queue;
create or replace view public.ui_producer_quality with (security_invoker = true) as select * from flow.v_producer_quality;
create or replace view public.ui_qc_criteria with (security_invoker = true) as select id, method_code, name, description, sort_order, is_active from flow.qc_criteria;

-- ---------------------------------------------------------------------------
-- Wrappers (service role only) and grants
-- ---------------------------------------------------------------------------
create or replace function public.flow_qc_record_check(p_check uuid, p_order uuid, p_gate text, p_checked int, p_failed int, p_results jsonb, p_defect text, p_cause text, p_notes text, p_evidence jsonb, p_line uuid, p_movement text, p_checkpoint int, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.qc_record_check(p_check, p_order, p_gate, p_checked, p_failed, p_results, p_defect, p_cause, p_notes, p_evidence, p_line, p_movement, p_checkpoint, p_actor) $$;
create or replace function public.flow_qc_open_rework(p_order uuid, p_line uuid, p_units int, p_defect text, p_cause text, p_outcome text, p_movement text, p_notes text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.qc_open_rework(p_order, p_line, p_units, p_defect, p_cause, p_outcome, p_movement, p_notes, p_actor, null) $$;
create or replace function public.flow_qc_rework_update(p_id uuid, p_action text, p_payload jsonb, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.qc_rework_update(p_id, p_action, p_payload, p_actor) $$;
create or replace function public.flow_qc_criterion_set(p_id uuid, p_method text, p_name text, p_description text, p_active boolean, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.qc_criterion_set(p_id, p_method, p_name, p_description, p_active, p_actor) $$;

do $$
declare f text; v text;
begin
  foreach f in array array['public.flow_qc_record_check(uuid,uuid,text,int,int,jsonb,text,text,text,jsonb,uuid,text,int,text)', 'public.flow_qc_open_rework(uuid,uuid,int,text,text,text,text,text,text)',
    'public.flow_qc_rework_update(uuid,text,jsonb,text)', 'public.flow_qc_criterion_set(uuid,text,text,text,boolean,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.qc_record_check(uuid,uuid,text,int,int,jsonb,text,text,text,jsonb,uuid,text,int,text)', 'flow.qc_open_rework(uuid,uuid,int,text,text,text,text,text,text,uuid)',
    'flow.qc_rework_update(uuid,text,jsonb,text)', 'flow.qc_criterion_set(uuid,text,text,text,boolean,text)', 'flow.exc_detect_quality()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach v in array array['ui_qc_checks', 'ui_rework_jobs', 'ui_qc_queue', 'ui_producer_quality', 'ui_qc_criteria'] loop
    execute format('revoke all on public.%I from public, anon', v); execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
