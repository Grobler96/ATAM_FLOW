-- Artwork proofs: lifecycle, the rule that an approval only counts for the artwork it shows, supersede, withdraw, exceptions, and who can see what.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, created_at) values
  ('PFA', '#PFA', 'Proof Co', now() + interval '9 days', 'ready_for_production', true, 1, 20, '{embroidery}', now() - interval '3 days'),
  ('PFB', '#PFB', 'Other Proof Co', now() + interval '9 days', 'ready_for_production', true, 1, 10, '{embroidery}', now() - interval '3 days');
select id as pfa from flow.orders where order_ref = '#PFA' \gset
select id as pfb from flow.orders where order_ref = '#PFB' \gset

-- artwork: two areas on PFA, one on PFB (all waiting for the customer)
select flow.artwork_manual_replace(:'pfa', 'L1', 'Left chest', 'orders/PFA/left-chest/v1-logo.dst', 'tester', 'first upload', '{"approval_status":"pending","file_format":"dst","stitch_count":5200}'::jsonb);
select flow.artwork_manual_replace(:'pfa', 'L1', 'Back', 'orders/PFA/back/v1-back.dst', 'tester', 'first upload', '{"approval_status":"pending","file_format":"dst"}'::jsonb);
select flow.artwork_manual_replace(:'pfb', 'L1', 'Chest', 'orders/PFB/chest/v1.dst', 'tester', 'first upload', '{"approval_status":"pending"}'::jsonb);
select id as a_chest from flow.artwork_files where order_id = :'pfa' and area = 'Left chest' and is_current \gset
select id as a_back from flow.artwork_files where order_id = :'pfa' and area = 'Back' and is_current \gset
select id as b_chest from flow.artwork_files where order_id = :'pfb' and is_current \gset

-- 1. creating a proof
insert into r select 'c0', flow.proof_create(:'pfa', '{}'::uuid[], 'proofs/PFA/p1.pdf', 'p1.pdf', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c0'), 'a proof must show at least one area');
insert into r select 'c1', flow.proof_create(:'pfa', array[:'b_chest'::uuid], 'proofs/PFA/p1.pdf', 'p1.pdf', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c1'), 'artwork from another order cannot be on the proof');
insert into r select 'c2', flow.proof_create(:'pfa', array[:'a_chest'::uuid], 'proofs/OTHER/p1.pdf', 'p1.pdf', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'c2'), 'the proof file must be in this order''s proofs folder');
insert into r select 'p1', flow.proof_create(:'pfa', array[:'a_chest'::uuid], 'proofs/PFA/p1.pdf', 'p1.pdf', 'First look', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'proof_ref' like 'PRF-%' from r where k = 'p1'), 'a proof is created as a draft');
select j->>'proof_id' as p1id from r where k = 'p1' \gset
select pg_temp.assert((select status = 'draft' and areas = array['Left chest'] from flow.artwork_proofs where id = :'p1id'), 'it starts as a draft showing the chosen area');

-- 2. cannot be answered or approved before it is sent
insert into r select 'x1', flow.proof_respond(:'p1id', 'approved', 'Sam at Proof Co', null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'x1'), 'a draft cannot be answered');
-- 3. sending it
insert into r select 's0', flow.proof_send(:'p1id', 'x', 'email', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's0'), 'who it was sent to is required');
insert into r select 's1', flow.proof_send(:'p1id', 'sam@proofco.test', 'email', 'Sent with the quote', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 's1'), 'marked as sent');
insert into r select 's2', flow.proof_send(:'p1id', 'sam@proofco.test', 'email', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's2'), 'it cannot be sent twice');

-- 4. the answer
insert into r select 'a0', flow.proof_respond(:'p1id', 'maybe', 'Sam at Proof Co', null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a0'), 'only the three real answers are accepted');
insert into r select 'a1', flow.proof_respond(:'p1id', 'approved', '', null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a1'), 'who gave the answer is required');
insert into r select 'a2', flow.proof_respond(:'p1id', 'changes_requested', 'Sam at Proof Co', 'no', null, 'tester');
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'a2'), 'a request for changes needs the customer''s words');
insert into r select 'a3', flow.proof_respond(:'p1id', 'approved', 'Sam at Proof Co', null, 'proofs/OTHER/email.png', 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a3'), 'evidence must be in this order''s folder');
insert into r select 'a4', flow.proof_respond(:'p1id', 'approved', 'Sam at Proof Co', 'Happy with it by email', 'proofs/PFA/email.png', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'artwork_approval' = 'approved' from r where k = 'a4'), 'approval recorded');
select pg_temp.assert((select approval_status from flow.artwork_files where id = :'a_chest') = 'approved' and (select approval_status from flow.artwork_files where id = :'a_back') = 'pending', 'only the areas on the proof become approved');
select pg_temp.assert((select status = 'approved' and answered_by = 'Sam at Proof Co' and recorded_by = 'tester' and answer_evidence_path = 'proofs/PFA/email.png' from flow.artwork_proofs where id = :'p1id'), 'who answered, who recorded it, and the evidence are kept');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'proof_answer' and entity_id = '#PFA'), 'the answer is audited');
insert into r select 'a5', flow.proof_respond(:'p1id', 'rejected', 'Sam at Proof Co', 'Changed our minds', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'a5'), 'an answered proof cannot be answered again');

-- 5. a new version of the artwork makes the approved proof out of date, and cannot be proofed with the old id
select flow.artwork_manual_replace(:'pfa', 'L1', 'Left chest', 'orders/PFA/left-chest/v2-logo.dst', 'tester', 'customer asked for a bigger logo', '{"approval_status":"pending"}'::jsonb);
select id as a_chest2 from flow.artwork_files where order_id = :'pfa' and area = 'Left chest' and is_current \gset
select pg_temp.assert((select is_out_of_date from public.ui_artwork_proofs where id = :'p1id'), 'the approved proof is now flagged out of date');
insert into r select 'o1', flow.proof_create(:'pfa', array[:'a_chest'::uuid], 'proofs/PFA/p2.pdf', 'p2.pdf', null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'o1'), 'an old version cannot be put on a new proof');
select pg_temp.assert(jsonb_array_length(flow.exc_detect_proofs()) >= 1 and flow.exc_detect_proofs()::text like '%proof_out_of_date%', 'the detector reports an approved proof that no longer matches the artwork');

-- 6. a new proof for the same area replaces an unanswered one
insert into r select 'p2', flow.proof_create(:'pfa', array[:'a_chest2'::uuid, :'a_back'::uuid], 'proofs/PFA/p2.pdf', 'p2.pdf', 'Both areas', 'tester');
select j->>'proof_id' as p2id from r where k = 'p2' \gset
select flow.proof_send(:'p2id', 'sam@proofco.test', 'email', null, 'tester');
insert into r select 'p3', flow.proof_create(:'pfa', array[:'a_chest2'::uuid], 'proofs/PFA/p3.pdf', 'p3.pdf', 'Chest only', 'tester');
select j->>'proof_id' as p3id from r where k = 'p3' \gset
select pg_temp.assert((select status from flow.artwork_proofs where id = :'p2id') = 'superseded' and (select (j->>'replaced') is not null from r where k = 'p3'), 'a newer proof for the same area supersedes the earlier unanswered one');
-- 7. the answer is refused if the artwork changes after the proof was sent
select flow.proof_send(:'p3id', 'sam@proofco.test', 'phone', null, 'tester');
select flow.artwork_manual_replace(:'pfa', 'L1', 'Left chest', 'orders/PFA/left-chest/v3-logo.dst', 'tester', 'fixed the spelling', '{"approval_status":"pending"}'::jsonb);
insert into r select 'late', flow.proof_respond(:'p3id', 'approved', 'Sam at Proof Co', null, null, 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'late') and (select j->>'error' like '%Make a new proof%' from r where k = 'late'), 'an approval cannot cover artwork that changed after the proof was made');
select pg_temp.assert((select approval_status from flow.artwork_files where order_id = :'pfa' and area = 'Left chest' and is_current) = 'pending', 'and the new version stays unapproved');
-- 8. changes requested sets the area back to pending; rejected sets it to rejected
select flow.artwork_manual_replace(:'pfb', 'L1', 'Chest', 'orders/PFB/chest/v2.dst', 'tester', 'second version', '{"approval_status":"approved"}'::jsonb);
select id as b2 from flow.artwork_files where order_id = :'pfb' and is_current \gset
select (flow.proof_create(:'pfb', array[:'b2'::uuid], 'proofs/PFB/p1.pdf', 'p1.pdf', null, 'tester')->>'proof_id') as q1 \gset
select flow.proof_send(:'q1', 'nia@other.test', 'portal', null, 'tester');
select (flow.proof_respond(:'q1', 'changes_requested', 'Nia', 'Make the logo smaller please', null, 'tester')->>'ok')::bool as chg \gset
select pg_temp.assert(:'chg'::bool and (select approval_status from flow.artwork_files where id = :'b2') = 'pending', 'changes requested puts an approved area back to waiting');
-- 9. withdrawing
insert into r select 'w0', flow.proof_withdraw(:'p3id', 'no', 'tester');
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'w0'), 'withdrawing needs a reason');
insert into r select 'w1', flow.proof_withdraw(:'p3id', 'Artwork changed, making a new one', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'w1'), 'a sent proof can be withdrawn');
insert into r select 'w2', flow.proof_withdraw(:'p1id', 'Trying to withdraw an approved one', 'tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'w2'), 'an answered proof cannot be withdrawn');

-- 10. unanswered proofs raise an exception after the reminder days
select (flow.proof_create(:'pfb', array[:'b2'::uuid], 'proofs/PFB/p2.pdf', 'p2.pdf', null, 'tester')->>'proof_id') as q2 \gset
select flow.proof_send(:'q2', 'nia@other.test', 'email', null, 'tester');
select pg_temp.assert(flow.exc_detect_proofs()::text not like '%' || (select proof_ref from flow.artwork_proofs where id = :'q2') || '%', 'a proof sent just now is not yet flagged');
update flow.artwork_proofs set sent_at = now() - interval '5 days' where id = :'q2';
select pg_temp.assert(flow.exc_detect_proofs()::text like '%proof_unanswered%' and flow.exc_detect_proofs()::text like '%' || (select proof_ref from flow.artwork_proofs where id = :'q2') || '%', 'a proof unanswered for 5 days is flagged');
select pg_temp.assert(pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) like '%''proofs''%', 'the detector runs with every exception check');

-- 11. who can see what
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000f1', 'staff@proofs.test', now()), ('00000000-0000-0000-0000-0000000000f2', 'outsider@proofs.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000f1', 'production') on conflict (user_id) do update set role = 'production';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_artwork_proofs where order_ref in ('#PFA', '#PFB')) >= 4 and (select count(*) from public.ui_artwork_files where order_ref in ('#PFA', '#PFB')) >= 6, 'a team member sees proofs and artwork files');
select pg_temp.assert(not ((select string_agg(column_name, ',') from information_schema.columns where table_schema = 'public' and table_name = 'ui_artwork_files') ~ '(source_url|production_url|editable_url)'), 'the artwork view does not expose DecoNetwork source links');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_artwork_proofs) = 0 and (select count(*) from public.ui_artwork_files) = 0, 'a logged-in outsider (for example a decorator) sees nothing');
select pg_temp.assert(pg_temp.try(format('select flow.proof_respond(%L::uuid, ''approved'', ''x'', null, null, ''x'')', :'q2')) like '%permission denied%' and pg_temp.try(format('select public.flow_proof_send(%L::uuid, ''x@y.z'', ''email'', null, ''x'')', :'q2')) like '%permission denied%', 'nobody in the browser can act on a proof directly');
reset role;
select pg_temp.assert(has_function_privilege('service_role', 'public.flow_proof_respond(uuid,text,text,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_proof_create(uuid,uuid[],text,text,text,text)', 'execute'), 'only the service role can act; anonymous visitors can call nothing');
\echo proofs_test OK
