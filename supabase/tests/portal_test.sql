-- Decorator portal: identity, isolation, accept / check in / stage / ship / message, photos, exceptions.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'false') where key = 'artwork.options';
insert into flow.producers (code, name, address, contact_name, turnaround_days, can_direct_dispatch, capable_methods, special_instructions) values
  ('PTA', 'Portal Stitchers', '1 Mill St', 'Sam', 3, false, '{embroidery}', 'Left chest only'),
  ('PTB', 'Other Decorators', '2 Dock Rd', 'Nia', 3, false, '{embroidery}', null);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, priority, total_units, created_at) values
  ('PO1', '#PO1', 'Northside FC', now() + interval '10 days', 'ready_for_production', true, 1, 0, 24, now() - interval '2 days'),
  ('PO2', '#PO2', 'Cityline', now() + interval '10 days', 'ready_for_production', true, 1, 0, 10, now() - interval '2 days'),
  ('PO3', '#PO3', 'Problem Co', now() + interval '10 days', 'ready_for_production', true, 1, 0, 6, now() - interval '2 days');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, garment_type, product_name, qty_required, decoration_methods)
  select v.wi, o.id, v.sku, 'Navy', 'M', 'Polos', 'Polo shirt', v.q, '{embroidery}' from (values ('POL1', 'PO1', 'POLO-NVY-M', 24), ('POL2', 'PO2', 'POLO-NVY-L', 10), ('POL3', 'PO3', 'POLO-NVY-S', 6)) v(wi, oid, sku, q) join flow.orders o on o.deco_order_id = v.oid;
select flow.generate_bins('OUT', 'OUT', 6);
select id as pta from flow.producers where code = 'PTA' \gset
select id as ptb from flow.producers where code = 'PTB' \gset
select id as pol1 from flow.order_lines where deco_workflow_item_id = 'POL1' \gset
select id as pol2 from flow.order_lines where deco_workflow_item_id = 'POL2' \gset
select id as pol3 from flow.order_lines where deco_workflow_item_id = 'POL3' \gset

-- a clean job and a problem job for PTA, one job for PTB, one still in draft
insert into r select 'c1', flow.create_outbound_movement(:'pta', jsonb_build_array(jsonb_build_object('order_line_id', :'pol1', 'qty', 24)), 'wh');
insert into r select 'c2', flow.create_outbound_movement(:'ptb', jsonb_build_array(jsonb_build_object('order_line_id', :'pol2', 'qty', 10)), 'wh');
select j->>'movement_code' as mv1 from r where k = 'c1' \gset
select j->>'movement_code' as mv2 from r where k = 'c2' \gset
insert into r select 'c3', flow.create_outbound_movement(:'pta', jsonb_build_array(jsonb_build_object('order_line_id', :'pol3', 'qty', 6)), 'wh');
select j->>'movement_code' as mv3 from r where k = 'c3' \gset
select flow.tp_scan(:'mv2', 'picked', 'w'); select flow.tp_scan(:'mv2', 'packed', 'w'); select flow.tp_scan(:'mv2', 'dispatched', 'w', '{"date":"2026-11-09"}');
-- the PTA job is still a draft: invisible to the decorator

-- logins
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000a1', 'sam@stitchers.test', now()), ('00000000-0000-0000-0000-0000000000a2', 'nobody@elsewhere.test', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'unconfirmed@stitchers.test', null), ('00000000-0000-0000-0000-0000000000a4', 'staff@atam.test', now()), ('00000000-0000-0000-0000-0000000000b1', 'nia@others.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000a4', 'admin');
select (flow.pp_add_user(:'pta', 'Sam@Stitchers.test', 'Sam', 'tester')->>'ok')::bool as a \gset
select (flow.pp_add_user(:'pta', 'unconfirmed@stitchers.test', 'Una', 'tester')->>'ok')::bool as b \gset
select (flow.pp_add_user(:'ptb', 'nia@others.test', 'Nia', 'tester')->>'ok')::bool as c \gset
select pg_temp.assert(:'a'::bool and :'b'::bool and :'c'::bool, 'users added');
select pg_temp.assert(not (flow.pp_add_user(:'pta', 'sam@stitchers.test', 'Dup', 't')->>'ok')::bool, 'the same email cannot be added twice');
select pg_temp.assert(not (flow.pp_add_user(:'pta', 'staff@atam.test', 'Staff', 't')->>'ok')::bool, 'an ATAM team login cannot be a decorator login');
select pg_temp.assert(not (flow.pp_add_user(:'pta', 'not-an-email', 'x', 't')->>'ok')::bool, 'email checked');

create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

-- 1. who may come in
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
set role authenticated;
select pg_temp.assert(pg_temp.try('select public.portal_whoami()') like '%does not have access%', 'an unknown login is refused');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
set role authenticated;
select pg_temp.assert(pg_temp.try('select public.portal_whoami()') like '%does not have access%', 'an unconfirmed email is refused');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a4');
set role authenticated;
select pg_temp.assert(pg_temp.try('select public.portal_jobs()') like '%does not have access%', 'an ATAM team login is not a decorator');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
set role authenticated;
insert into r select 'who', public.portal_whoami();
select pg_temp.assert((select j->>'producer' = 'Portal Stitchers' and j->>'user' = 'Sam' from r where k = 'who'), 'the invited decorator signs in on first use');
reset role;
select pg_temp.assert((select user_id is not null from flow.producer_users where lower(email) = 'sam@stitchers.test'), 'the invitation is claimed by the verified login');

-- 2. isolation and nothing internal
set role authenticated;
select pg_temp.assert(jsonb_array_length(public.portal_jobs()) = 0, 'a draft job is invisible to the decorator');
select pg_temp.assert(pg_temp.try('select count(*) from public.ui_orders') <> 'ok' or (select count(*) from public.ui_orders) = 0, 'internal views show a decorator nothing');
select pg_temp.assert(pg_temp.try('select flow.portal_ctx()') like '%permission denied%', 'internal functions are closed to decorators');
reset role;
select flow.tp_scan(:'mv1', 'picked', 'w'); select flow.tp_scan(:'mv1', 'packed', 'w'); select flow.tp_scan(:'mv1', 'dispatched', 'w', '{"date":"2026-11-09"}');
select flow.tp_scan(:'mv3', 'picked', 'w'); select flow.tp_scan(:'mv3', 'packed', 'w'); select flow.tp_scan(:'mv3', 'dispatched', 'w', '{"date":"2026-11-09"}');
set role authenticated;
insert into r select 'jobs', public.portal_jobs();
select pg_temp.assert((select jsonb_array_length(j) = 2 and not exists (select 1 from jsonb_array_elements(j) x where x->>'code' = :'mv2') and bool_and(x->>'state' = 'to_accept') from r, jsonb_array_elements(r.j) x where k = 'jobs' group by r.j), 'the decorator sees only its own dispatched jobs: ' || (select j::text from r where k = 'jobs'));
select pg_temp.assert((select bool_or(x->'orders'->0->>'customer' = 'Northside FC') from r, jsonb_array_elements(r.j) x where k = 'jobs'), 'customer names are shown');
select pg_temp.assert(pg_temp.try(format('select public.portal_job(%L)', :'mv2')) like '%not found%', 'another decorator''s job cannot be opened');
select pg_temp.assert(pg_temp.try(format('select public.portal_accept(%L)', :'mv2')) like '%not found%', 'another decorator''s job cannot be accepted');
reset role;

-- 3. accept / decline
set role authenticated;
select pg_temp.assert((public.portal_decline(:'mv3', 'no')->>'needs_reason')::bool, 'declining needs a reason');
insert into r select 'acc', public.portal_accept(:'mv1');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'acc'), 'job accepted');
select pg_temp.assert(not (public.portal_accept(:'mv1')->>'ok')::bool, 'cannot accept twice');
insert into r select 'dec', public.portal_decline(:'mv3', 'We have no capacity this week');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'dec'), 'job declined with a reason');
select pg_temp.assert(not (public.portal_check_in(:'mv3', '[]'::jsonb, null)->>'ok')::bool, 'a declined job cannot be checked in');
reset role;
select pg_temp.assert(exists (select 1 from flow.exceptions where type_code = 'producer_declined' and dedupe_key = 'decl:' || :'mv3'), 'a declined job raises a critical exception');
set role authenticated;
select pg_temp.assert((public.portal_accept(:'mv3')->>'ok')::bool, 'a declined job can be accepted after a talk');
reset role;
select id as it1 from flow.tp_movement_items where movement_id = (select id from flow.tp_movements where movement_code = :'mv1') \gset
select id as it3 from flow.tp_movement_items where movement_id = (select id from flow.tp_movements where movement_code = :'mv3') \gset

-- 4. check in: must count everything; problems need words; a clean count is quiet
set role authenticated;
select pg_temp.assert(not (public.portal_check_in(:'mv1', '[]'::jsonb, null)->>'ok')::bool, 'every line must be counted');
select pg_temp.assert((public.portal_check_in(:'mv3', jsonb_build_array(jsonb_build_object('item_id', :'it3', 'qty_counted', 5, 'qty_damaged', 1)), null)->>'needs_reason')::bool, 'a problem needs words');
select pg_temp.assert(not (public.portal_check_in(:'mv3', jsonb_build_array(jsonb_build_object('item_id', :'it3', 'qty_counted', 2, 'qty_damaged', 3, 'note', 'bad count here')), null)->>'ok')::bool, 'damaged cannot exceed counted');
insert into r select 'ci1', public.portal_check_in(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it1', 'qty_counted', 24, 'qty_damaged', 0)), 'All good');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'clean')::bool from r where k = 'ci1'), 'a clean check in');
insert into r select 'ci3', public.portal_check_in(:'mv3', jsonb_build_array(jsonb_build_object('item_id', :'it3', 'qty_counted', 5, 'qty_damaged', 1, 'issue', 'damaged', 'note', 'One polo has an oil stain')), null);
select pg_temp.assert((select (j->>'ok')::bool and not (j->>'clean')::bool from r where k = 'ci3'), 'a check in with problems');
select pg_temp.assert(not (public.portal_check_in(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it1', 'qty_counted', 24)), null)->>'ok')::bool, 'cannot check in twice');
reset role;
select pg_temp.assert((select status = 'received_by_producer' from flow.tp_movements where movement_code = :'mv1'), 'checking in moves the consignment to received by producer');
select pg_temp.assert(exists (select 1 from flow.exceptions where type_code = 'producer_receipt_issue' and dedupe_key = 'rcpt:' || :'mv3') and not exists (select 1 from flow.exceptions where type_code = 'producer_receipt_issue' and dedupe_key = 'rcpt:' || :'mv1'), 'only the problem check in raises an exception');
select pg_temp.assert((select qty_counted = 5 and qty_damaged = 1 and issue = 'damaged' from flow.tp_receipts where item_id = :'it3'), 'count and condition are recorded');

-- 5. stage
set role authenticated;
select pg_temp.assert(not (public.portal_stage(:'mv1', 'shipped', null, null)->>'ok')::bool, 'unknown stage refused');
select pg_temp.assert((public.portal_stage(:'mv1', 'in_production', null, null)->>'ok')::bool, 'in production');
select pg_temp.assert((public.portal_stage(:'mv1', 'delayed', 'x', current_date + 3)->>'needs_reason')::bool, 'a delay needs a reason');
select pg_temp.assert((public.portal_stage(:'mv1', 'delayed', 'Thread supply is late', current_date + 3)->>'ok')::bool, 'delay reported with a new date');
select pg_temp.assert((public.portal_stage(:'mv1', 'production_complete', null, null)->>'ok')::bool, 'production complete');
reset role;
select pg_temp.assert((select status = 'production_complete' and expected_return_date = current_date + 3 from flow.tp_movements where movement_code = :'mv1'), 'status and the new date are saved');
select pg_temp.assert(exists (select 1 from flow.exceptions where type_code = 'producer_delay'), 'a delay raises an exception');

-- 6. ship back
set role authenticated;
select pg_temp.assert(not (public.portal_ship(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it1', 'qty_shipped', 24)), 'DPD', '', null)->>'ok')::bool, 'courier and tracking are required');
select pg_temp.assert((public.portal_ship(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it1', 'qty_shipped', 10)), 'DPD', 'DPD777', '')->>'needs_reason')::bool, 'sending fewer than expected needs an explanation');
select pg_temp.assert((public.portal_ship(:'mv1', jsonb_build_array(jsonb_build_object('item_id', :'it1', 'qty_shipped', 24)), 'DPD', 'DPD777', null)->>'ok')::bool, 'shipped back');
reset role;
select pg_temp.assert((select status = 'in_transit_back' and return_tracking_ref = 'DPD777' from flow.tp_movements where movement_code = :'mv1'), 'status and tracking are saved');

-- 7. messages and photos
set role authenticated;
select pg_temp.assert(not (public.portal_message(:'mv1', '   ')->>'ok')::bool, 'empty message refused');
select pg_temp.assert((public.portal_message(:'mv3', 'When can you replace the stained polo?')->>'ok')::bool, 'message sent');
select pg_temp.assert(not (public.portal_evidence_add(:'mv3', :'it3', 'someone-else/' || :'mv3' || '/photo.jpg', 'issue', 'x')->>'ok')::bool, 'a photo outside the decorator''s own folder is refused');
select pg_temp.assert((public.portal_evidence_add(:'mv3', :'it3', :'pta' || '/' || :'mv3' || '/stain.jpg', 'issue', 'Oil stain')->>'ok')::bool, 'a photo in its own folder is recorded');
select pg_temp.assert(jsonb_array_length(public.portal_job(:'mv3')->'messages') = 1 and jsonb_array_length(public.portal_job(:'mv3')->'evidence') = 1, 'the job card shows the message and photo');
reset role;
update flow.tp_messages set created_at = now() - interval '30 hours' where movement_id = (select id from flow.tp_movements where movement_code = :'mv3');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.exc_detect_portal()) e where e->>'key' = 'qry:' || :'mv3'), 'an unanswered question raises an exception after a day');
select pg_temp.assert((flow.pp_reply(:'mv3', 'Replacement is on its way', 'tester')->>'ok')::bool, 'we can reply');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.exc_detect_portal()) e where e->>'key' = 'qry:' || :'mv3'), 'a reply clears it');
select pg_temp.assert((flow.pp_resolve_receipt(:'mv3', 'Replacement polo being sent', 'tester')->>'ok')::bool and not (flow.pp_resolve_receipt(:'mv3', 'Again nothing to do', 'tester')->>'ok')::bool, 'receipt problem resolved once');

-- 8. switching a user off, and the browser roles
select pg_temp.assert((flow.pp_set_user_active((select id from flow.producer_users where lower(email) = 'sam@stitchers.test'), false, 'Left the company', 'tester')->>'ok')::bool, 'a user can be switched off');
set role authenticated;
select pg_temp.assert(pg_temp.try('select public.portal_jobs()') like '%does not have access%', 'a switched-off user is locked out at once');
reset role;
select pg_temp.assert(not has_function_privilege('anon', 'public.portal_jobs()', 'execute') and not has_function_privilege('anon', 'public.portal_check_in(text,jsonb,text)', 'execute'), 'anonymous visitors cannot call the portal');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_pp_add_user(uuid,text,text,text)', 'execute') and not has_function_privilege('authenticated', 'flow.pp_reply(text,text,text)', 'execute'), 'decorators cannot call internal functions');
\echo portal_test OK
