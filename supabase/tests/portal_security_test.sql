-- Portal hardening: company addresses only, sign-in log, new-device note, inactivity sign-out, staff-only visibility.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.login(p_uid text, p_sid text, p_ua text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'session_id', p_sid)::text, false);
  perform set_config('request.headers', json_build_object('user-agent', p_ua, 'x-forwarded-for', '203.0.113.7, 10.0.0.1')::text, false);
end $$;

insert into flow.producers (code, name, turnaround_days, capable_methods) values ('PSEC', 'Secure Decorators', 3, '{dtf}');
select id as ps from flow.producers where code = 'PSEC' \gset
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000001c1', 'ops@secure-decorators.test', now()), ('00000000-0000-0000-0000-0000000001c2', 'staff2@atam.test', now()), ('00000000-0000-0000-0000-0000000001c3', 'stranger@elsewhere.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000001c2', 'admin') on conflict (user_id) do update set role = 'admin';

-- 1. company addresses only
select pg_temp.assert(not (flow.pp_add_user(:'ps', 'someone@gmail.com', 'P', 't')->>'ok')::bool and (flow.pp_add_user(:'ps', 'someone@gmail.com', 'P', 't')->>'personal_email')::bool, 'a personal address cannot be invited');
select pg_temp.assert(not (flow.pp_add_user(:'ps', 'Someone@Hotmail.co.uk', 'P', 't')->>'ok')::bool, 'case and other personal domains are caught too');
select pg_temp.assert(not (flow.portal_allow_email('someone@gmail.com', 'short', 'admin')->>'ok')::bool, 'allowing a personal address needs a real reason');
select pg_temp.assert((flow.portal_allow_email('someone@gmail.com', 'Sole trader, no company mailbox', 'admin')->>'ok')::bool, 'an admin can allow one personal address with a reason');
select pg_temp.assert((flow.pp_add_user(:'ps', 'someone@gmail.com', 'P', 't')->>'ok')::bool, 'the allowed address can now be invited');
select pg_temp.assert(not (flow.pp_add_user(:'ps', 'other@gmail.com', 'P', 't')->>'ok')::bool, 'the allowance covers only that address');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'portal_email_allowed'), 'allowing a personal address is audited');
select pg_temp.assert((flow.pp_add_user(:'ps', 'ops@secure-decorators.test', 'Ops', 't')->>'ok')::bool, 'a company address is fine');

-- 2. sign-in log and new device
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '11111111-1111-1111-1111-111111111111', 'Browser A');
set role authenticated;
select public.portal_whoami();
reset role;
select pg_temp.assert((select event from flow.portal_sign_ins where email = 'ops@secure-decorators.test' order by id limit 1) = 'first_sign_in', 'first sign-in logged');
select pg_temp.assert((select ip from flow.portal_sign_ins where email = 'ops@secure-decorators.test' order by id limit 1) = '203.0.113.7', 'the address is the first one in the forwarded list');
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '22222222-2222-2222-2222-222222222222', 'Browser B');
set role authenticated; select public.portal_whoami(); reset role;
select pg_temp.assert((select event from flow.portal_sign_ins where email = 'ops@secure-decorators.test' order by id desc limit 1) = 'new_device', 'a different device is noted');
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '33333333-3333-3333-3333-333333333333', 'Browser A');
set role authenticated; select public.portal_whoami(); reset role;
select pg_temp.assert((select event from flow.portal_sign_ins where email = 'ops@secure-decorators.test' order by id desc limit 1) = 'signed_in', 'a known device is an ordinary sign-in');
select pg_temp.assert((select count(*) from flow.portal_sign_ins where email = 'ops@secure-decorators.test') = 3, 'one row per new session, not per call');
set role authenticated; select public.portal_whoami(); select public.portal_jobs(); reset role;
select pg_temp.assert((select count(*) from flow.portal_sign_ins where email = 'ops@secure-decorators.test') = 3, 'ordinary calls in the same session do not add rows');

-- 3. inactivity
update flow.portal_sessions set last_active_at = now() - interval '3 hours' where session_id = '33333333-3333-3333-3333-333333333333';
select pg_temp.assert(pg_temp.try('select public.portal_whoami()') like '%inactivity%' or (select count(*) from flow.portal_sessions where session_id = '33333333-3333-3333-3333-333333333333' and last_active_at < now() - interval '2 hours') = 1, 'idle precondition');
set role authenticated;
select pg_temp.assert(pg_temp.try('select public.portal_whoami()') like '%signed out after 120 minutes of inactivity%', 'an idle session is refused by the database');
select pg_temp.assert(pg_temp.try('select public.portal_jobs()') like '%inactivity%', 'every portal call refuses an idle session');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '44444444-4444-4444-4444-444444444444', 'Browser A');
set role authenticated; select pg_temp.assert(pg_temp.try('select public.portal_whoami()') = 'ok', 'a fresh sign-in works again'); reset role;
update flow.flow_settings set value = value || '{"idle_minutes": 0}'::jsonb where key = 'portal.security';
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '33333333-3333-3333-3333-333333333333', 'Browser A');
set role authenticated; select pg_temp.assert(pg_temp.try('select public.portal_whoami()') = 'ok', 'a limit of 0 switches the inactivity rule off'); reset role;
update flow.flow_settings set value = value || '{"idle_minutes": 120}'::jsonb where key = 'portal.security';

-- 4. refused logins are noted once an hour
select pg_temp.login('00000000-0000-0000-0000-0000000001c3', '55555555-5555-5555-5555-555555555555', 'Browser C');
set role authenticated; select public.portal_report_refused(); select public.portal_report_refused(); reset role;
select pg_temp.assert((select count(*) from flow.portal_sign_ins where event = 'refused' and email = 'stranger@elsewhere.test') = 1, 'a refused login is logged once an hour');
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '33333333-3333-3333-3333-333333333333', 'Browser A');
set role authenticated; select public.portal_report_refused(); reset role;
select pg_temp.assert(not exists (select 1 from flow.portal_sign_ins where event = 'refused' and email = 'ops@secure-decorators.test'), 'an invited decorator is never logged as refused');

-- 5. who can see the log
select pg_temp.login('00000000-0000-0000-0000-0000000001c2', '66666666-6666-6666-6666-666666666666', 'Staff');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_portal_sign_ins) >= 4, 'staff see the sign-in log');
select pg_temp.assert((select count(*) from public.ui_portal_users where email = 'someone@gmail.com' and personal_email) = 1, 'staff see which decorator logins use a personal address');
select pg_temp.assert(pg_temp.try('select count(*) from public.ui_exception_attention') = 'ok' and pg_temp.try('select count(*) from public.ui_po_invoices') = 'ok', 'staff can read the digest and invoice views (helper functions are executable)');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000001c1', '33333333-3333-3333-3333-333333333333', 'Browser A');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_portal_sign_ins) = 0, 'a decorator cannot see the sign-in log');
reset role;
\echo portal_security_test OK
