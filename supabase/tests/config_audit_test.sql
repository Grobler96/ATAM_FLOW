-- Direct writes to set-up tables by a logged-in person leave an audit trail; other paths and no-op updates do not.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.login(p_uid text) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claim.sub', p_uid, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false); end $$;

insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000004a1', 'admin@cfgaudit.test', now()), ('00000000-0000-0000-0000-0000000004a2', 'viewer@cfgaudit.test', now()), ('00000000-0000-0000-0000-0000000004a3', 'manager@cfgaudit.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000004a1', 'admin'), ('00000000-0000-0000-0000-0000000004a2', 'viewer'), ('00000000-0000-0000-0000-0000000004a3', 'manager') on conflict (user_id) do update set role = excluded.role;
select count(*) as base from flow.audit_log \gset

-- 1. a direct insert, update and delete by an admin are recorded, with who, which row, and the row before and after
select pg_temp.login('00000000-0000-0000-0000-0000000004a1'); set role authenticated;
insert into flow.flow_settings (key, value, description) values ('audit.test', '{"a": 1}', 'first');
update flow.flow_settings set value = '{"a": 2}' where key = 'audit.test';
delete from flow.flow_settings where key = 'audit.test';
reset role;
select pg_temp.assert((select count(*) from flow.audit_log where entity = 'flow_settings' and entity_id = 'audit.test') = 3, 'insert, update and delete each leave one audit row');
select pg_temp.assert((select count(*) from flow.audit_log where entity = 'flow_settings' and entity_id = 'audit.test' and actor = 'direct:00000000-0000-0000-0000-0000000004a1') = 3, 'the audit row says who made the change');
select pg_temp.assert((select before is null and after->>'description' = 'first' and after->'value' = '{"a": 1}'::jsonb from flow.audit_log where entity_id = 'audit.test' and action = 'direct_insert'), 'an insert has no before and the new row as after');
select pg_temp.assert((select before->'value' = '{"a": 1}'::jsonb and after->'value' = '{"a": 2}'::jsonb from flow.audit_log where entity_id = 'audit.test' and action = 'direct_update'), 'an update records the row before and after');
select pg_temp.assert((select before->>'key' = 'audit.test' and after is null from flow.audit_log where entity_id = 'audit.test' and action = 'direct_delete'), 'a delete records the row that went and no after');

-- 2. an update that changes nothing, or only updated_at, is not recorded
select count(*) as n1 from flow.audit_log \gset
select pg_temp.login('00000000-0000-0000-0000-0000000004a1'); set role authenticated;
insert into flow.flow_settings (key, value, description) values ('audit.noop', '{"x": 1}', 'same');
reset role;
select count(*) as n2 from flow.audit_log \gset
select pg_temp.login('00000000-0000-0000-0000-0000000004a1'); set role authenticated;
update flow.flow_settings set description = 'same' where key = 'audit.noop';
update flow.flow_settings set updated_at = now() + interval '1 minute' where key = 'audit.noop';
reset role;
select pg_temp.assert((select count(*) from flow.audit_log) = :n2, 'an update that changes nothing, or only updated_at, writes no audit row');
select pg_temp.assert(:n2 = :n1 + 1, 'the earlier insert was recorded');

-- 3. a row with a different key (user_roles) and a manager's write
select pg_temp.login('00000000-0000-0000-0000-0000000004a1'); set role authenticated;
update flow.user_roles set role = 'warehouse' where user_id = '00000000-0000-0000-0000-0000000004a2';
reset role;
select pg_temp.assert((select count(*) from flow.audit_log where entity = 'user_roles' and entity_id = '00000000-0000-0000-0000-0000000004a2' and action = 'direct_update' and before->>'role' = 'viewer' and after->>'role' = 'warehouse') = 1, 'a role change is recorded against the person''s id, with the old and new role');
select pg_temp.login('00000000-0000-0000-0000-0000000004a3'); set role authenticated;
insert into flow.bin_zones (code, name) values ('AUD', 'Audit zone');
reset role;
select pg_temp.assert((select count(*) from flow.audit_log where entity = 'bin_zones' and action = 'direct_insert' and actor = 'direct:00000000-0000-0000-0000-0000000004a3' and after->>'code' = 'AUD') = 1, 'a manager''s direct write is recorded too');
-- a table with a uuid key: the key is the row id
select pg_temp.assert((select entity_id = (after->>'id') from flow.audit_log where entity = 'bin_zones' and after->>'code' = 'AUD'), 'the row''s own key is recorded');

-- 4. paths that audit themselves, and refused writes, add nothing
select count(*) as n3 from flow.audit_log \gset
insert into flow.flow_settings (key, value, description) values ('audit.owner', '{"o": 1}', 'written by the database owner');
select pg_temp.assert((select count(*) from flow.audit_log) = :n3, 'a write by the database owner (migrations, seeds) is not recorded here');
set role service_role;
update flow.flow_settings set value = '{"o": 2}' where key = 'audit.owner';
reset role;
select pg_temp.assert((select count(*) from flow.audit_log) = :n3, 'a write by the service role (n8n, syncs) is not recorded here');
select pg_temp.login('00000000-0000-0000-0000-0000000004a2'); set role authenticated;
select pg_temp.assert(pg_temp.try($$insert into flow.flow_settings (key, value, description) values ('audit.refused', '{}', 'viewer')$$) like '%row-level security%', 'a viewer is still refused');
reset role;
select pg_temp.assert((select count(*) from flow.audit_log) = :n3, 'a refused write leaves nothing');

-- 5. the guard: every table a logged-in person can write directly has the audit trigger, so a new one cannot be forgotten
select pg_temp.assert(not exists (select 1 from pg_class c where c.relnamespace = 'flow'::regnamespace and c.relkind in ('r', 'p')
    and (has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update') or has_table_privilege('authenticated', c.oid, 'delete'))
    and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'audit_direct_write' and not t.tgisinternal)),
  'every flow table a logged-in person can write directly has the audit trigger (add it to migration 63''s list, or here, for a new one)');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.audit_direct_write()', 'execute') and not has_function_privilege('anon', 'flow.audit_direct_write()', 'execute'), 'the trigger function is private');
\echo config_audit_test OK
