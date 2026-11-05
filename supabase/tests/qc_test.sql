-- Quality control and rework: checks, defects, rework lifecycle, re-checks, exceptions, producer quality.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.producers (code, name, turnaround_days, capable_methods) values ('QCP', 'Quality Producer', 3, '{embroidery}');
select id as qp from flow.producers where code = 'QCP' \gset
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values
  ('QCO1', '#Q1', 'Quality Customer', now() + interval '1 day', 'quality_check', true, 1, 40), ('QCO2', '#Q2', 'Other Customer', now() + interval '20 days', 'in_production', true, 1, 10);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select 'QL1', o.id, 'QC-POLO-M', 'Navy', 'M', 'Polo', 40, '{embroidery}' from flow.orders o where o.deco_order_id = 'QCO1';
select id as o1 from flow.orders where deco_order_id = 'QCO1' \gset
select id as o2 from flow.orders where deco_order_id = 'QCO2' \gset
select id as l1 from flow.order_lines where deco_workflow_item_id = 'QL1' \gset
select id as crit1 from flow.qc_criteria where name = 'Stitch quality' \gset

-- 1. seeded checklist exists
select pg_temp.assert((select count(*) from flow.qc_criteria where method_code is null) = 3 and (select count(*) from flow.qc_criteria where method_code = 'embroidery') = 3, 'placeholder checklist seeded');

-- 2. validation
select pg_temp.assert(not (flow.qc_record_check(null, :'o1', 'weird', 10, 0, null, null, null, null, null, null, null, null, 't')->>'ok')::bool, 'unknown gate refused');
select pg_temp.assert(not (flow.qc_record_check(null, :'o1', 'final', 0, 0, null, null, null, null, null, null, null, null, 't')->>'ok')::bool and not (flow.qc_record_check(null, :'o1', 'final', 10, 11, null, null, null, null, null, null, null, null, 't')->>'ok')::bool, 'units checked and failed must make sense');
select pg_temp.assert((flow.qc_record_check(null, :'o1', 'final', 10, 2, null, null, null, null, null, null, null, null, 't')->>'needs_defect')::bool, 'failed units need a defect and a cause');
select pg_temp.assert((flow.qc_record_check(null, :'o1', 'final', 10, 2, null, 'stitching', 'cosmic rays', null, null, null, null, null, 't')->>'needs_defect')::bool, 'cause must be one of the list');
select pg_temp.assert(not (flow.qc_record_check(null, :'o1', 'final', 10, 0, jsonb_build_array(jsonb_build_object('criterion_id', :'crit1', 'passed', false)), null, null, null, null, null, null, null, 't')->>'ok')::bool, 'a failed checklist item needs at least one failed unit');
select pg_temp.assert(not exists (select 1 from flow.qc_checks) and not exists (select 1 from flow.rework_jobs), 'refused checks leave nothing behind');

-- 3. a passing check
insert into r select 'p1', flow.qc_record_check(null, :'o2', 'pre_production', 10, 0, jsonb_build_array(jsonb_build_object('criterion_id', :'crit1', 'passed', true)), null, null, 'Looks right', '[]'::jsonb, null, null, null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'passed' and j->>'check_ref' ~ '^QC-[0-9]{4}-[0-9]{5}$' and j->>'rework_id' is null from r where k = 'p1'), 'pass recorded without rework: ' || (select j::text from r where k = 'p1'));

-- 4. a failing final check opens rework; operator fault = redo
insert into r select 'f1', flow.qc_record_check(null, :'o1', 'final', 40, 6, jsonb_build_array(jsonb_build_object('criterion_id', :'crit1', 'passed', false, 'note', 'puckering')), 'stitching', 'operator', 'Tension too high', '[{"url":"https://x.test/p.jpg","name":"photo"}]'::jsonb, :'l1', null, null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'failed' and j->>'rework_ref' ~ '^RW-' from r where k = 'f1'), 'failed check recorded: ' || (select j::text from r where k = 'f1'));
select j->>'rework_id' as rw1 from r where k = 'f1' \gset
select pg_temp.assert((select units = 6 and outcome = 'redo' and status = 'open' and replacement_status = 'not_needed' and cause = 'operator' from flow.rework_jobs where id = :'rw1'), 'rework job opened for the failed units');
select pg_temp.assert((select results->0->>'criterion' = 'Stitch quality' and not (results->0->>'passed')::boolean from flow.v_qc_checks where check_ref = (select j->>'check_ref' from r where k = 'f1')), 'the read model names the failed checklist item');

-- 5. garment fault = replace and replacement is tracked
insert into r select 'f2', flow.qc_record_check(null, :'o1', 'in_line', 10, 3, null, 'garment_damage', 'garment', 'Holes in the cuffs', null, :'l1', null, 50, 'tester');
select j->>'rework_id' as rw2 from r where k = 'f2' \gset
select pg_temp.assert((select outcome = 'replace' and replacement_status = 'needed' from flow.rework_jobs where id = :'rw2'), 'a garment fault asks for replacements');

-- 6. exceptions block completion while quality is unresolved
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'qc_failed' and status = 'open' and 'completion' = any (blocks) and 'dispatch' = any (blocks)) = 2, 'one blocking exception per open rework job');
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'qc_replacement' and status = 'open') = 1, 'replacement still needed is an exception');
select pg_temp.assert((select severity = 'critical' from flow.exceptions where type_code = 'qc_failed' and description like '%' || (select rework_ref from flow.rework_jobs where id = :'rw1') || '%'), 'due within two days: critical');

-- 7. rework lifecycle
select pg_temp.assert(not (flow.qc_rework_update(:'rw1', 'complete', '{"units_fixed": 5, "units_scrapped": 0}'::jsonb, 't')->>'ok')::bool, 'fixed plus scrapped must add up');
select pg_temp.assert((flow.qc_rework_update(:'rw1', 'assign', '{"assigned_to": "Sam"}'::jsonb, 't')->>'ok')::bool and (flow.qc_rework_update(:'rw1', 'start', '{}'::jsonb, 'tester')->>'ok')::bool, 'assign and start');
select pg_temp.assert(not (flow.qc_rework_update(:'rw1', 'start', '{}'::jsonb, 'tester')->>'ok')::bool, 'cannot start twice');
insert into r select 'c1', flow.qc_rework_update(:'rw1', 'complete', '{"units_fixed": 5, "units_scrapped": 1, "note": "one beyond repair"}'::jsonb, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'recheck_ref' like 'QC-%' from r where k = 'c1'), 'completed, re-check created: ' || (select j::text from r where k = 'c1'));
select pg_temp.assert((select status = 'complete' and units_fixed = 5 and units_scrapped = 1 and replacement_status = 'needed' from flow.rework_jobs where id = :'rw1'), 'scrapped unit needs a replacement');
select pg_temp.assert((select status = 'pending' and gate = 'recheck' and units_checked = 5 and due_by > now() from flow.qc_checks where id = (select (j->>'recheck_id')::uuid from r where k = 'c1')), 'a pending re-check of the fixed units');
-- the re-check passes: fulfils the pending check, not a new one
select (j->>'recheck_id')::uuid as rc1 from r where k = 'c1' \gset
insert into r select 'rc', flow.qc_record_check(:'rc1', null, null, 5, 0, null, null, null, 'All good now', null, null, null, null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'passed' from r where k = 'rc') and (select count(*) from flow.qc_checks where gate = 'recheck') = 1, 're-check completes the pending one');
select pg_temp.assert(not (flow.qc_record_check(:'rc1', null, null, 5, 0, null, null, null, null, null, null, null, null, 't')->>'ok')::bool, 'a check cannot be completed twice');

-- 8. replacement tracking and cancel
select pg_temp.assert(not (flow.qc_rework_update(:'rw2', 'replacement', '{"status": "not_needed"}'::jsonb, 't')->>'ok')::bool, 'not-needed needs a reason');
select pg_temp.assert((flow.qc_rework_update(:'rw2', 'replacement', '{"status": "ordered", "note": "On PO AF-PO-9"}'::jsonb, 't')->>'ok')::bool, 'replacement ordered');
select pg_temp.assert((flow.qc_rework_update(:'rw2', 'cancel', '{"reason": ""}'::jsonb, 't')->>'needs_reason')::bool, 'cancelling needs a reason');
select pg_temp.assert((flow.qc_rework_update(:'rw2', 'cancel', '{"reason": "Customer accepted as is"}'::jsonb, 't')->>'ok')::bool and not (flow.qc_rework_update(:'rw2', 'cancel', '{"reason": "again please"}'::jsonb, 't')->>'ok')::bool, 'cancel once');
-- finish the rest so exceptions clear
select flow.qc_rework_update(:'rw2', 'replacement', '{"status": "received"}'::jsonb, 'tester');
select flow.qc_rework_update(:'rw1', 'replacement', '{"status": "not_needed", "note": "Spare garment used"}'::jsonb, 'tester');
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code in ('qc_failed', 'qc_replacement') and status in ('open', 'investigating')) = 0, 'every quality exception cleared once resolved: ' || (select coalesce(string_agg(description, '; '), '') from flow.exceptions where type_code in ('qc_failed', 'qc_replacement') and status in ('open', 'investigating')));

-- 9. overdue checks and orders left in quality check
insert into r select 'pend', flow.qc_record_check(null, :'o2', 'in_line', 5, 0, null, null, null, null, null, null, null, 10, 'tester');
insert into flow.qc_checks (check_ref, order_id, gate, status, due_by, created_by) values ('QC-TEST-OLD', :'o2', 'final', 'pending', now() - interval '2 hours', 'tester');
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values ('QCO3', '#Q3', 'Stuck Customer', now() + interval '20 days', 'quality_check', true, 1, 5);
select id as o3 from flow.orders where deco_order_id = 'QCO3' \gset
set session_replication_role = replica;
update flow.orders set updated_at = now() - interval '2 days' where id = :'o3';
set session_replication_role = origin;
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'qc_pending' and status = 'open') = 2, 'an overdue check and an order stuck in quality check both raise: ' || (select coalesce(string_agg(description, '; '), '') from flow.exceptions where type_code = 'qc_pending'));
insert into r select 'fin', flow.qc_record_check(null, :'o3', 'final', 5, 0, null, null, null, 'All passed', null, null, null, null, 'tester');
update flow.qc_checks set status = 'cancelled' where check_ref = 'QC-TEST-OLD';
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'qc_pending' and status = 'open') = 0, 'a passing final check and a cancelled overdue check clear them');

-- 10. producer quality
insert into flow.tp_movements (movement_code, producer_id, status) values ('TP-QC-1', :'qp', 'returned');
insert into r select 'pq', flow.qc_record_check(null, :'o1', 'producer_return', 20, 4, null, 'colour', 'producer', null, null, :'l1', 'TP-QC-1', null, 'tester');
select pg_temp.assert((select checks = 1 and units_checked = 20 and units_failed = 4 and pass_rate = 80.0 and open_rework = 1 from flow.v_producer_quality where producer_id = :'qp'), 'producer quality: 80% pass, one open rework');
select pg_temp.assert((select producer_id = :'qp' from flow.rework_jobs where movement_id = (select id from flow.tp_movements where movement_code = 'TP-QC-1')), 'rework carries the producer');

-- 11. queue and criteria
select pg_temp.assert(exists (select 1 from flow.v_qc_queue where order_ref = '#Q1' and open_rework = 1), 'the order with open rework is in the QC queue');
select pg_temp.assert((flow.qc_criterion_set(null, 'embroidery', 'Backing trimmed', 'Backing cut close to the stitching.', true, 'tester')->>'ok')::bool and not (flow.qc_criterion_set(null, 'embroidery', 'backing trimmed', null, true, 'tester')->>'ok')::bool and not (flow.qc_criterion_set(null, 'nope', 'Whatever item', null, true, 'tester')->>'ok')::bool, 'checklist items can be added, no duplicates, method must exist');

-- 12. locked down
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_qc_record_check(uuid,uuid,text,int,int,jsonb,text,text,text,jsonb,uuid,text,int,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_qc_rework_update(uuid,text,jsonb,text)', 'execute')
  and has_function_privilege('service_role', 'public.flow_qc_open_rework(uuid,uuid,int,text,text,text,text,text,text)', 'execute'), 'wrappers locked down');
\echo qc_test OK
