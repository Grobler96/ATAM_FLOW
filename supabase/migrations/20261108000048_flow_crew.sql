-- Crew: workers, what each can run, who is free, who has done what before, and a recommender that suggests who does which job.
-- The recommendation is a transparent score (every reason is shown in plain English), never a black box, and a person always decides:
-- accept it, or pick someone else with a reason. Floor Start / Stop records real job times so the suggestions learn real speed.

alter table flow.operators add column if not exists history_name text;
update flow.operators set history_name = name where history_name is null;

create table flow.operator_skills (
  operator_id uuid not null references flow.operators(id),
  kind  text not null check (kind in ('method', 'machine')),
  ref   text not null,                       -- production method code, or machine id as text
  level int not null check (level between 0 and 3),   -- 0 not allowed, 1 learning, 2 competent, 3 expert
  note  text, set_by text, set_at timestamptz not null default now(), removed_at timestamptz,
  primary key (operator_id, kind, ref)
);
create table flow.operator_shifts (
  id uuid primary key default gen_random_uuid(), operator_id uuid not null references flow.operators(id),
  weekday smallint not null check (weekday between 1 and 7), start_time time not null, end_time time not null, removed_at timestamptz, check (end_time > start_time));
create table flow.operator_absence (
  id uuid primary key default gen_random_uuid(), operator_id uuid not null references flow.operators(id),
  from_date date not null, to_date date not null, reason text, created_by text, created_at timestamptz not null default now(), removed_at timestamptz, check (to_date >= from_date));
create table flow.assignment_log (
  id bigint generated always as identity primary key, at timestamptz not null default now(),
  step_id uuid references flow.job_steps(id) on delete set null, order_ref text, method_code text,
  operator_id uuid references flow.operators(id), source text not null check (source in ('manual', 'recommended', 'override')),
  recommended_operator_id uuid references flow.operators(id), score numeric, actor text, reason text);
create table flow.job_time_log (
  id bigint generated always as identity primary key, step_id uuid not null references flow.job_steps(id) on delete cascade,
  operator_id uuid references flow.operators(id), machine_id uuid references flow.machines(id),
  event text not null check (event in ('start', 'stop', 'finish')), at timestamptz not null default now(), units int, note text, actor text);
create index job_time_log_step on flow.job_time_log (step_id, at);
alter table flow.job_steps add column if not exists started_at timestamptz, add column if not exists finished_at timestamptz,
  add column if not exists actual_minutes numeric, add column if not exists units_done int;
alter table flow.operator_skills enable row level security; alter table flow.operator_shifts enable row level security; alter table flow.operator_absence enable row level security;
alter table flow.assignment_log enable row level security; alter table flow.job_time_log enable row level security;
create policy operator_skills_read on flow.operator_skills for select to authenticated using (flow.is_member());
create policy operator_shifts_read on flow.operator_shifts for select to authenticated using (flow.is_member());
create policy operator_absence_read on flow.operator_absence for select to authenticated using (flow.is_member());
create policy assignment_log_read on flow.assignment_log for select to authenticated using (flow.is_member());
create policy job_time_log_read on flow.job_time_log for select to authenticated using (flow.is_member());

-- DecoNetwork process codes in the production history -> our process names
create or replace function flow.hist_method(p_code text) returns text language sql immutable as $$
  select case upper(coalesce(p_code, '')) when 'WEMB' then 'embroidery' when 'EMB' then 'embroidery' when 'DTF' then 'dtf' when 'UV' then 'uv' when 'DTG' then 'dtg' when 'SCREEN' then 'screen_print' when 'VINYL' then 'vinyl' else lower(coalesce(p_code, 'other')) end $$;

create or replace view flow.v_operator_history as
  select op.id as operator_id, flow.hist_method(d.process_code) as method_code, count(*)::int as records, coalesce(sum(d.quantity), 0)::int as units,
         count(distinct d.report_date)::int as days, max(d.report_date) as last_done
  from flow.operators op join public.decoration_records d on lower(btrim(d.processed_by)) = lower(btrim(op.history_name))
  group by 1, 2;
create or replace view flow.v_operator_customer_history as
  select op.id as operator_id, flow.hist_method(d.process_code) as method_code, lower(btrim(d.customer_name)) as customer_key, count(*)::int as records
  from flow.operators op join public.decoration_records d on lower(btrim(d.processed_by)) = lower(btrim(op.history_name)) where d.customer_name is not null
  group by 1, 2, 3;

-- first skills from the real history (volume): 200+ records expert, 20+ competent, otherwise learning. Editable on the Crew page.
insert into flow.operator_skills (operator_id, kind, ref, level, note, set_by)
  select h.operator_id, 'method', h.method_code, case when h.records >= 200 then 3 when h.records >= 20 then 2 else 1 end, 'Worked out from ' || h.records || ' production records; please check', 'migration'
  from flow.v_operator_history h on conflict do nothing;

create or replace function flow.op_day_capacity(p_op uuid, p_day date) returns numeric language sql stable set search_path = flow, public as $$
  select coalesce(
    (select sum(extract(epoch from (end_time - start_time)) / 60) from flow.operator_shifts where operator_id = p_op and removed_at is null and weekday = extract(isodow from p_day)),
    case when exists (select 1 from flow.operator_shifts where operator_id = p_op and removed_at is null) then 0 else
      (select sum(extract(epoch from (end_time - start_time)) / 60) from flow.machine_shifts where machine_id is null and weekday = extract(isodow from p_day)) end, 0) $$;

-- one operator scored for one job step, with plain-English reasons
create or replace function flow.rec_score(p_step uuid, p_op uuid, p_extra_load numeric default 0) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare js flow.job_steps; o flow.orders; op flow.operators; v_day date; v_machine uuid; v_mname text; v_method text; v_level int; v_mlevel int; v_has_skills boolean;
  v_cap numeric; v_load numeric; v_need numeric; v_free numeric; v_hist record; v_cust int := 0; v_manual int; v_same_order int; v_n_act int; v_ratio numeric;
  v_score numeric := 0; v_reasons text[] := '{}'; v_warn text[] := '{}'; v_elig boolean := true; v_urgent boolean; v_pts numeric; v_abs record;
begin
  select * into js from flow.job_steps where id = p_step; select * into o from flow.orders where id = js.order_id; select * into op from flow.operators where id = p_op;
  v_method := js.method_code; v_machine := coalesce(js.assigned_machine_id, js.machine_id); select name into v_mname from flow.machines where id = v_machine;
  v_day := coalesce((js.planned_start at time zone 'Europe/London')::date, current_date);
  v_urgent := coalesce(js.is_late, false) or (o.due_date is not null and o.due_date < now() + interval '3 days');
  if op.id is null or not op.is_active then return jsonb_build_object('operator_id', p_op, 'name', op.name, 'eligible', false, 'score', 0, 'reasons', '[]'::jsonb, 'warnings', jsonb_build_array('Not an active worker.')); end if;
  select * into v_abs from flow.operator_absence where operator_id = p_op and removed_at is null and v_day between from_date and to_date limit 1;
  if v_abs.id is not null then v_elig := false; v_warn := v_warn || ('Away on ' || to_char(v_day, 'DD Mon') || coalesce(' (' || v_abs.reason || ')', '') || '.'); end if;
  v_cap := flow.op_day_capacity(p_op, v_day);
  if v_cap <= 0 then v_elig := false; v_warn := v_warn || ('Not on shift on ' || to_char(v_day, 'Dy DD Mon') || '.'); end if;
  select exists (select 1 from flow.operator_skills where operator_id = p_op and removed_at is null) into v_has_skills;
  select level into v_level from flow.operator_skills where operator_id = p_op and kind = 'method' and ref = v_method and removed_at is null;
  if v_has_skills and v_level is null then v_elig := false; v_warn := v_warn || ('Not set up to run ' || replace(v_method, '_', ' ') || '.');
  elsif v_level = 0 then v_elig := false; v_warn := v_warn || ('Not allowed to run ' || replace(v_method, '_', ' ') || '.');
  elsif v_level is not null then v_pts := v_level * 10 * case when v_urgent then 1.25 else 1 end; v_score := v_score + v_pts; v_reasons := v_reasons || (case v_level when 3 then 'Expert' when 2 then 'Competent' else 'Still learning' end || ' at ' || replace(v_method, '_', ' ') || '.');
  else v_warn := v_warn || 'No skills recorded for this worker yet: set them on the Crew page.'::text; end if;
  if v_machine is not null then
    select level into v_mlevel from flow.operator_skills where operator_id = p_op and kind = 'machine' and ref = v_machine::text and removed_at is null;
    if v_mlevel = 0 then v_elig := false; v_warn := v_warn || ('Not cleared for ' || coalesce(v_mname, 'that machine') || '.');
    elsif v_mlevel is not null then v_score := v_score + v_mlevel * 3; v_reasons := v_reasons || ('Knows ' || coalesce(v_mname, 'the machine') || ' (' || case v_mlevel when 3 then 'expert' when 2 then 'competent' else 'learning' end || ').'); end if;
  end if;
  select * into v_hist from flow.v_operator_history where operator_id = p_op and method_code = v_method;
  if v_hist.operator_id is not null then
    v_pts := least(15, round((4 * ln(1 + v_hist.records / 10.0))::numeric, 1)); v_score := v_score + v_pts; v_reasons := v_reasons || format('%s past %s records (%s units over %s days).', v_hist.records, replace(v_method, '_', ' '), v_hist.units, v_hist.days);
    if v_hist.last_done >= current_date - 30 then v_score := v_score + 5; v_reasons := v_reasons || 'Did this kind of work in the last 30 days.'::text; end if;
  end if;
  select coalesce(sum(records), 0) into v_cust from flow.v_operator_customer_history where operator_id = p_op and method_code = v_method and customer_key = lower(btrim(coalesce(o.customer_name, '')));
  if v_cust > 0 then v_pts := least(10, round((3 * ln(1 + v_cust))::numeric, 1)); v_score := v_score + v_pts; v_reasons := v_reasons || format('Has done %s earlier job(s) for %s.', v_cust, o.customer_name); end if;
  select count(*), coalesce(sum(js2.actual_minutes), 0) / nullif(sum(js2.est_minutes + coalesce(js2.setup_minutes, 0)), 0) into v_n_act, v_ratio
    from flow.job_steps js2 where js2.operator_id = p_op and js2.method_code = v_method and js2.status = 'complete' and js2.actual_minutes is not null and js2.est_minutes > 0;
  if v_n_act >= 3 and v_ratio is not null then v_pts := greatest(-10, least(15, round((1.2 - v_ratio) * 30, 1))) * case when v_urgent and v_ratio < 1 then 1.25 else 1 end; v_score := v_score + v_pts;
    v_reasons := v_reasons || format('%s their recent jobs (%s of the estimated time).', case when v_ratio <= 1 then 'Quicker than the estimate on' else 'Slower than the estimate on' end, to_char(round(v_ratio * 100), 'FM999') || '%'); end if;
  select coalesce(sum(coalesce(est_minutes, 0) + coalesce(setup_minutes, 0)), 0) into v_load from flow.job_steps where operator_id = p_op and id <> p_step and status in ('pending', 'ready', 'in_progress') and (planned_start at time zone 'Europe/London')::date = v_day;
  v_load := v_load + coalesce(p_extra_load, 0); v_need := coalesce(js.est_minutes, 0) + coalesce(js.setup_minutes, 0); v_free := v_cap - v_load;
  if v_cap > 0 then
    v_pts := greatest(-25, least(20, round(20 * (v_free - v_need) / v_cap, 1))); v_score := v_score + v_pts;
    if v_free < v_need then v_warn := v_warn || format('Already booked for %s of %s minutes that day; this job needs %s.', round(v_load), round(v_cap), round(v_need));
    else v_reasons := v_reasons || format('Free: %s of %s minutes still open on %s.', round(v_free), round(v_cap), to_char(v_day, 'Dy DD Mon')); end if;
  end if;
  select count(*) into v_same_order from flow.job_steps where order_id = js.order_id and operator_id = p_op and id <> p_step;
  if v_same_order > 0 then v_score := v_score + 5; v_reasons := v_reasons || 'Already working on another step of this order.'::text; end if;
  select count(*) into v_manual from flow.assignment_log where operator_id = p_op and method_code = v_method and source in ('manual', 'override') and at > now() - interval '90 days';
  if v_manual > 0 then v_score := v_score + least(8, v_manual); v_reasons := v_reasons || format('You picked them for %s similar job(s) recently.', v_manual); end if;
  return jsonb_build_object('operator_id', p_op, 'name', op.name, 'eligible', v_elig, 'score', round(v_score, 1), 'reasons', to_jsonb(v_reasons), 'warnings', to_jsonb(v_warn), 'free_minutes', round(coalesce(v_free, 0)));
end $$;

create or replace function flow.rec_options(p_step uuid, p_loads jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare r record; v_out jsonb := '[]'::jsonb;
begin
  if not exists (select 1 from flow.job_steps where id = p_step) then return jsonb_build_object('ok', false, 'error', 'Job not found.'); end if;
  for r in select id from flow.operators where is_active order by name loop v_out := v_out || jsonb_build_array(flow.rec_score(p_step, r.id, coalesce((p_loads->>(r.id::text))::numeric, 0))); end loop;
  return coalesce((select jsonb_agg(x order by (x->>'eligible')::boolean desc, (x->>'score')::numeric desc, x->>'name') from jsonb_array_elements(v_out) x), '[]'::jsonb);
end $$;

-- machines that could run this job, with their load that day (the planner's own pick is marked)
create or replace function flow.rec_machines(p_step uuid) returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare js flow.job_steps; v_day date;
begin
  select * into js from flow.job_steps where id = p_step; if js.id is null then return '[]'::jsonb; end if;
  v_day := coalesce((js.planned_start at time zone 'Europe/London')::date, current_date);
  return coalesce((select jsonb_agg(jsonb_build_object('machine_id', m.id, 'code', m.code, 'name', m.name, 'heads', m.heads, 'planned_pick', m.id = js.machine_id, 'chosen', m.id = js.assigned_machine_id,
      'available', coalesce(v.status = 'operational' or v.status = 'limited', true), 'status', coalesce(v.status, 'operational'),
      'load_minutes', (select round(coalesce(sum(coalesce(j2.est_minutes, 0) + coalesce(j2.setup_minutes, 0)), 0)) from flow.job_steps j2 where j2.machine_id = m.id and j2.status in ('pending', 'ready', 'in_progress') and (j2.planned_start at time zone 'Europe/London')::date = v_day))
      order by m.id = js.machine_id desc, m.code)
    from flow.machines m left join flow.v_machine_status v on v.machine_id = m.id where m.is_active and m.method_code = js.method_code), '[]'::jsonb);
end $$;

-- suggestions for every unassigned job on a day, filling people up as it goes so one person is not given everything
create or replace function flow.rec_plan(p_day date) returns jsonb language plpgsql stable security definer set search_path = flow, public as $$
declare s record; v_loads jsonb := '{}'::jsonb; v_opts jsonb; v_best jsonb; v_out jsonb := '[]'::jsonb; v_need numeric;
begin
  for s in select js.id, js.order_id, js.method_code, js.planned_start, o.order_ref, o.customer_name, coalesce(js.est_minutes, 0) + coalesce(js.setup_minutes, 0) as need
           from flow.job_steps js join flow.orders o on o.id = js.order_id
           where js.operator_id is null and js.status in ('pending', 'ready') and (js.planned_start at time zone 'Europe/London')::date = p_day and js.blocked_reason is null
           order by js.is_late desc, o.priority desc, js.planned_start loop
    v_opts := flow.rec_options(s.id, v_loads);
    select x into v_best from jsonb_array_elements(v_opts) x where (x->>'eligible')::boolean limit 1;
    if v_best is not null then v_loads := jsonb_set(v_loads, array[v_best->>'operator_id'], to_jsonb(coalesce((v_loads->>(v_best->>'operator_id'))::numeric, 0) + s.need)); end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('step_id', s.id, 'order_ref', s.order_ref, 'customer', s.customer_name, 'method_code', s.method_code, 'planned_start', s.planned_start, 'best', v_best,
      'alternatives', coalesce((select jsonb_agg(x) from (select x from jsonb_array_elements(v_opts) x where (x->>'eligible')::boolean and (v_best is null or x->>'operator_id' <> v_best->>'operator_id') limit 3) q), '[]'::jsonb)));
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Changing the crew
-- ---------------------------------------------------------------------------
create or replace function flow.wk_save(p_id uuid, p_name text, p_history_name text, p_active boolean, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_id uuid;
begin
  if length(btrim(coalesce(p_name, ''))) < 2 then return jsonb_build_object('ok', false, 'error', 'Enter the worker''s name.'); end if;
  if p_id is null then
    if exists (select 1 from flow.operators where lower(name) = lower(btrim(p_name))) then return jsonb_build_object('ok', false, 'error', 'There is already a worker with that name.'); end if;
    insert into flow.operators (name, history_name) values (btrim(p_name), coalesce(nullif(btrim(coalesce(p_history_name, '')), ''), btrim(p_name))) returning id into v_id;
  else
    update flow.operators set name = btrim(p_name), history_name = coalesce(nullif(btrim(coalesce(p_history_name, '')), ''), btrim(p_name)), is_active = coalesce(p_active, is_active) where id = p_id returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'Worker not found.'); end if;
  end if;
  perform flow.wh_audit(p_actor, case when p_id is null then 'worker_added' else 'worker_changed' end, 'worker', btrim(p_name), null, jsonb_build_object('history_name', p_history_name, 'active', p_active), null);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function flow.wk_skill_set(p_op uuid, p_kind text, p_ref text, p_level int, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare op flow.operators; v_label text;
begin
  select * into op from flow.operators where id = p_op; if op.id is null then return jsonb_build_object('ok', false, 'error', 'Worker not found.'); end if;
  if p_kind not in ('method', 'machine') or p_level is null or p_level not between 0 and 3 then return jsonb_build_object('ok', false, 'error', 'Level must be 0 (not allowed) to 3 (expert).'); end if;
  if p_kind = 'method' and not exists (select 1 from flow.production_methods where code = p_ref) then return jsonb_build_object('ok', false, 'error', 'Unknown process.'); end if;
  if p_kind = 'machine' and not exists (select 1 from flow.machines where id::text = p_ref) then return jsonb_build_object('ok', false, 'error', 'Unknown machine.'); end if;
  insert into flow.operator_skills (operator_id, kind, ref, level, set_by) values (p_op, p_kind, p_ref, p_level, p_actor)
    on conflict (operator_id, kind, ref) do update set level = excluded.level, set_by = excluded.set_by, set_at = now(), removed_at = null;
  perform flow.wh_audit(p_actor, 'worker_skill', 'worker', op.name, null, jsonb_build_object('kind', p_kind, 'ref', p_ref, 'level', p_level), null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.wk_skill_clear(p_op uuid, p_kind text, p_ref text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_n int;
begin
  update flow.operator_skills set removed_at = now(), set_by = p_actor where operator_id = p_op and kind = p_kind and ref = p_ref and removed_at is null; get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'That skill is not recorded.'); end if;
  perform flow.wh_audit(p_actor, 'worker_skill_cleared', 'worker', p_op::text, null, jsonb_build_object('kind', p_kind, 'ref', p_ref), null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.wk_shift_set(p_op uuid, p_weekday int, p_start time, p_end time, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if p_weekday not between 1 and 7 then return jsonb_build_object('ok', false, 'error', 'Weekday must be 1 (Mon) to 7 (Sun).'); end if;
  update flow.operator_shifts set removed_at = now() where operator_id = p_op and weekday = p_weekday and removed_at is null;
  if p_start is not null and p_end is not null then
    if p_end <= p_start then return jsonb_build_object('ok', false, 'error', 'The shift must end after it starts.'); end if;
    insert into flow.operator_shifts (operator_id, weekday, start_time, end_time) values (p_op, p_weekday, p_start, p_end);
  end if;
  perform flow.wh_audit(p_actor, 'worker_shift', 'worker', p_op::text, null, jsonb_build_object('weekday', p_weekday, 'start', p_start, 'end', p_end), null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.wk_absence_add(p_op uuid, p_from date, p_to date, p_reason text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if p_from is null or p_to is null or p_to < p_from then return jsonb_build_object('ok', false, 'error', 'Enter the first and last day away.'); end if;
  insert into flow.operator_absence (operator_id, from_date, to_date, reason, created_by) values (p_op, p_from, p_to, nullif(btrim(coalesce(p_reason, '')), ''), p_actor);
  perform flow.wh_audit(p_actor, 'worker_absence', 'worker', p_op::text, null, jsonb_build_object('from', p_from, 'to', p_to), p_reason);
  return jsonb_build_object('ok', true, 'jobs_affected', (select count(*) from flow.job_steps where operator_id = p_op and status in ('pending', 'ready') and (planned_start at time zone 'Europe/London')::date between p_from and p_to));
end $$;

create or replace function flow.wk_absence_remove(p_id uuid, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_n int;
begin update flow.operator_absence set removed_at = now() where id = p_id and removed_at is null; get diagnostics v_n = row_count; if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'Not found.'); end if;
  perform flow.wh_audit(p_actor, 'worker_absence_removed', 'worker', p_id::text, null, null, null); return jsonb_build_object('ok', true); end $$;

-- assigning, with the recommendation remembered: accepting it is free, choosing someone else needs a reason
create or replace function flow.js_assign(p_order uuid, p_method text, p_operator uuid, p_recommended uuid, p_reason text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare js flow.job_steps; v_src text; v_res jsonb; v_score numeric; o flow.orders;
begin
  select * into js from flow.job_steps where order_id = p_order and method_code = p_method; select * into o from flow.orders where id = p_order;
  if js.id is null then return jsonb_build_object('ok', false, 'error', 'That job has not been planned yet. Re-plan production first.'); end if;
  if p_operator is not null and p_recommended is not null and p_operator <> p_recommended and length(btrim(coalesce(p_reason, ''))) < 5 then
    return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'You chose someone other than the recommendation. Say why (at least a few words).'); end if;
  v_src := case when p_operator is null then 'manual' when p_recommended is null then 'manual' when p_operator = p_recommended then 'recommended' else 'override' end;
  v_res := flow.js_set_operator(p_order, p_method, p_operator, p_actor);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
  if p_operator is not null then
    v_score := (flow.rec_score(js.id, p_operator)->>'score')::numeric;
    insert into flow.assignment_log (step_id, order_ref, method_code, operator_id, source, recommended_operator_id, score, actor, reason) values (js.id, o.order_ref, p_method, p_operator, v_src, p_recommended, v_score, p_actor, nullif(btrim(coalesce(p_reason, '')), ''));
  end if;
  return v_res || jsonb_build_object('source', v_src);
end $$;

-- ---------------------------------------------------------------------------
-- Floor: Start and Stop record real times
-- ---------------------------------------------------------------------------
create or replace function flow.fl_start(p_step uuid, p_operator uuid, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare js flow.job_steps; o flow.orders; op flow.operators; v_machine uuid; v_level int; v_busy text;
begin
  select * into js from flow.job_steps where id = p_step; if js.id is null then return jsonb_build_object('ok', false, 'error', 'Job not found.'); end if;
  select * into o from flow.orders where id = js.order_id; select * into op from flow.operators where id = p_operator;
  if op.id is null or not op.is_active then return jsonb_build_object('ok', false, 'error', 'Choose a worker.'); end if;
  if js.status = 'in_progress' then return jsonb_build_object('ok', false, 'error', 'That job is already running.'); end if;
  if js.status not in ('pending', 'ready') then return jsonb_build_object('ok', false, 'error', 'That job cannot be started: it is ' || js.status || '.'); end if;
  if o.order_status = 'on_hold' then return jsonb_build_object('ok', false, 'error', o.order_ref || ' is on hold.'); end if;
  if js.blocked_reason is not null then return jsonb_build_object('ok', false, 'error', 'That job is blocked: ' || js.blocked_reason); end if;
  select level into v_level from flow.operator_skills where operator_id = p_operator and kind = 'method' and ref = js.method_code and removed_at is null;
  if v_level = 0 then return jsonb_build_object('ok', false, 'error', op.name || ' is not allowed to run ' || replace(js.method_code, '_', ' ') || '.'); end if;
  v_machine := coalesce(js.assigned_machine_id, js.machine_id);
  if v_machine is null then return jsonb_build_object('ok', false, 'error', 'This job has no machine yet. Re-plan production or choose one.'); end if;
  select o2.order_ref into v_busy from flow.job_steps j2 join flow.orders o2 on o2.id = j2.order_id where j2.status = 'in_progress' and j2.operator_id = p_operator limit 1;
  if v_busy is not null then return jsonb_build_object('ok', false, 'error', op.name || ' is already running ' || v_busy || '. Stop that job first.'); end if;
  select o2.order_ref into v_busy from flow.job_steps j2 join flow.orders o2 on o2.id = j2.order_id where j2.status = 'in_progress' and coalesce(j2.assigned_machine_id, j2.machine_id) = v_machine limit 1;
  if v_busy is not null then return jsonb_build_object('ok', false, 'error', 'That machine is already running ' || v_busy || '.'); end if;
  update flow.job_steps set status = 'in_progress', started_at = coalesce(started_at, now()), operator_id = p_operator, machine_id = v_machine where id = p_step;
  insert into flow.job_time_log (step_id, operator_id, machine_id, event, actor) values (p_step, p_operator, v_machine, 'start', p_actor);
  perform flow.wh_audit(p_actor, 'job_started', 'order', o.order_ref, null, jsonb_build_object('method', js.method_code, 'operator', op.name), null);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref);
end $$;

-- p_finished false = stop for now (a break, or the machine is needed): the job goes back to ready and its time so far is kept
create or replace function flow.fl_stop(p_step uuid, p_units int, p_finished boolean, p_note text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare js flow.job_steps; o flow.orders; v_last timestamptz; v_add numeric; v_total numeric;
begin
  select * into js from flow.job_steps where id = p_step; if js.id is null then return jsonb_build_object('ok', false, 'error', 'Job not found.'); end if;
  if js.status <> 'in_progress' then return jsonb_build_object('ok', false, 'error', 'That job is not running.'); end if;
  select * into o from flow.orders where id = js.order_id;
  if p_units is not null and p_units < 0 then return jsonb_build_object('ok', false, 'error', 'Units cannot be negative.'); end if;
  if p_finished and p_units is not null and js.units is not null and p_units < js.units and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'You counted fewer units than planned. Say why (at least a few words).'); end if;
  select max(at) into v_last from flow.job_time_log where step_id = p_step and event = 'start';
  v_add := greatest(extract(epoch from (now() - coalesce(v_last, js.started_at, now()))) / 60, 0);
  v_total := coalesce(js.actual_minutes, 0) + v_add;
  insert into flow.job_time_log (step_id, operator_id, machine_id, event, units, note, actor) values (p_step, js.operator_id, coalesce(js.assigned_machine_id, js.machine_id), case when p_finished then 'finish' else 'stop' end, p_units, nullif(btrim(coalesce(p_note, '')), ''), p_actor);
  update flow.job_steps set actual_minutes = round(v_total, 1), units_done = coalesce(p_units, units_done), status = case when p_finished then 'complete' else 'ready' end, finished_at = case when p_finished then now() else finished_at end where id = p_step;
  perform flow.wh_audit(p_actor, case when p_finished then 'job_finished' else 'job_stopped' end, 'order', o.order_ref, null, jsonb_build_object('method', js.method_code, 'minutes', round(v_total, 1), 'units', p_units), p_note);
  return jsonb_build_object('ok', true, 'order_ref', o.order_ref, 'minutes', round(v_total, 1), 'finished', p_finished);
end $$;

-- ---------------------------------------------------------------------------
-- Read models, wrappers, grants
-- ---------------------------------------------------------------------------
create or replace view public.ui_operators with (security_invoker = true) as select id, name, is_active, notes, history_name from flow.operators;
create or replace view public.ui_operator_skills with (security_invoker = true) as
  select s.operator_id, s.kind, s.ref, s.level, case when s.kind = 'machine' then (select name from flow.machines where id::text = s.ref) else null end as machine_name, s.set_by, s.set_at from flow.operator_skills s where s.removed_at is null;
create or replace view public.ui_operator_shifts with (security_invoker = true) as select id, operator_id, weekday, start_time, end_time from flow.operator_shifts where removed_at is null;
create or replace view public.ui_operator_absence with (security_invoker = true) as select id, operator_id, from_date, to_date, reason from flow.operator_absence where removed_at is null;
create or replace function public.ui_operator_history() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when flow.is_member() then coalesce((select jsonb_agg(to_jsonb(h)) from flow.v_operator_history h), '[]'::jsonb) else '[]'::jsonb end $$;
create or replace view public.ui_assignment_log with (security_invoker = true) as
  select l.id, l.at, l.order_ref, l.method_code, op.name as operator, rop.name as recommended, l.source, l.score, l.actor, l.reason
  from flow.assignment_log l left join flow.operators op on op.id = l.operator_id left join flow.operators rop on rop.id = l.recommended_operator_id;
create or replace view public.ui_job_time with (security_invoker = true) as
  select js.id as step_id, o.order_ref, js.method_code, op.name as operator, js.started_at, js.finished_at, js.actual_minutes, js.units_done, js.est_minutes, js.status
  from flow.job_steps js join flow.orders o on o.id = js.order_id left join flow.operators op on op.id = js.operator_id where js.started_at is not null;

create or replace function public.ui_rec_options(p_step uuid) returns jsonb language sql stable security definer set search_path = flow, public as $$ select case when flow.is_member() then flow.rec_options(p_step) else '[]'::jsonb end $$;
create or replace function public.ui_rec_machines(p_step uuid) returns jsonb language sql stable security definer set search_path = flow, public as $$ select case when flow.is_member() then flow.rec_machines(p_step) else '[]'::jsonb end $$;
create or replace function public.ui_rec_plan(p_day date) returns jsonb language sql stable security definer set search_path = flow, public as $$ select case when flow.is_member() then flow.rec_plan(p_day) else '[]'::jsonb end $$;

create or replace function public.flow_wk_save(p_id uuid, p_name text, p_history_name text, p_active boolean, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.wk_save(p_id, p_name, p_history_name, p_active, p_actor) $$;
create or replace function public.flow_wk_skill_set(p_op uuid, p_kind text, p_ref text, p_level int, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.wk_skill_set(p_op, p_kind, p_ref, p_level, p_actor) $$;
create or replace function public.flow_wk_skill_clear(p_op uuid, p_kind text, p_ref text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.wk_skill_clear(p_op, p_kind, p_ref, p_actor) $$;
create or replace function public.flow_wk_shift_set(p_op uuid, p_weekday int, p_start time, p_end time, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.wk_shift_set(p_op, p_weekday, p_start, p_end, p_actor) $$;
create or replace function public.flow_wk_absence_add(p_op uuid, p_from date, p_to date, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.wk_absence_add(p_op, p_from, p_to, p_reason, p_actor) $$;
create or replace function public.flow_wk_absence_remove(p_id uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.wk_absence_remove(p_id, p_actor) $$;
create or replace function public.flow_js_assign(p_order uuid, p_method text, p_operator uuid, p_recommended uuid, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.js_assign(p_order, p_method, p_operator, p_recommended, p_reason, p_actor) $$;
create or replace function public.flow_fl_start(p_step uuid, p_operator uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.fl_start(p_step, p_operator, p_actor) $$;
create or replace function public.flow_fl_stop(p_step uuid, p_units int, p_finished boolean, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.fl_stop(p_step, p_units, p_finished, p_note, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_wk_save(uuid,text,text,boolean,text)', 'public.flow_wk_skill_set(uuid,text,text,int,text)', 'public.flow_wk_skill_clear(uuid,text,text,text)', 'public.flow_wk_shift_set(uuid,int,time,time,text)',
    'public.flow_wk_absence_add(uuid,date,date,text,text)', 'public.flow_wk_absence_remove(uuid,text)', 'public.flow_js_assign(uuid,text,uuid,uuid,text,text)', 'public.flow_fl_start(uuid,uuid,text)', 'public.flow_fl_stop(uuid,int,boolean,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  foreach f in array array['flow.rec_score(uuid,uuid,numeric)', 'flow.rec_options(uuid,jsonb)', 'flow.rec_machines(uuid)', 'flow.rec_plan(date)', 'flow.wk_save(uuid,text,text,boolean,text)', 'flow.wk_skill_set(uuid,text,text,int,text)', 'flow.wk_skill_clear(uuid,text,text,text)',
    'flow.wk_shift_set(uuid,int,time,time,text)', 'flow.wk_absence_add(uuid,date,date,text,text)', 'flow.wk_absence_remove(uuid,text)', 'flow.js_assign(uuid,text,uuid,uuid,text,text)', 'flow.fl_start(uuid,uuid,text)', 'flow.fl_stop(uuid,int,boolean,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  grant execute on function flow.op_day_capacity(uuid, date), flow.hist_method(text) to authenticated, service_role;
  revoke all on public.ui_operators, public.ui_operator_skills, public.ui_operator_shifts, public.ui_operator_absence, public.ui_assignment_log, public.ui_job_time from public, anon;
  grant select on public.ui_operators, public.ui_operator_skills, public.ui_operator_shifts, public.ui_operator_absence, public.ui_assignment_log, public.ui_job_time to authenticated;
  revoke all on function public.ui_rec_options(uuid), public.ui_rec_machines(uuid), public.ui_rec_plan(date), public.ui_operator_history() from public, anon;
  grant execute on function public.ui_rec_options(uuid), public.ui_rec_machines(uuid), public.ui_rec_plan(date), public.ui_operator_history() to authenticated;
end $$;
