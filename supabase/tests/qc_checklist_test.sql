-- Real QC checklists: placeholder handling, required/critical/photo rules, snapshots, sign-off, detector.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values ('QKO1', '#QK1', 'Checklist Customer', now() + interval '3 days', 'quality_check', true, 1, 20);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select 'QKL1', o.id, 'QK-TEE-M', 'Black', 'M', 'Tee', 20, '{dtf}' from flow.orders o where o.deco_order_id = 'QKO1';
select id as o1 from flow.orders where deco_order_id = 'QKO1' \gset

-- 1. starter items are placeholders and do not block
select pg_temp.assert((select count(*) from flow.qc_criteria where created_by = 'seed (placeholder)' and is_placeholder and not is_required) >= 1, 'starter items marked as placeholders and not required');
select pg_temp.assert((flow.qc_record_check(null, :'o1', 'final', 5, 0, null, null, null, null, null, null, null, null, 'ck')->>'ok')::bool, 'a check with only placeholder items is still allowed');

-- 2. cannot confirm while placeholders are in use
select pg_temp.assert(not (flow.qc_confirm_checklist('x', 'mgr')->>'ok')::bool, 'cannot confirm with starter items');
select pg_temp.assert(not (select is_confirmed from public.ui_qc_standards), 'not confirmed');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.exc_detect_qc_checklist()) x where x->>'type' = 'qc_checklist_unconfirmed'), 'detector flags checks done against an unconfirmed checklist');

-- 3. save real items: required, critical, photo, stage-limited
select pg_temp.assert((flow.qc_criterion_save(jsonb_build_object('name', 'Test print position', 'method', 'dtf', 'gates', jsonb_build_array('final'), 'required', true), 'mgr')->>'ok')::bool, 'item saved');
select pg_temp.assert((flow.qc_criterion_save(jsonb_build_object('name', 'Test no cracking', 'method', 'dtf', 'required', true, 'critical', true, 'needs_photo', true), 'mgr')->>'ok')::bool, 'critical photo item saved');
select pg_temp.assert(not (flow.qc_criterion_save(jsonb_build_object('name', 'ab'), 'mgr')->>'ok')::bool, 'name needed');
select pg_temp.assert(not (flow.qc_criterion_save(jsonb_build_object('name', 'Test bad stage', 'gates', jsonb_build_array('nowhere')), 'mgr')->>'ok')::bool, 'unknown stage refused');
select id as c_pos from flow.qc_criteria where name = 'Test print position' \gset
select id as c_crack from flow.qc_criteria where name = 'Test no cracking' \gset

-- 4. required items must be answered at the stage they apply to; other stages are not asked
select pg_temp.assert(not (flow.qc_record_check(null, :'o1', 'final', 5, 0, jsonb_build_array(jsonb_build_object('criterion_id', :'c_crack', 'passed', true)), null, null, null, null, null, null, null, 'ck')->>'ok')::bool, 'missing required item refused at final');
select pg_temp.assert((select error from (select flow.qc_record_check(null, :'o1', 'final', 5, 0, '[]'::jsonb, null, null, null, null, null, null, null, 'ck')->>'error' as error) s) like '%Test print position%', 'missing item is named');
select pg_temp.assert((flow.qc_check_results(:'o1', 'in_line', null, jsonb_build_array(jsonb_build_object('criterion_id', :'c_crack', 'passed', true)), null, null)) is null, 'stage-limited item not required at other stages');

-- 5. a failed item needs a note, a failed photo item needs evidence
select pg_temp.assert(flow.qc_check_results(:'o1', 'final', null, jsonb_build_array(jsonb_build_object('criterion_id', :'c_pos', 'passed', true), jsonb_build_object('criterion_id', :'c_crack', 'passed', false)), '[]'::jsonb, null) like '%say what is wrong%', 'failed item needs a note');
select pg_temp.assert(flow.qc_check_results(:'o1', 'final', null, jsonb_build_array(jsonb_build_object('criterion_id', :'c_pos', 'passed', true), jsonb_build_object('criterion_id', :'c_crack', 'passed', false, 'note', 'cracked on fold')), '[]'::jsonb, null) like '%photo%', 'failed photo item needs evidence');
select pg_temp.assert(flow.qc_check_results(:'o1', 'final', null, jsonb_build_array(jsonb_build_object('criterion_id', :'c_pos', 'passed', true), jsonb_build_object('criterion_id', :'c_crack', 'passed', false, 'note', 'cracked on fold')), jsonb_build_array(jsonb_build_object('url', 'https://x.test/a.jpg')), null) is null, 'note plus evidence accepted');
select pg_temp.assert(flow.qc_check_results(:'o1', 'final', null, jsonb_build_array(jsonb_build_object('criterion_id', gen_random_uuid(), 'passed', true)), null, null) like '%no longer exists%', 'unknown item refused');

-- 6. a good check stores a snapshot of each item
insert into flow.qc_checks (check_ref, order_id, gate, status, units_checked, units_failed, results, created_by) values ('QC-SNAP', :'o1', 'final', 'passed', 1, 0, '[]', 'ck');
select pg_temp.assert((flow.qc_record_check(null, :'o1', 'final', 5, 0, jsonb_build_array(jsonb_build_object('criterion_id', :'c_pos', 'passed', true), jsonb_build_object('criterion_id', :'c_crack', 'passed', true)), null, null, null, null, null, null, null, 'ck')->>'ok')::bool, 'complete check recorded');
select pg_temp.assert((select results->0->>'name' from flow.qc_checks where order_id = :'o1' and check_ref <> 'QC-SNAP' and results <> '[]' order by checked_at desc limit 1) is not null, 'name snapshot stored');
select pg_temp.assert((select bool_or((e->>'critical')::boolean) from flow.qc_checks c, jsonb_array_elements(c.results) e where c.order_id = :'o1' and c.check_ref <> 'QC-SNAP'), 'critical flag snapshot stored');

-- 7. editing bumps the version and clears the placeholder flag; confirm after replacing starters
select flow.qc_criterion_save(jsonb_build_object('id', :'c_pos', 'name', 'Test print position', 'required', true), 'mgr');
select pg_temp.assert((select version from flow.qc_criteria where id = :'c_pos') = 2, 'edit bumps version');
update flow.qc_criteria set is_active = false where is_placeholder;
select pg_temp.assert((flow.qc_confirm_checklist('Our standards, signed off', 'mgr')->>'ok')::bool, 'confirmed once starters are off');
select pg_temp.assert((select is_confirmed from public.ui_qc_standards), 'standards confirmed');
select pg_temp.assert(jsonb_array_length(flow.exc_detect_qc_checklist()) = 0, 'detector quiet once confirmed');
select flow.qc_criterion_save(jsonb_build_object('id', :'c_pos', 'name', 'Test print position', 'description', 'edited after sign-off'), 'mgr');
select pg_temp.assert(not (select is_confirmed from public.ui_qc_standards), 'editing after sign-off needs a new confirmation');
select pg_temp.assert(pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) like '%qc_checklist%' and pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) like '%stocktakes%', 'detector list keeps earlier detectors');
\echo qc_checklist_test OK
