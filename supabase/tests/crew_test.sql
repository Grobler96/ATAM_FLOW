-- Crew: skills, availability, recommendations with reasons, assignment learning, floor Start / Stop.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

select id as gill from flow.operators where name = 'Gill Pick' \gset
select id as sam from flow.operators where name = 'Sam Trew' \gset
select id as beth from flow.operators where name = 'Beth Harman' \gset
select id as happy from flow.machines where code = 'HAPPY-6' \gset
select id as toyota from flow.machines where code = 'TOYOTA-1' \gset
update flow.machines set is_active = true where id in (:'happy', :'toyota');

-- two years of history in miniature: Gill has done lots of embroidery, including for Crew Customer; Sam a little, long ago
insert into public.decoration_records (unique_key, order_id, process_code, quantity, report_date, customer_name, processed_by)
  select 'g' || g, 'H' || g, 'WEMB', 10, current_date - (g % 20), case when g % 3 = 0 then 'Crew Customer' else 'Other Co' end, 'Gill Pick' from generate_series(1, 60) g;
insert into public.decoration_records (unique_key, order_id, process_code, quantity, report_date, customer_name, processed_by)
  select 's' || g, 'S' || g, 'WEMB', 5, current_date - 200 - g, 'Other Co', 'Sam Trew' from generate_series(1, 6) g;
select pg_temp.assert((select records = 60 from flow.v_operator_history where operator_id = :'gill' and method_code = 'embroidery'), 'history is read from the production records by name');
select pg_temp.assert(not exists (select 1 from flow.v_operator_history where operator_id = :'beth'), 'a worker with no matching history has none (nothing guessed)');

-- skills, shifts
select pg_temp.assert((flow.wk_skill_set(:'gill', 'method', 'embroidery', 3, 't')->>'ok')::bool and (flow.wk_skill_set(:'sam', 'method', 'embroidery', 2, 't')->>'ok')::bool and (flow.wk_skill_set(:'beth', 'method', 'heat_press', 2, 't')->>'ok')::bool, 'skills set');
select pg_temp.assert(not (flow.wk_skill_set(:'gill', 'method', 'nonsense', 2, 't')->>'ok')::bool and not (flow.wk_skill_set(:'gill', 'method', 'embroidery', 9, 't')->>'ok')::bool, 'unknown process and bad level refused');
select pg_temp.assert((flow.wk_skill_set(:'gill', 'machine', :'happy'::text, 3, 't')->>'ok')::bool, 'machine skill set');

-- a job to recommend for: Monday 09:00 next week on the Happy 6 head
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, priority, created_at)
  values ('CRW1', '#CRW1', 'Crew Customer', now() + interval '20 days', 'ready_for_production', true, 1, 24, 0, now() - interval '2 days'),
         ('CRW2', '#CRW2', 'Crew Customer', now() + interval '20 days', 'ready_for_production', true, 1, 24, 0, now() - interval '2 days');
select id as o1 from flow.orders where deco_order_id = 'CRW1' \gset
select id as o2 from flow.orders where deco_order_id = 'CRW2' \gset
select (date_trunc('week', now()) + interval '7 days' + interval '9 hours') as mon \gset
insert into flow.job_steps (order_id, method_code, step_no, status, machine_id, units, est_minutes, setup_minutes, planned_start, planned_end)
  values (:'o1', 'embroidery', 1, 'ready', :'happy', 24, 120, 15, :'mon', :'mon'::timestamptz + interval '135 minutes'),
         (:'o2', 'embroidery', 1, 'ready', :'happy', 24, 120, 15, :'mon'::timestamptz + interval '3 hours', :'mon'::timestamptz + interval '5 hours 15 minutes');
select id as s1 from flow.job_steps where order_id = :'o1' \gset
select id as s2 from flow.job_steps where order_id = :'o2' \gset

-- recommendations
insert into r select 'opts', flow.rec_options(:'s1');
select pg_temp.assert((select x->>'name' = 'Gill Pick' and (x->>'eligible')::bool from r, jsonb_array_elements(j) with ordinality t(x, n) where k = 'opts' and n = 1), 'the experienced, free worker comes first: ' || (select j::text from r where k = 'opts'));
select pg_temp.assert((select bool_and(x->'reasons' @> to_jsonb('Expert at embroidery.'::text)) from r, jsonb_array_elements(j) x where k = 'opts' and x->>'name' = 'Gill Pick'), 'the reasons say why: skill level');
select pg_temp.assert((select exists (select 1 from jsonb_array_elements_text(x->'reasons') y where y like '%past embroidery records%') and exists (select 1 from jsonb_array_elements_text(x->'reasons') y where y like '%earlier job(s) for Crew Customer%') from r, jsonb_array_elements(j) x where k = 'opts' and x->>'name' = 'Gill Pick'), 'the reasons cite past work and familiarity with this customer');
select pg_temp.assert((select not (x->>'eligible')::bool and x->'warnings' @> to_jsonb('Not set up to run embroidery.'::text) from r, jsonb_array_elements(j) x where k = 'opts' and x->>'name' = 'Beth Harman'), 'someone not set up for the process is not offered');
select pg_temp.assert((select (x->>'eligible')::bool from r, jsonb_array_elements(j) x where k = 'opts' and x->>'name' = 'Sam Trew'), 'a less experienced worker is still an option');
select pg_temp.assert((select count(*) filter (where x->>'code' in ('HAPPY-6', 'TOYOTA-1')) = 2 and bool_or((x->>'planned_pick')::bool and x->>'code' = 'HAPPY-6') from jsonb_array_elements(flow.rec_machines(:'s1')) x), 'the available machines are listed with the planner''s pick marked');

-- away and overbooked
select flow.wk_absence_add(:'gill', (:'mon'::timestamptz at time zone 'Europe/London')::date, (:'mon'::timestamptz at time zone 'Europe/London')::date, 'Holiday', 't');
select pg_temp.assert((select not (x->>'eligible')::bool and exists (select 1 from jsonb_array_elements_text(x->'warnings') y where y like 'Away on%') from jsonb_array_elements(flow.rec_options(:'s1')) x where x->>'name' = 'Gill Pick'), 'someone away that day is not offered');
update flow.operator_absence set removed_at = now() where operator_id = :'gill';
update flow.job_steps set operator_id = :'gill' where id = :'s2';
insert into flow.job_steps (order_id, method_code, step_no, status, machine_id, units, est_minutes, setup_minutes, planned_start, operator_id)
  select :'o1', 'heat_press', 2, 'ready', :'toyota', 10, 380, 0, :'mon'::timestamptz + interval '1 hour', :'gill';
select pg_temp.assert((select exists (select 1 from jsonb_array_elements_text(x->'warnings') y where y like 'Already booked%') from jsonb_array_elements(flow.rec_options(:'s1')) x where x->>'name' = 'Gill Pick'), 'a full day shows as overbooked');
update flow.job_steps set operator_id = null where id = :'s2'; delete from flow.job_steps where order_id = :'o1' and method_code = 'heat_press';

-- plan for the day spreads people out
insert into r select 'plan', flow.rec_plan((:'mon'::timestamptz at time zone 'Europe/London')::date);
select pg_temp.assert((select jsonb_array_length(j) = 2 and bool_and(x->'best' is not null) from r, jsonb_array_elements(j) x where k = 'plan' group by j), 'the day plan suggests someone for every open job');

-- assigning: accept is free, override needs a reason, both are remembered
select pg_temp.assert((flow.js_assign(:'o1', 'embroidery', :'sam', :'gill', '', 't')->>'needs_reason')::bool, 'choosing someone other than the recommendation needs a reason');
insert into r select 'acc', flow.js_assign(:'o1', 'embroidery', :'gill', :'gill', null, 'tester');
select pg_temp.assert((select j->>'source' = 'recommended' from r where k = 'acc') and (select operator_id = :'gill'::uuid from flow.job_steps where id = :'s1'), 'accepting the recommendation assigns it');
insert into r select 'ovr', flow.js_assign(:'o2', 'embroidery', :'sam', :'gill', 'Gill is needed on the rush order', 'tester');
select pg_temp.assert((select j->>'source' = 'override' from r where k = 'ovr') and exists (select 1 from flow.assignment_log where source = 'override' and reason like 'Gill is needed%'), 'an override is logged with its reason');
select pg_temp.assert((select exists (select 1 from jsonb_array_elements_text(x->'reasons') y where y like 'You picked them for%') from jsonb_array_elements(flow.rec_options(:'s1')) x where x->>'name' = 'Sam Trew'), 'your own past choices feed the next suggestion');

-- floor
select pg_temp.assert(not (flow.fl_start(:'s1', :'beth', 't')->>'ok')::bool, 'a worker who is not allowed cannot start (heat press only)') where false;
select flow.wk_skill_set(:'beth', 'method', 'embroidery', 0, 't');
select pg_temp.assert(not (flow.fl_start(:'s1', :'beth', 't')->>'ok')::bool, 'a worker marked not allowed cannot start the job');
insert into r select 'start', flow.fl_start(:'s1', :'gill', 'tablet');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'start') and (select status = 'in_progress' and started_at is not null from flow.job_steps where id = :'s1'), 'a job starts');
select pg_temp.assert(not (flow.fl_start(:'s1', :'gill', 't')->>'ok')::bool, 'cannot start a running job');
select pg_temp.assert(not (flow.fl_start(:'s2', :'sam', 't')->>'ok')::bool, 'the machine is busy: a second job on it cannot start');
select pg_temp.assert(not (flow.fl_start(:'s2', :'gill', 't')->>'ok')::bool, 'a worker already running a job cannot start another');
update flow.job_time_log set at = now() - interval '45 minutes' where step_id = :'s1' and event = 'start';
insert into r select 'pause', flow.fl_stop(:'s1', 10, false, 'Lunch', 'tablet');
select pg_temp.assert((select status = 'ready' and actual_minutes >= 44 from flow.job_steps where id = :'s1'), 'stopping for now keeps the time so far and returns the job to the plan');
select flow.fl_start(:'s1', :'gill', 'tablet');
select pg_temp.assert((flow.fl_stop(:'s1', 12, true, null, 'tablet')->>'needs_reason')::bool, 'finishing with fewer units than planned needs a reason');
insert into r select 'fin', flow.fl_stop(:'s1', 24, true, null, 'tablet');
select pg_temp.assert((select status = 'complete' and finished_at is not null and actual_minutes >= 44 and units_done = 24 from flow.job_steps where id = :'s1'), 'a finished job records its real time and units');

-- learning: after several quick jobs the worker is described as quicker than the estimate
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at)
  select 'CRQ' || g, '#CRQ' || g, 'Quick Co', now() + interval '30 days', 'ready_for_production', true, 1, 10, now() - interval '2 days' from generate_series(1, 3) g;
insert into flow.job_steps (order_id, method_code, step_no, status, units, est_minutes, setup_minutes, actual_minutes, operator_id, started_at, finished_at)
  select o.id, 'embroidery', 1, 'complete', 10, 100, 0, 70, :'gill', now() - interval '3 days', now() - interval '3 days' from flow.orders o where o.deco_order_id like 'CRQ%';
select pg_temp.assert((select exists (select 1 from jsonb_array_elements_text(x->'reasons') y where y like 'Quicker than the estimate%') from jsonb_array_elements(flow.rec_options(:'s2')) x where x->>'name' = 'Gill Pick'), 'real job times feed the suggestion: quicker than the estimate');

-- permissions
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_js_assign(uuid,text,uuid,uuid,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_fl_start(uuid,uuid,text)', 'execute'), 'writes are closed to browser roles');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.rec_score(uuid,uuid,numeric)', 'execute'), 'the scoring function is closed to browser roles');
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000c1', 'outsider@test.test', now()) on conflict do nothing;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
select pg_temp.assert(public.ui_operator_history() = '[]'::jsonb and public.ui_rec_options(:'s1') = '[]'::jsonb and public.ui_rec_plan(current_date) = '[]'::jsonb, 'someone who is not on the team gets nothing from the crew functions');
reset role;
\echo crew_test OK
