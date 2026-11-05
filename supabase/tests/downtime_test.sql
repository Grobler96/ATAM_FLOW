-- Machine downtime: records, status, impact analysis, scheduler input, exception, machine records.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

-- fixtures: two embroidery machines (one backup of the other), jobs planned on the first
insert into r select 'm1', flow.mc_upsert_machine('{"code":"dt-a","name":"Tajima A","method_code":"embroidery","units_per_hour":12,"location":"Floor 1","machine_type":"6-head"}'::jsonb, 'tester');
insert into r select 'm2', flow.mc_upsert_machine('{"code":"DT-B","name":"Tajima B","method_code":"embroidery","units_per_hour":12,"backup_codes":["DT-A"]}'::jsonb, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'code' = 'DT-A' from r where k = 'm1') and (select (j->>'ok')::bool from r where k = 'm2'), 'machines created (code upper-cased)');
select (j->>'machine_id')::uuid as ma from r where k = 'm1' \gset
select (j->>'machine_id')::uuid as mb from r where k = 'm2' \gset
select pg_temp.assert(not (flow.mc_upsert_machine('{"code":"DT-A","name":"dup","method_code":"embroidery"}'::jsonb, 't')->>'ok')::bool and not (flow.mc_upsert_machine('{"code":"X1","name":"x","method_code":"nope"}'::jsonb, 't')->>'ok')::bool and not (flow.mc_upsert_machine('{"code":"!!","name":"x","method_code":"embroidery"}'::jsonb, 't')->>'ok')::bool, 'duplicate code, unknown method and bad code refused');
select pg_temp.assert((select backup_codes = '{DT-A}' from flow.v_machine_status where machine_id = :'mb'), 'backup machine recorded');

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values
  ('D1', '#D1', 'Due Soon Ltd', now() + interval '2 days', 'ready_for_production', true, 1, 40), ('D2', '#D2', 'Due Later Ltd', now() + interval '30 days', 'ready_for_production', true, 1, 20);
insert into flow.job_steps (order_id, method_code, step_no, status, machine_id, units, est_minutes, setup_minutes, planned_start, planned_end)
select o.id, 'embroidery', 1, 'pending', :'ma', v.u, v.m, 10, now() + v.s, now() + v.s + interval '4 hours' from (values ('D1', 40, 240, interval '1 day'), ('D2', 20, 120, interval '10 days')) v(r, u, m, s) join flow.orders o on o.deco_order_id = v.r;

-- 1. status starts operational
select pg_temp.assert((select status = 'operational' and capacity_factor = 1 from flow.v_machine_status where machine_id = :'ma'), 'machine starts operational');
select pg_temp.assert((select (j->'machines'->0 ? 'is_active') from (select flow.scheduler_input() j) x), 'scheduler input still lists machines');

-- 2. validation
select pg_temp.assert(not (flow.mc_report_downtime(:'ma', 'explode', 'x reason', null, 0, null, 't')->>'ok')::bool, 'unknown kind refused');
select pg_temp.assert((flow.mc_report_downtime(:'ma', 'breakdown', '', null, 0, null, 't')->>'needs_reason')::bool, 'reason required');
select pg_temp.assert(not (flow.mc_report_downtime(:'ma', 'limited', 'one head dead', null, 0.95, null, 't')->>'ok')::bool, 'limited needs a believable capacity');
select pg_temp.assert(not (flow.mc_report_downtime(:'ma', 'breakdown', 'motor failed', now() - interval '1 hour', 0, null, 't')->>'ok')::bool, 'return before start refused');

-- 3. a breakdown: current, impact computed, scheduler stops using the machine, exception raised
insert into r select 'bd', flow.mc_report_downtime(:'ma', 'breakdown', 'Main motor failed', now() + interval '3 days', 0, null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'current')::bool and (j->>'replan_needed')::bool from r where k = 'bd'), 'breakdown reported: ' || (select j::text from r where k = 'bd'));
select (j->>'downtime_id')::uuid as dd from r where k = 'bd' \gset
select pg_temp.assert((select status = 'breakdown' and capacity_factor = 0 and status_reason = 'Main motor failed' from flow.v_machine_status where machine_id = :'ma'), 'status is breakdown');
select pg_temp.assert((select jsonb_array_length(j->'impact'->'steps') = 1 and (j->'impact'->>'units')::int = 40 and (j->'impact'->>'at_risk')::int = 1 from r where k = 'bd'), 'impact: only the job inside the 3-day window, flagged at risk: ' || (select (j->'impact')::text from r where k = 'bd'));
select pg_temp.assert((select j->'impact'->'alternatives'->0->>'code' = 'DT-B' from r where k = 'bd') and (select bool_or(o->>'kind' = 'reroute') from r, jsonb_array_elements(j->'impact'->'options') o where k = 'bd'), 'reroute option names the other machine');
select pg_temp.assert((select not (m->>'is_active')::bool from (select jsonb_array_elements(flow.scheduler_input()->'machines') m) x where m->>'code' = 'DT-A'), 'scheduler is told the machine is not active');
select pg_temp.assert((select (m->>'is_active')::bool from (select jsonb_array_elements(flow.scheduler_input()->'machines') m) x where m->>'code' = 'DT-B'), 'the other machine still plans');
select pg_temp.assert((flow.mc_report_downtime(:'ma', 'maintenance', 'oil change', null, 0, null, 't')->>'error') like '%already has an open downtime%', 'one current downtime at a time');
select pg_temp.assert((select count(*) from flow.audit_log where action = 'machine_downtime_started' and entity_id = 'DT-A') = 1, 'downtime audited');
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'machine_down' and status = 'open' and description like 'DT-A is breakdown%') = 1, 'machine-down exception raised');

-- 4. return time can be moved (with a reason); impact refreshed
select pg_temp.assert((flow.mc_update_downtime(:'dd', now() + interval '5 days', '', 't')->>'needs_reason')::bool, 'moving the return time needs a reason');
select pg_temp.assert((flow.mc_update_downtime(:'dd', now() + interval '12 days', 'part on order', 'tester')->>'ok')::bool, 'return time moved');
insert into r select 'imp', flow.mc_impact(:'ma', now(), now() + interval '12 days', 0);
select pg_temp.assert((select jsonb_array_length(j->'steps') = 2 from r where k = 'imp'), 'a longer window catches the later job too');

-- 5. resolving ends it, clears the exception, scheduler uses the machine again
insert into r select 'rs', flow.mc_resolve_downtime(:'dd', 'tester', 'Motor replaced, test run OK');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'replan_needed')::bool from r where k = 'rs'), 'resolved, re-plan flagged');
select pg_temp.assert((select status = 'operational' from flow.v_machine_status where machine_id = :'ma') and (select (m->>'is_active')::bool from (select jsonb_array_elements(flow.scheduler_input()->'machines') m) x where m->>'code' = 'DT-A'), 'machine operational and plannable again');
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'machine_down' and status in ('open', 'investigating')) = 0, 'exception cleared when the downtime ended');
select pg_temp.assert(not (flow.mc_resolve_downtime(:'dd', 't', 'again please')->>'ok')::bool, 'cannot resolve twice');

-- 6. limited capacity: reported, shown, scheduler still plans (not modelled)
insert into r select 'lim', flow.mc_report_downtime(:'mb', 'limited', 'Two of six heads out', null, 0.66, null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'replan_needed')::bool from r where k = 'lim'), 'limited capacity does not force a re-plan');
select pg_temp.assert((select status = 'limited' and capacity_factor = 0.66 from flow.v_machine_status where machine_id = :'mb') and (select (m->>'is_active')::bool from (select jsonb_array_elements(flow.scheduler_input()->'machines') m) x where m->>'code' = 'DT-B'), 'limited status shown; machine remains plannable');

-- 7. planned maintenance in the future: scheduled, not current; no exception; cancellable
insert into r select 'pm', flow.mc_report_downtime(:'ma', 'maintenance', 'Annual service', now() + interval '10 days' + interval '8 hours', 0, now() + interval '10 days', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'current')::bool and not (j->>'replan_needed')::bool from r where k = 'pm'), 'future maintenance is scheduled, not current');
select (j->>'downtime_id')::uuid as pmid from r where k = 'pm' \gset
select pg_temp.assert((select status = 'operational' and next_planned_start is not null from flow.v_machine_status where machine_id = :'ma') and (select is_scheduled from flow.v_machine_downtime where id = :'pmid'), 'machine still operational with a planned window ahead');
select pg_temp.assert((select jsonb_array_length(j->'impact'->'steps') = 1 from r where k = 'pm'), 'planned window impact finds the job on day 10');
insert into r select 'pmx', flow.mc_resolve_downtime(:'pmid', 'tester', 'Service rescheduled');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'was_current')::bool and not (j->>'replan_needed')::bool from r where k = 'pmx') and (select count(*) from flow.audit_log where action = 'machine_downtime_cancelled') = 1, 'a scheduled window can be cancelled');

-- 8. retiring a machine
select pg_temp.assert((flow.mc_upsert_machine(jsonb_build_object('id', :'mb', 'is_active', false), 't')->>'needs_reason')::bool, 'retiring needs a reason');
select pg_temp.assert(not (flow.mc_upsert_machine(jsonb_build_object('id', :'mb', 'is_active', false, 'reason', 'sold'), 't')->>'ok')::bool, 'cannot retire a machine with open downtime');
insert into r select 'dm', flow.mc_resolve_downtime((select downtime_id from flow.v_machine_status where machine_id = :'mb'), 'tester', 'heads repaired');
insert into r select 'ret', flow.mc_upsert_machine(jsonb_build_object('id', :'mb', 'is_active', false, 'reason', 'sold'), 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'replan_needed')::bool from r where k = 'ret') and (select status = 'retired' from flow.v_machine_status where machine_id = :'mb'), 'machine retired');

-- 9. locked down
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_mc_report_downtime(uuid,text,text,timestamptz,numeric,timestamptz,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_mc_upsert_machine(jsonb,text)', 'execute')
  and has_function_privilege('service_role', 'public.flow_mc_resolve_downtime(uuid,text,text)', 'execute') and not has_function_privilege('anon', 'public.ui_mc_impact(uuid,timestamptz,timestamptz,numeric)', 'execute') and has_function_privilege('authenticated', 'public.ui_mc_impact(uuid,timestamptz,timestamptz,numeric)', 'execute'), 'wrappers locked down; impact readable when signed in');
\echo downtime_test OK
