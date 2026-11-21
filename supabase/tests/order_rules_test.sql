-- Order tags and routing rules (shadow mode): tags, first-match routing, precedence, safety, permissions.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

-- fixtures ---------------------------------------------------------------------------------------------------------------------
insert into flow.producers (code, name) values ('DPSX', 'DPS test') on conflict (code) do nothing;
select id as dps from flow.producers where code = 'DPSX' \gset
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, third_party_flag) values
 ('RR1', '#RR1', 'Plain',      now() + interval '9 days', 'awaiting_stock', false, 1, 21, now() - interval '2 days', false),
 ('RR2', '#RR2', 'Twenty',     now() + interval '9 days', 'awaiting_stock', false, 1, 20, now() - interval '2 days', false),
 ('RR3', '#RR3', 'Flagged',    now() + interval '9 days', 'awaiting_stock', false, 1, 30, now() - interval '2 days', true),
 ('RR4', '#RR4', 'Manual',     now() + interval '9 days', 'awaiting_stock', false, 1, 30, now() - interval '2 days', false),
 ('RR5', '#RR5', 'Started',    now() + interval '9 days', 'in_production',        true, 1, 30, now() - interval '2 days', false),
 ('RR6', '#RR6', 'No facts',   now() + interval '9 days', 'awaiting_stock', false, 1, 30, now() - interval '2 days', false);
select id as o1 from flow.orders where deco_order_id = 'RR1' \gset
select id as o2 from flow.orders where deco_order_id = 'RR2' \gset
select id as o3 from flow.orders where deco_order_id = 'RR3' \gset
select id as o4 from flow.orders where deco_order_id = 'RR4' \gset
select id as o5 from flow.orders where deco_order_id = 'RR5' \gset
select id as o6 from flow.orders where deco_order_id = 'RR6' \gset
select flow.sc_set_order_scope(:'o4', 'in_house', 'We are doing this one ourselves', 'tester');

-- starting set exists, and the mode cannot be anything but shadow -------------------------------------------------------------
select pg_temp.assert((select mode = 'shadow' from flow.routing_settings), 'starts in shadow mode');
select pg_temp.assert(exists (select 1 from flow.tag_definitions where code = 'person_packing' and label = 'Requires person packing'), 'person packing tag is seeded');
select pg_temp.assert(exists (select 1 from flow.routing_rules where kind = 'decorations_over' and params->>'n' = '20' and outcome_scope = 'third_party'), 'the more-than-20 rule is seeded');
do $$ begin
  begin update flow.routing_settings set mode = 'live'; raise exception 'live was allowed';
  exception when check_violation then null; end;
end $$;
-- point the seeded rule at the test producer through the audited function
select id as rule20 from flow.routing_rules where name = 'More than 20 decorations' \gset
insert into r select 'edit', flow.rr_save_routing_rule(:'rule20', 10, 'More than 20 decorations', 'decorations_over', '{"n":20}', 'third_party', :'dps', true, 'tester', 'Send big orders to DPS');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'edit'), 'rule edit accepted: ' || (select j::text from r where k = 'edit'));
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, third_party_flag)
 values ('RR7', '#RR7', 'Gone', now() - interval '3 days', 'dispatched', true, 9, 30, now() - interval '9 days', false);
select id as o7 from flow.orders where deco_order_id = 'RR7' \gset

-- facts: 7 garments x 3 decorations = 21 is over 20; exactly 20 is not ----------------------------------------------------------
insert into r select 'ingest', flow.order_facts_ingest(jsonb_build_array(
  jsonb_build_object('order_id', 'RR1', 'decoration_count', 21, 'custom_fields', jsonb_build_object('Uniform For', jsonb_build_array('Jenni Young', 'jenni young ', ' ', 'Nathan Atkin'), 'Size', jsonb_build_array())),
  jsonb_build_object('order_id', 'RR2', 'decoration_count', 20, 'custom_fields', '{}'::jsonb),
  jsonb_build_object('order_id', 'RR3', 'decoration_count', 25),
  jsonb_build_object('order_id', 'RR4', 'decoration_count', 25),
  jsonb_build_object('order_id', 'RR5', 'decoration_count', 25),
  jsonb_build_object('order_id', 'NOT-OURS', 'decoration_count', 99),
  jsonb_build_object('order_id', 'RR2', 'decoration_count', -4)), 'test');
select pg_temp.assert((select (j->>'saved')::int = 5 and (j->>'not_in_flow')::int = 1 and (j->>'rejected')::int = 1 from r where k = 'ingest'), 'ingest counts: ' || (select j::text from r where k = 'ingest'));
select pg_temp.assert(not (flow.order_facts_ingest('{"a":1}'::jsonb, 't')->>'ok')::bool, 'a list is required');

-- 21 decorations: would move to DPS, but nothing is changed
select pg_temp.assert((select outcome = 'would_change' and would_scope = 'third_party' and would_producer_id = :'dps' and current_scope = 'unclassified' from public.ui_routing_decisions d where order_ref = '#RR1'), 'RR1: 21 decorations would go to DPS (shadow)');
select pg_temp.assert((select scope = 'unclassified' from public.ui_order_scope where order_ref = '#RR1'), 'RR1: the real scope is untouched in shadow mode');
select pg_temp.assert((select third_party_flag = false and scope_override is null and producer_id is null from flow.orders where id = :'o1'), 'RR1: no order column was changed');
-- exactly 20: not "more than 20"
select pg_temp.assert((select outcome = 'no_rule_matched' from flow.routing_decisions where order_id = :'o2'), 'RR2: exactly 20 does not match');
-- already third party by flag
select pg_temp.assert((select outcome = 'already_matches' from flow.routing_decisions where order_id = :'o3'), 'RR3: Priority flag agrees with the rule');
-- a manual scope wins
select pg_temp.assert((select outcome = 'manual_wins' from flow.routing_decisions where order_id = :'o4'), 'RR4: manual scope wins over the rule');
select pg_temp.assert((select scope = 'in_house' and source = 'override' from public.ui_order_scope where order_ref = '#RR4'), 'RR4: manual scope still in force');
-- work already started: left alone, flagged
select pg_temp.assert((select outcome = 'protected' from flow.routing_decisions where order_id = :'o5'), 'RR5: an order with work started is protected');
-- a dispatched order is never moved, even with far more than 20 decorations
insert into r select 'rr7', flow.order_facts_ingest('[{"order_id":"RR7","decoration_count":60}]'::jsonb, 'test');
select pg_temp.assert((select outcome = 'protected' and rule_scope = 'third_party' and detail like '%already been dispatched%' from flow.routing_decisions where order_id = :'o7'), 'RR7: a dispatched order is left alone, with the reason');
select pg_temp.assert((select scope = 'unclassified' from public.ui_order_scope where order_ref = '#RR7'), 'RR7: its real scope is untouched');
-- an inactive order is re-checked too when a rule changes (a dispatched order is inactive in real data)
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, third_party_flag, is_active)
 values ('RR8', '#RR8', 'Inactive', now() + interval '9 days', 'awaiting_stock', false, 1, 30, now() - interval '9 days', false, false);
select id as o8 from flow.orders where deco_order_id = 'RR8' \gset
insert into r select 'rr8', flow.order_facts_ingest('[{"order_id":"RR8","decoration_count":60}]'::jsonb, 'test');
select pg_temp.assert((select outcome = 'would_change' from flow.routing_decisions where order_id = :'o8'), 'RR8: starts as would change');
update flow.orders set order_status = 'dispatched' where id = :'o8';
insert into r select 'all', flow.rules_evaluate_all('test');
select pg_temp.assert((select outcome = 'protected' from flow.routing_decisions where order_id = :'o8'), 'RR8: an inactive order is refreshed by a re-check of everything');
-- no facts, no decision
select pg_temp.assert(not exists (select 1 from flow.routing_decisions where order_id = :'o6'), 'RR6: no facts means no decision');
select pg_temp.assert((flow.rules_evaluate_order(:'o6')->>'skipped') = 'no facts yet', 'RR6: evaluating without facts is skipped');

-- tags: two distinct people (case and spacing ignored, blanks ignored) -----------------------------------------------------------
select pg_temp.assert((select quantity = 2 and label = 'Requires person packing' from public.ui_order_tags where order_ref = '#RR1'), 'RR1: tagged person packing with 2 distinct names');
select pg_temp.assert(not exists (select 1 from flow.order_tags where order_id in (:'o2', :'o3')), 'orders with no names get no tag');

-- idempotent, and a changed order updates its tag and decision ---------------------------------------------------------------------
insert into r select 'again', flow.order_facts_ingest('[{"order_id":"RR1","decoration_count":21,"custom_fields":{"Uniform For":["Jenni Young","Nathan Atkin"]}}]'::jsonb, 'test');
select pg_temp.assert((select count(*) = 1 from flow.order_tags where order_id = :'o1'), 'reading again does not duplicate the tag');
insert into r select 'change', flow.order_facts_ingest('[{"order_id":"RR1","decoration_count":5,"custom_fields":{"Uniform For":[]}}]'::jsonb, 'test');
select pg_temp.assert(not exists (select 1 from flow.order_tags where order_id = :'o1'), 'names removed: the tag goes');
select pg_temp.assert((select outcome = 'no_rule_matched' from flow.routing_decisions where order_id = :'o1'), 'fewer decorations: no longer matches');

-- adding a tag and a rule without code ---------------------------------------------------------------------------------------------
insert into r select 'badreason', flow.rr_save_tag_rule(null, 'folding', 'Needs folding', 'Many units', 'units_over', '{"n":10}', true, 'tester', 'x');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'badreason'), 'a reason is required');
insert into r select 'badparams', flow.rr_save_tag_rule(null, 'folding', 'Needs folding', 'Many units', 'units_over', '{"n":"lots"}', true, 'tester', 'Folding section');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'badparams'), 'bad settings are refused');
select pg_temp.assert(not exists (select 1 from flow.tag_definitions where code = 'folding'), 'a refused rule leaves no half-made tag behind');
insert into r select 'newtag', flow.rr_save_tag_rule(null, 'folding', 'Needs folding', 'More than 10 units', 'units_over', '{"n":10}', true, 'tester', 'Orders over 10 units go to folding');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'newtag'), 'a new tag rule can be added: ' || (select j::text from r where k = 'newtag'));
select pg_temp.assert((select quantity = 30 from flow.order_tags where order_id = :'o3' and tag_code = 'folding'), 'existing orders are tagged straight away (30 units)');
select pg_temp.assert((select quantity = 20 from flow.order_tags where order_id = :'o2' and tag_code = 'folding'), '20 units is over 10, so it is tagged too');
select pg_temp.assert((select count(*) = 2 from flow.audit_log where entity in ('tag_rules', 'routing_rules') and actor = 'tester' and reason is not null), 'each rule change is audited with its reason (edit + new tag rule)');

-- a routing rule that uses a tag, placed ahead of the first one: first match wins by position ------------------------------------------
insert into r select 'tagrule', flow.rr_save_routing_rule(null, 5, 'Named orders stay in house', 'tag_present', '{"tag":"person_packing"}', 'in_house', null, true, 'tester', 'Trial: keep named orders here');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'tagrule'), 'a tag-based routing rule can be added: ' || (select j::text from r where k = 'tagrule'));
insert into r select 'names', flow.order_facts_ingest('[{"order_id":"RR1","decoration_count":40,"custom_fields":{"Uniform For":["Jenni Young"]}}]'::jsonb, 'test');
select pg_temp.assert((select rule_name = 'Named orders stay in house' and rule_scope = 'in_house' and outcome = 'would_change' from flow.routing_decisions where order_id = :'o1'), 'position 5 runs before position 10 even though 40 decorations also match the other rule');
select pg_temp.assert((select count(*) = 1 from flow.routing_decisions where order_id = :'o1'), 'one decision per order');
insert into r select 'badprod', flow.rr_save_routing_rule(null, 20, 'Bad', 'units_over', '{"n":5}', 'in_house', :'dps', true, 'tester', 'In house with a producer');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'badprod'), 'an in-house result cannot name a producer');
insert into r select 'notag', flow.rr_save_routing_rule(null, 20, 'Bad', 'tag_present', '{"tag":"nope"}', 'third_party', null, true, 'tester', 'Unknown tag');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'notag'), 'a rule about a tag that does not exist is refused');

-- switching a rule off removes it from consideration ------------------------------------------------------------------------------------------
select id as rule5 from flow.routing_rules where name = 'Named orders stay in house' \gset
insert into r select 'off', flow.rr_save_routing_rule(:'rule5', 5, 'Named orders stay in house', 'tag_present', '{"tag":"person_packing"}', 'in_house', null, false, 'tester', 'Trial finished');
select pg_temp.assert((select rule_name = 'More than 20 decorations' from flow.routing_decisions where order_id = :'o1'), 'rule off: the next rule decides');

-- the real order data was never touched by any of this -------------------------------------------------------------------------------------------
select pg_temp.assert((select count(*) = 0 from flow.orders where deco_order_id in ('RR1','RR2','RR3','RR5','RR6') and (scope_override is not null or producer_id is not null)), 'no order got a scope or producer from the rules');
select pg_temp.assert((select count(*) = 1 from flow.flow_runs where workflow = 'order_facts' and summary->>'not_in_flow' = '1'), 'each read is logged');

-- permissions ------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_order_facts_ingest(jsonb,text)', 'execute'), 'ingest wrapper closed to browser roles');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_rr_save_tag_rule(uuid,text,text,text,text,jsonb,boolean,text,text)', 'execute'), 'tag rule wrapper closed to browser roles');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_rr_save_routing_rule(uuid,int,text,text,jsonb,text,uuid,boolean,text,text)', 'execute'), 'routing rule wrapper closed to browser roles');
select pg_temp.assert(has_function_privilege('service_role', 'public.flow_rr_save_routing_rule(uuid,int,text,text,jsonb,text,uuid,boolean,text,text)', 'execute'), 'n8n can call the rule wrapper');
select pg_temp.assert(not has_table_privilege('authenticated', 'flow.routing_rules', 'insert') and not has_table_privilege('authenticated', 'flow.order_tags', 'update'), 'staff cannot write the rule tables directly');
select pg_temp.assert(has_table_privilege('authenticated', 'public.ui_routing_decisions', 'select'), 'staff can read the decisions view');
\echo order_rules_test OK
