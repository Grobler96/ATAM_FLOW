-- Producer risk: score and reasons, suspend/resume enforcement, limits, recovery options, checkpoint exceptions, job sheet draft.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.producers (code, name, contact_name, email, turnaround_days, capable_methods, special_instructions) values
  ('RSK', 'Risky Stitchers', 'Rita', 'rita@risky.test', 3, '{embroidery}', 'No backing show-through'), ('ALT', 'Alternative Embroidery', null, null, 4, '{embroidery}', null), ('SAFE', 'Safe Hands Ltd', 'Sol', 'sol@safe.test', 2, '{embroidery}', null);
select id as rsk from flow.producers where code = 'RSK' \gset
select id as alt from flow.producers where code = 'ALT' \gset
select id as safe from flow.producers where code = 'SAFE' \gset
insert into flow.producer_stats (producer_id, units_held, value_held, open_jobs, on_time_rate, discrepancy_rate) values (:'rsk', 20, 240, 1, 60, 10) on conflict (producer_id) do update set units_held = 20, value_held = 240, open_jobs = 1, on_time_rate = 60, discrepancy_rate = 10;
insert into flow.tp_movements (movement_code, producer_id, status, dispatch_date, expected_return_date) values ('TP-RSK-1', :'rsk', 'dispatched', current_date - 5, current_date - 1);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values ('PRK1', '#PRK1', 'Risk Customer', now() + interval '10 days', 'ready_for_production', true, 1, 24);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods) select 'PRKL1', id, 'PRK-POLO-M', 'Navy', 'M', 'Polo', 24, '{embroidery}' from flow.orders where deco_order_id = 'PRK1';
select id as prkl from flow.order_lines where deco_workflow_item_id = 'PRKL1' \gset
insert into flow.tp_movement_items (movement_id, order_id, order_line_id, sku, qty_sent, qty_expected_back) select m.id, l.order_id, l.id, l.sku, 20, 20 from flow.tp_movements m, flow.order_lines l where m.movement_code = 'TP-RSK-1' and l.deco_workflow_item_id = 'PRKL1';

-- 1. score: late 12 + discrepancy 15 + overdue 8 + unconfirmed receipt 10 = 45 -> high, with reasons
select pg_temp.assert((select risk_score = 45 and risk_rating = 'high' and cardinality(reasons) = 4 from flow.v_producer_risk where producer_id = :'rsk'), 'risk 45 high with four reasons: ' || (select row_to_json(x)::text from flow.v_producer_risk x where producer_id = :'rsk'));
select pg_temp.assert((select risk_rating = 'low' from flow.v_producer_risk where producer_id = :'safe') or (select risk_score <= 10 from flow.v_producer_risk where producer_id = :'safe'), 'a producer with no history is low risk');

-- 2. recovery options
insert into r select 'rec', flow.pr_recovery(:'rsk');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'units_held')::int = 20 and jsonb_array_length(j->'held') = 1 and (select bool_or(o->>'kind' = 'resource') from jsonb_array_elements(j->'options') o) and (select bool_or(o->>'kind' = 'suspend') from jsonb_array_elements(j->'options') o) from r where k = 'rec'), 'recovery lists held goods, alternatives and a suspend suggestion: ' || (select j::text from r where k = 'rec'));
select pg_temp.assert((select j->'alternatives'->0->>'name' is not null and not exists (select 1 from jsonb_array_elements(j->'alternatives') a where a->>'name' = 'Risky Stitchers') from r where k = 'rec'), 'the producer is never offered as its own alternative');

-- 3. contact + limits
select pg_temp.assert((flow.pr_record_contact(:'rsk', '', 't')->>'needs_reason')::bool, 'contact note required');
insert into r select 'ct', flow.pr_record_contact(:'rsk', 'Spoke to Rita, back Friday', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'ct') and (select last_contact_note like 'Spoke%' from flow.producers where id = :'rsk'), 'contact recorded');
insert into r select 'lm', flow.pr_set_limits(:'rsk', 'Rita Boss', '07000 000000', array['alt', 'rsk', 'NOPE'], null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'lm') and (select backup_producer_ids = array[:'alt'::uuid] and emergency_phone = '07000 000000' from flow.producers where id = :'rsk'), 'limits set; backups resolved by code, self and unknown ignored');
select pg_temp.assert(not (flow.pr_set_limits(:'rsk', null, null, null, 0, 't')->>'ok')::bool, 'job limit must be positive');
select pg_temp.assert((select (select bool_or(a->>'is_backup' = 'true') from jsonb_array_elements(flow.pr_recovery(:'rsk')->'alternatives') a)), 'backup flagged in the alternatives');

-- 4. suspend: reason needed, blocks new work (direct insert and the normal create function), resume
select pg_temp.assert((flow.pr_suspend(:'rsk', 'no', 't')->>'needs_reason')::bool, 'suspension needs a real reason');
insert into r select 'sus', flow.pr_suspend(:'rsk', 'Lost two consignments in a month', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'message' like '%still hold 20%' from r where k = 'sus'), 'suspended; the message mentions goods still held');
select pg_temp.assert(not (flow.pr_suspend(:'rsk', 'again please', 't')->>'ok')::bool, 'cannot suspend twice');
do $$ begin
  begin insert into flow.tp_movements (movement_code, producer_id) values ('TP-RSK-NEW', (select id from flow.producers where code = 'RSK')); raise exception 'should not be allowed';
  exception when others then if sqlerrm not like '%suspended%' then raise; end if; end;
end $$;
insert into r select 'blocked', flow.create_outbound_movement(:'rsk', jsonb_build_array(jsonb_build_object('order_line_id', :'prkl', 'qty', 10)), 'tester');
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like '%suspended%' from r where k = 'blocked') and not exists (select 1 from flow.tp_movements where producer_id = :'rsk' and created_at > now() - interval '1 minute' and movement_code <> 'TP-RSK-1'), 'a suspended producer cannot be sent work and nothing is left behind: ' || (select j::text from r where k = 'blocked'));
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'producer_at_risk' and status = 'open' and description like 'Risky Stitchers is high risk%') = 1, 'a high-risk producer holding goods raises an exception');
select pg_temp.assert((flow.pr_resume(:'rsk', '', 't')->>'needs_reason')::bool, 'resume needs a reason');
insert into r select 'rs', flow.pr_resume(:'rsk', 'Cause found and fixed with Rita', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'rs') and not (select is_suspended from flow.producers where id = :'rsk'), 'resumed with a reason');
select pg_temp.assert(not (flow.pr_resume(:'rsk', 'not suspended any more', 't')->>'ok')::bool, 'cannot resume what is not suspended');

-- 5. job limit
select flow.pr_set_limits(:'rsk', null, null, null, 1, 'tester');
insert into r select 'lim', flow.create_outbound_movement(:'rsk', jsonb_build_array(jsonb_build_object('order_line_id', :'prkl', 'qty', 10)), 'tester');
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like '%limit of 1 open job%' from r where k = 'lim'), 'a producer at its job limit is refused: ' || (select j::text from r where k = 'lim'));
select flow.pr_set_limits(:'rsk', null, null, null, null, 'tester');

-- 6. silence checkpoint
insert into flow.tp_movements (movement_code, producer_id, status, dispatch_date) values ('TP-SIL-1', :'safe', 'in_production', current_date - 8);
insert into flow.tp_movement_events (movement_id, at, event, actor) select id, now() - interval '6 days', 'production_started', 't' from flow.tp_movements where movement_code = 'TP-SIL-1';
select flow.exceptions_detect_all();
select pg_temp.assert((select count(*) from flow.exceptions where type_code = 'producer_no_update' and status in ('open', 'awaiting_producer') and description like 'TP-SIL-1%') = 1, 'no update for six days raises a checkpoint exception: ' || (select coalesce(string_agg(description, '; '), '') from flow.exceptions where type_code = 'producer_no_update'));

-- 7. job sheet draft
insert into r select 'mv', flow.create_outbound_movement(:'safe', jsonb_build_array(jsonb_build_object('order_line_id', :'prkl', 'qty', 4)), 'tester', null, 'courier', 'fragile');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'mv'), 'movement for the job sheet: ' || (select j::text from r where k = 'mv'));
select j->>'movement_code' as mvc from r where k = 'mv' \gset
insert into r select 'js', flow.mv_job_sheet_draft(:'mvc', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'no_recipient')::bool from r where k = 'js') and (select status = 'pending_review' and kind = 'producer_job' and to_addresses = '{sol@safe.test}' and subject like 'Job sheet: ' || :'mvc' || ' (4 units%' and body_text like '%4 x PRK-POLO-M%' and body_text like 'Hello Sol%' from flow.communications where entity_type = 'movement' and entity_id = (select id from flow.tp_movements where movement_code = :'mvc')), 'job sheet drafted for review with the lines and the contact: ' || (select coalesce(string_agg(subject || ' / ' || body_text, ' | '), 'none') from flow.communications where kind = 'producer_job'));
insert into r select 'js2', flow.mv_job_sheet_draft(:'mvc', 'tester');
select pg_temp.assert((select (j->>'already_queued')::bool from r where k = 'js2'), 'a second job sheet is not queued while one waits');
select pg_temp.assert(not (flow.mv_job_sheet_draft('TP-NOPE', 't')->>'ok')::bool, 'unknown movement refused');

-- 8. locked down
select pg_temp.assert(not has_function_privilege('anon', 'public.flow_pr_suspend(uuid,text,text)', 'execute') and not has_function_privilege('authenticated', 'public.flow_pr_suspend(uuid,text,text)', 'execute') and has_function_privilege('service_role', 'public.flow_mv_job_sheet_draft(text,text)', 'execute')
  and not has_function_privilege('anon', 'public.ui_pr_recovery(uuid)', 'execute') and has_function_privilege('authenticated', 'public.ui_pr_recovery(uuid)', 'execute'), 'wrappers locked down');
\echo producer_risk_test OK
