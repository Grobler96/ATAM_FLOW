-- Audit fixes: a decorator login is confined to the portal; crew views and blocking-exception lookups are team-only.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.login(p_uid text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', p_uid, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false); end $$;
create or replace function pg_temp.path(p text) returns void language sql as $$ select set_config('request.path', p, false) $$;

insert into flow.producers (code, name, turnaround_days, capable_methods) values ('PGD', 'Guarded Decorators', 3, '{dtf}');
select id as pg from flow.producers where code = 'PGD' \gset
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000002e1', 'team@guard.test', now()), ('00000000-0000-0000-0000-0000000002e5', 'otherapp@guard.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000002e1', 'admin') on conflict (user_id) do update set role = 'admin';

-- 1. an address that already has a login cannot be invited
select pg_temp.assert(not (flow.pp_add_user(:'pg', 'otherapp@guard.test', 'X', 't')->>'ok')::bool and (flow.pp_add_user(:'pg', 'otherapp@guard.test', 'X', 't')->>'error') like '%already has a login%', 'an existing login cannot be made a decorator');
select pg_temp.assert((flow.pp_add_user(:'pg', 'claimed@guard-decor.test', 'C', 't')->>'ok')::bool and (flow.pp_add_user(:'pg', 'invited@guard-decor.test', 'I', 't')->>'ok')::bool and (flow.pp_add_user(:'pg', 'off@guard-decor.test', 'O', 't')->>'ok')::bool, 'fresh addresses can be invited');
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000002e2', 'claimed@guard-decor.test', now()), ('00000000-0000-0000-0000-0000000002e3', 'Invited@Guard-Decor.test', now()), ('00000000-0000-0000-0000-0000000002e4', 'off@guard-decor.test', now());
update flow.producer_users set user_id = '00000000-0000-0000-0000-0000000002e2' where email = 'claimed@guard-decor.test';
update flow.producer_users set is_active = false where email = 'off@guard-decor.test';

-- 2. who counts as a decorator login
select pg_temp.login('00000000-0000-0000-0000-0000000002e2'); select pg_temp.assert(flow.is_portal_login(), 'a claimed decorator is a portal login');
select pg_temp.login('00000000-0000-0000-0000-0000000002e3'); select pg_temp.assert(flow.is_portal_login(), 'an invited decorator who has never opened the portal is still a portal login (matched on email, any case)');
select pg_temp.login('00000000-0000-0000-0000-0000000002e4'); select pg_temp.assert(flow.is_portal_login(), 'a switched-off decorator is still confined');
select pg_temp.login('00000000-0000-0000-0000-0000000002e1'); select pg_temp.assert(not flow.is_portal_login(), 'a team member is not a portal login');
select pg_temp.login('00000000-0000-0000-0000-0000000002e5'); select pg_temp.assert(not flow.is_portal_login(), 'a login of the other app is not a portal login');

-- 3. the guard: decorators reach only portal functions; everyone else is untouched
select pg_temp.login('00000000-0000-0000-0000-0000000002e3');
set role authenticated;
select pg_temp.path('/rpc/portal_jobs');             select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') = 'ok', 'a decorator may call portal functions');
select pg_temp.path('/customer_accounts');           select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use the ATAM decorator portal%', 'a decorator cannot read another app''s tables');
select pg_temp.path('/rpc/approve_sales_invoice');   select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use%', 'a decorator cannot call another app''s functions');
select pg_temp.path('/ui_orders');                   select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use%', 'a decorator cannot read staff views');
select pg_temp.path('/rpc/portal_jobs/../ui_search'); select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use%', 'path tricks are refused');
select pg_temp.path('/rpc/portalx');                 select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use%', 'only functions whose name starts portal_ are allowed');
select pg_temp.path('');                             select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use%', 'an unknown path is refused for a decorator');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000002e4'); set role authenticated;
select pg_temp.path('/xero_sales_documents');        select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') like '%only use%', 'a switched-off decorator is confined too');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000002e1'); set role authenticated;
select pg_temp.path('/customer_accounts');           select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') = 'ok', 'the team is not affected');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000002e5'); set role authenticated;
select pg_temp.path('/rpc/approve_sales_invoice');   select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') = 'ok', 'the other app''s users are not affected');
reset role;
select set_config('request.jwt.claim.sub', '', false); select set_config('request.jwt.claims', '{}', false);
set role anon;         select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') = 'ok', 'signed-out requests pass through (their own rules still apply)'); reset role;
set role service_role; select pg_temp.assert(pg_temp.try('select public.portal_api_guard()') = 'ok', 'the service role passes through'); reset role;

-- 4. flow-only hardening
select pg_temp.assert(not has_table_privilege('authenticated', 'flow.v_operator_history', 'select') and not has_table_privilege('authenticated', 'flow.v_operator_customer_history', 'select') and not has_table_privilege('authenticated', 'flow.v_operator_quality', 'select'), 'crew history views are not readable directly');
select pg_temp.assert(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'v' and (n.nspname = 'flow' or (n.nspname = 'public' and c.relname like 'ui\_%'))
  and coalesce(c.reloptions::text, '') not like '%security_invoker=true%' and (has_table_privilege('authenticated', c.oid, 'select') or has_table_privilege('anon', c.oid, 'select'))), 'no owner-rights view is readable from the browser');
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units) values ('PGO1', '#PG1', 'Guard Customer', now() + interval '5 days', 'in_production', true, 1, 5);
select id as go from flow.orders where deco_order_id = 'PGO1' \gset
select flow.exc_raise('manual_review', 'guard:block', 'test', 'Guard test blocker', jsonb_build_array(jsonb_build_object('type', 'order', 'id', :'go')), '{"severity":"high","blocks":["completion"]}'::jsonb) is not null as raised \gset
select pg_temp.assert(jsonb_array_length(flow.order_blocking_exceptions(:'go', 'completion')) >= 1, 'the service side still sees blocking exceptions');
select pg_temp.login('00000000-0000-0000-0000-0000000002e1'); set role authenticated;
select pg_temp.assert(jsonb_array_length(flow.order_blocking_exceptions(:'go', 'completion')) >= 1, 'the team still sees blocking exceptions'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000002e2'); set role authenticated;
select pg_temp.assert(jsonb_array_length(flow.order_blocking_exceptions(:'go', 'completion')) = 0, 'a decorator login gets nothing from the blocking-exception lookup'); reset role;
\echo portal_guard_test OK
