-- Assigning a job to an operator and a machine.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at) values ('ASG1', '#ASG1', 'Assign Co', now() + interval '9 days', 'ready_for_production', true, 1, 12, now() - interval '2 days');
select id as o from flow.orders where deco_order_id = 'ASG1' \gset
insert into flow.job_steps (order_id, method_code, step_no, status) values (:'o', 'embroidery', 1, 'pending'), (:'o', 'heat_press', 2, 'pending');
select id as emb from flow.machines where code = 'TOYOTA-1' \gset
select id as press from flow.machines where code = 'PRESS-SILVER' \gset
select id as gill from flow.operators where name = 'Gill Pick' \gset

-- machine
select pg_temp.assert(not (flow.js_set_machine(:'o', 'embroidery', :'press', 'Because I said so', 't')->>'ok')::bool, 'a heat press cannot take an embroidery job');
select pg_temp.assert((flow.js_set_machine(:'o', 'embroidery', :'emb', '', 't')->>'needs_reason')::bool, 'choosing a machine needs a reason');
select pg_temp.assert(not (flow.js_set_machine(:'o', 'dtf', :'emb', 'Unplanned method here', 't')->>'ok')::bool, 'unplanned job refused');
insert into r select 'mach', flow.js_set_machine(:'o', 'embroidery', :'emb', 'Small run suits the single head', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'replan_needed')::bool from r where k = 'mach'), 'machine chosen, re-plan flagged');
select pg_temp.assert((select bool_or(a->>'machine_id' = :'emb') from jsonb_array_elements(flow.scheduler_input()->'assignments') a where a->>'order_id' = :'o'), 'planner is told about the choice');
select pg_temp.assert((select machine_chosen and assignment_reason like 'Small run%' from flow.v_production_queue where order_id = :'o' and method_code = 'embroidery'), 'queue shows the choice and why');
update flow.machines set is_active = false where id = :'emb';
select pg_temp.assert(not (flow.js_set_machine(:'o', 'embroidery', :'emb', 'Switched off machine', 't')->>'ok')::bool, 'a switched-off machine cannot be chosen');
update flow.machines set is_active = true where id = :'emb';
update flow.job_steps set status = 'in_progress' where order_id = :'o' and method_code = 'embroidery';
select pg_temp.assert(not (flow.js_set_machine(:'o', 'embroidery', null, null, 't')->>'ok')::bool, 'cannot change the machine of a running job');
update flow.job_steps set status = 'pending' where order_id = :'o' and method_code = 'embroidery';
select pg_temp.assert((flow.js_set_machine(:'o', 'embroidery', null, 'Let the planner decide', 't')->>'ok')::bool, 'choice can be cleared');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.scheduler_input()->'assignments') a where a->>'order_id' = :'o'), 'cleared choice no longer sent to the planner');

-- operator survives a re-plan write
insert into r select 'op', flow.js_set_operator(:'o', 'embroidery', :'gill', 'tester');
select pg_temp.assert((select j->>'operator' = 'Gill Pick' from r where k = 'op'), 'operator set');
select pg_temp.assert((select operator_name = 'Gill Pick' from flow.v_production_queue where order_id = :'o' and method_code = 'embroidery'), 'queue shows the operator');
select pg_temp.assert((flow.apply_schedule(jsonb_build_object('version', '1', 'generated_at', now(), 'steps', jsonb_build_array(jsonb_build_object('order_id', :'o', 'method_code', 'embroidery', 'step_no', 1, 'units', 12, 'status', 'ready')), 'batches', '[]'::jsonb), 'test')->>'ok')::bool, 'plan applied');
select pg_temp.assert((select operator_id = :'gill'::uuid from flow.job_steps where order_id = :'o' and method_code = 'embroidery'), 'a re-plan keeps the operator');
update flow.operators set is_active = false where name = 'Sam Trew';
select pg_temp.assert(not (flow.js_set_operator(:'o', 'embroidery', (select id from flow.operators where name = 'Sam Trew'), 't')->>'ok')::bool, 'inactive operator refused');
update flow.operators set is_active = true where name = 'Sam Trew';
insert into r select 'opclr', flow.js_set_operator(:'o', 'embroidery', null, 't');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'opclr') and (select operator_id is null from flow.job_steps where order_id = :'o' and method_code = 'embroidery'), 'operator can be cleared');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'job_machine_set') and exists (select 1 from flow.audit_log where action = 'job_operator_set'), 'both audited');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_js_set_machine(uuid,text,uuid,text,text)', 'execute'), 'wrapper closed to browser roles');
\echo assignment_test OK
