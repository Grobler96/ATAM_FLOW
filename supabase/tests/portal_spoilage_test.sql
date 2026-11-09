-- Decorators report spoiled units from the portal: own jobs only, capped by units sent, always a suggestion until a person confirms it.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'false') where key = 'artwork.options';
insert into flow.producers (code, name, address, contact_name, turnaround_days, can_direct_dispatch, capable_methods) values
  ('PSA', 'Spoilage Stitchers', '1 Mill St', 'Sam', 3, false, '{embroidery}'), ('PSB', 'Spoilage Others', '2 Dock Rd', 'Nia', 3, false, '{embroidery}');
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, priority, total_units, created_at) values
  ('PSP1', '#PSP1', 'Spoil FC', now() + interval '10 days', 'ready_for_production', true, 1, 0, 5, now() - interval '2 days'),
  ('PSP2', '#PSP2', 'Spoil Other', now() + interval '10 days', 'ready_for_production', true, 1, 0, 4, now() - interval '2 days');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, garment_type, product_name, qty_required, decoration_methods)
  select v.wi, o.id, v.sku, 'Navy', 'M', 'Polos', 'Polo shirt', v.q, '{embroidery}' from (values ('PSL1', 'PSP1', 'PSP-POLO-M', 5), ('PSL2', 'PSP2', 'PSP-POLO-L', 4)) v(wi, oid, sku, q) join flow.orders o on o.deco_order_id = v.oid;
select flow.generate_bins('OUT', 'PSP', 6);
select id as psa from flow.producers where code = 'PSA' \gset
select id as psb from flow.producers where code = 'PSB' \gset
select id as psl1 from flow.order_lines where deco_workflow_item_id = 'PSL1' \gset
select id as psl2 from flow.order_lines where deco_workflow_item_id = 'PSL2' \gset
insert into r select 'a', flow.create_outbound_movement(:'psa', jsonb_build_array(jsonb_build_object('order_line_id', :'psl1', 'qty', 5)), 'wh');
insert into r select 'b', flow.create_outbound_movement(:'psb', jsonb_build_array(jsonb_build_object('order_line_id', :'psl2', 'qty', 4)), 'wh');
select j->>'movement_code' as mva from r where k = 'a' \gset
select j->>'movement_code' as mvb from r where k = 'b' \gset
select flow.tp_scan(:'mva', 'picked', 'w'); select flow.tp_scan(:'mva', 'packed', 'w'); select flow.tp_scan(:'mva', 'dispatched', 'w', '{"date":"2026-11-09"}');
select flow.tp_scan(:'mvb', 'picked', 'w'); select flow.tp_scan(:'mvb', 'packed', 'w'); select flow.tp_scan(:'mvb', 'dispatched', 'w', '{"date":"2026-11-09"}');
select i.id as ita from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where m.movement_code = :'mva' \gset
select i.id as itb from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id where m.movement_code = :'mvb' \gset

select (flow.pp_add_user(:'psa', 'sam@spoilage.test', 'Sam', 'tester')->>'ok')::bool as u1 \gset
select (flow.pp_add_user(:'psb', 'nia@spoilage.test', 'Nia', 'tester')->>'ok')::bool as u2 \gset
-- sign-in accounts are created AFTER the invitation, as in real use (inviting an address that already has a login is refused)
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000c1', 'sam@spoilage.test', now()), ('00000000-0000-0000-0000-0000000000c2', 'nia@spoilage.test', now());
select pg_temp.assert(:'u1'::bool and :'u2'::bool, 'users added');

-- 1. Sam has the job but has not checked in yet: spoilage is refused (damage on arrival belongs in the check-in)
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
set role authenticated;
insert into r select 'early', public.portal_report_spoilage(:'mva', :'ita'::uuid, 1, 'stained', 'Mark on the sleeve', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'early'), 'not before the goods are checked in');
insert into r select 'ci', public.portal_check_in(:'mva', jsonb_build_array(jsonb_build_object('item_id', :'ita', 'qty_counted', 5, 'qty_damaged', 0)), null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'ci'), 'clean check-in');

-- 2. a proper report
insert into r select 'ok1', public.portal_report_spoilage(:'mva', :'ita'::uuid, 2, 'stained', 'Two shirts marked by the machine oil', null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'ok1'), 'a report is accepted');
reset role;
select pg_temp.assert((select status = 'suggested' and qty = 2 and party = 'decorator' and stage = 'decorator' and cause_code = 'decorator_spoilage' and recorded_by like 'producer:%' and order_ref = '#PSP1'
                         from flow.waste_events where waste_ref = (select j->>'waste_ref' from r where k = 'ok1')), 'it is a suggestion, from the decorator, linked to the order and job');
select pg_temp.assert(exists (select 1 from flow.tp_messages g join flow.tp_movements m on m.id = g.movement_id where m.movement_code = :'mva' and g.side = 'producer' and g.body like 'Reported 2 spoiled%'), 'it is posted in the job thread');
select pg_temp.assert(exists (select 1 from flow.tp_movement_events e join flow.tp_movements m on m.id = e.movement_id where m.movement_code = :'mva' and e.event = 'producer_spoilage'), 'it is logged on the job');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'portal_report_spoilage' and entity_id = :'mva'), 'it is audited');
select pg_temp.assert(not exists (select 1 from flow.waste_events where status = 'approved' and movement_id = (select id from flow.tp_movements where movement_code = :'mva')), 'it does not count as waste until a person confirms it');

-- 3. refusals
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
set role authenticated;
insert into r select 'cap', public.portal_report_spoilage(:'mva', :'ita'::uuid, 4, 'misprint', 'Too many for this line', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'cap') and (select j->>'error' from r where k = 'cap') like '%more than was sent%', 'cannot report more than was sent in total');
insert into r select 'note', public.portal_report_spoilage(:'mva', :'ita'::uuid, 1, 'misprint', 'no', null);
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'note'), 'a few words are required');
insert into r select 'what', public.portal_report_spoilage(:'mva', :'ita'::uuid, 1, 'ate_it', 'Some long enough note', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'what'), 'only known reasons');
insert into r select 'zero', public.portal_report_spoilage(:'mva', :'ita'::uuid, 0, 'stained', 'Some long enough note', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'zero'), 'a quantity is required');
insert into r select 'foreign', public.portal_report_spoilage(:'mva', :'itb'::uuid, 1, 'stained', 'A line from another job', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'foreign'), 'a line from another job is refused');
insert into r select 'path', public.portal_report_spoilage(:'mva', :'ita'::uuid, 1, 'stained', 'Photo from somewhere else', 'other-folder/x.jpg');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'path'), 'a photo outside their folder is refused');
select pg_temp.assert(pg_temp.try(format('select public.portal_report_spoilage(%L, %L::uuid, 1, ''stained'', ''Trying a job that is not mine'', null)', :'mvb', :'itb')) like '%not found%', 'another decorator''s job cannot be reported on');
insert into r select 'photo', public.portal_report_spoilage(:'mva', :'ita'::uuid, 1, 'damaged', 'Torn while loading, photo attached', (select id::text from flow.producers where code = 'PSA') || '/' || :'mva' || '/spoil.jpg');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'photo'), 'a photo in their own folder is accepted');
insert into r select 'full', public.portal_report_spoilage(:'mva', :'ita'::uuid, 3, 'stained', 'Now over the total', null);
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'full'), 'the total stays capped (2 + 1 reported of 5)');

-- 4. what the decorator can read back
insert into r select 'list', public.portal_spoilage(:'mva');
select pg_temp.assert(jsonb_array_length((select j->'reports' from r where k = 'list')) = 2, 'they see their two reports');
select pg_temp.assert(not ((select j::text from r where k = 'list') ~ '(unit_cost|"value"|decision_note|approved_by)'), 'no costs or internal notes are returned');
select pg_temp.assert(pg_temp.try(format('select public.portal_spoilage(%L)', :'mvb')) like '%not found%', 'they cannot read another decorator''s reports');
reset role;

-- 5. Nia (other decorator) sees nothing of Sam's
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c2');
set role authenticated;
select pg_temp.assert(pg_temp.try(format('select public.portal_spoilage(%L)', :'mva')) like '%not found%', 'the other decorator cannot read these reports');
select pg_temp.assert(pg_temp.try('select count(*) from flow.waste_events') like '%permission denied%' or (select count(*) from flow.waste_events) = 0, 'decorators cannot read the waste ledger');
reset role;

-- 6. a rejected report frees the units again
select flow.waste_confirm((select j->>'waste_ref' from r where k = 'ok1'), false, 'Not our machine, checking with the decorator', 'tester') as dismissed \gset
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
set role authenticated;
insert into r select 'again', public.portal_report_spoilage(:'mva', :'ita'::uuid, 3, 'stained', 'Counting again after review', null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'again'), 'dismissed units can be reported again');
reset role;

-- 7. permissions
select pg_temp.assert(not has_function_privilege('anon', 'public.portal_report_spoilage(text,uuid,int,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.portal_spoilage(text)', 'execute'), 'anonymous visitors can call nothing');
select pg_temp.assert(has_function_privilege('authenticated', 'public.portal_report_spoilage(text,uuid,int,text,text,text)', 'execute'), 'logged-in decorators can call it (the function checks who they are)');
\echo portal_spoilage_test OK
