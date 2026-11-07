-- Scope control: in-house switches and per-order scope.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at) values
 ('SCP1', '#SCP1', 'Scope In', now() + interval '9 days', 'ready_for_production', true, 1, 12, now() - interval '2 days'),
 ('SCP2', '#SCP2', 'Scope Out', now() + interval '9 days', 'ready_for_production', true, 1, 12, now() - interval '2 days'),
 ('SCP3', '#SCP3', 'Scope TP', now() + interval '9 days', 'ready_for_production', true, 1, 12, now() - interval '2 days');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
  select 'SCPL' || right(deco_order_id, 1), id, 'SCP-POLO', 'Navy', 'M', 'Polo', 12, '{embroidery}' from flow.orders where deco_order_id like 'SCP%';
select id as o1 from flow.orders where deco_order_id = 'SCP1' \gset
select id as o2 from flow.orders where deco_order_id = 'SCP2' \gset
select id as o3 from flow.orders where deco_order_id = 'SCP3' \gset
update flow.orders set third_party_flag = true where id = :'o3';

create or replace function pg_temp.planned(p_ref text) returns boolean language sql as $f$
  select exists (select 1 from jsonb_array_elements(flow.scheduler_input()->'steps') s join flow.orders o on o.id::text = s->>'order_id' where o.order_ref = p_ref) $f$;

-- scope of an order
select pg_temp.assert((select scope = 'unclassified' and source = 'none' from public.ui_order_scope where order_ref = '#SCP1'), 'no flag, no override: unclassified');
select pg_temp.assert((select scope = 'third_party' and source = 'deco_flag' from public.ui_order_scope where order_ref = '#SCP3'), 'the DecoNetwork flag makes it third party');
select pg_temp.assert(pg_temp.planned('#SCP1') and not pg_temp.planned('#SCP3'), 'planner plans unclassified work and leaves third-party work to the producers');

-- override wins, needs a reason, is audited
select pg_temp.assert((flow.sc_set_order_scope(:'o3', 'in_house', '', 't')->>'needs_reason')::bool, 'override needs a reason');
insert into r select 'ov', flow.sc_set_order_scope(:'o3', 'in_house', 'We will do this one ourselves', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'ov') and pg_temp.planned('#SCP3'), 'override to in-house puts it in the plan');
select pg_temp.assert(not (flow.sc_set_order_scope(:'o3', 'in_house', 'Again please no change', 't')->>'ok')::bool, 'no-op refused');
insert into r select 'ov2', flow.sc_set_order_scope(:'o3', null, 'Back to following DecoNetwork', 'tester');
select pg_temp.assert(not pg_temp.planned('#SCP3'), 'cleared override follows the flag again');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'order_scope') and (select count(*) = 2 from flow.scope_log where kind = 'order' and target = '#SCP3'), 'overrides audited and logged');

-- open consignment blocks moving an order out of third-party work
insert into flow.producers (code, name, turnaround_days, capable_methods) values ('SCPP', 'Scope Producer', 3, '{embroidery}');
insert into flow.tp_movements (movement_code, producer_id, status) select 'TP-SCP-1', id, 'dispatched' from flow.producers where code = 'SCPP';
insert into flow.tp_movement_items (movement_id, order_id, order_line_id, sku, qty_sent, qty_expected_back)
  select m.id, l.order_id, l.id, 'SCP-POLO', 12, 12 from flow.tp_movements m, flow.order_lines l where m.movement_code = 'TP-SCP-1' and l.deco_workflow_item_id = 'SCPL3';
select pg_temp.assert(not (flow.sc_set_order_scope(:'o3', 'out_of_scope', 'Not ours at all now', 't')->>'ok')::bool, 'cannot move an order with an open consignment out of scope');

-- out of scope orders are not planned and their exceptions are not raised
insert into r select 'oos', flow.sc_set_order_scope(:'o2', 'out_of_scope', 'Customer collected it themselves', 'tester');
select pg_temp.assert(not pg_temp.planned('#SCP2'), 'out-of-scope order is not planned');

-- switches
select pg_temp.assert((flow.sc_set_switch('inhouse.master', false, '', 't')->>'needs_reason')::bool, 'switch needs a reason');
select pg_temp.assert(not (flow.sc_set_switch('nope', false, 'Unknown switch here', 't')->>'ok')::bool, 'unknown switch refused');
select pg_temp.assert((flow.sc_preview('inhouse.master', false)->>'ok')::bool, 'preview works');
insert into r select 'prev', flow.sc_preview('inhouse.method.embroidery', false);
select pg_temp.assert((select (j->>'planned_steps') is not null and (j->>'running_steps') is not null from r where k = 'prev'), 'preview reports what it touches');

-- a running job blocks switching off
insert into flow.job_steps (order_id, method_code, step_no, status) values (:'o1', 'embroidery', 1, 'in_progress');
select pg_temp.assert(not (flow.sc_set_switch('inhouse.method.embroidery', false, 'Not doing embroidery in-house', 't')->>'ok')::bool, 'cannot switch off a process with a job running');
update flow.job_steps set status = 'pending' where order_id = :'o1';

update flow.job_steps set status = 'complete' where status = 'in_progress';      -- earlier suites leave running steps behind
insert into r select 'off', flow.sc_set_switch('inhouse.master', false, 'Launch with third-party work only', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'replan_needed')::bool from r where k = 'off'), 'master switched off');
select pg_temp.assert(not flow.inhouse_on() and not pg_temp.planned('#SCP1'), 'nothing is planned in-house while the master is off');
select pg_temp.assert(jsonb_array_length(flow.scheduler_input()->'steps') = 0, 'planner input has no steps at all');
select pg_temp.assert(not (flow.sc_set_switch('inhouse.master', false, 'Already off so nothing', 't')->>'ok')::bool, 'switching to the same state refused');

-- machine downtime exceptions are not raised while off
insert into flow.machines (code, name, method_code, units_per_hour, is_active) values ('SCP-M', 'Scope machine', 'embroidery', 10, true);
insert into r select 'det', flow.exceptions_detect_all();
select pg_temp.assert(not exists (select 1 from flow.exceptions where detector = 'detector:machine_downtime' and status = 'open'), 'no machine exceptions while in-house is off');

insert into r select 'on', flow.sc_set_switch('inhouse.master', true, 'We are starting in-house again', 'tester');
select pg_temp.assert(flow.inhouse_on() and pg_temp.planned('#SCP1'), 'switched back on: planned again');
insert into r select 'meth', flow.sc_set_switch('inhouse.method.embroidery', false, 'Embroidery goes to producers', 'tester');
select pg_temp.assert(not flow.inhouse_on('embroidery') and flow.inhouse_on('heat_press') and not pg_temp.planned('#SCP1'), 'per-process switch works');
insert into r select 'meth_on', flow.sc_set_switch('inhouse.method.embroidery', true, 'Embroidery is back in-house', 'tester');
select pg_temp.assert((select count(*) from flow.scope_log where kind = 'switch') >= 4 and exists (select 1 from flow.audit_log where action = 'scope_switch'), 'switch changes logged and audited');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_sc_set_switch(text,boolean,text,text)', 'execute'), 'wrapper closed to browser roles');
-- the read views must work for a logged-in browser user (permission to the helper functions)
set role authenticated;
select count(*) from public.ui_order_scope;
select count(*) from public.ui_scope_switches;
select count(*) from public.ui_scope_log;
reset role;
\echo scope_test OK
