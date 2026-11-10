-- Decorator upload cap: a decorator login may store only so many files, and so many bytes, in one job's folder.
-- The local test database has no storage schema, so a stand-in table is made inside a transaction and rolled back at the end.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.login(p_uid text) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claim.sub', p_uid, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false); end $$;

begin;
insert into flow.producers (code, name, turnaround_days, capable_methods) values ('UPC', 'Upload Cap Decorators', 3, '{dtf}');
select id as up from flow.producers where code = 'UPC' \gset
-- invite first: an address that already has a login cannot be invited as a decorator
select (flow.pp_add_user(:'up', 'decorator@upcap-decor.test', 'D', 't')->>'ok')::bool as invited \gset
select pg_temp.assert(:'invited'::bool, 'the decorator can be invited');
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000003a1', 'team@upcap.test', now()), ('00000000-0000-0000-0000-0000000003a2', 'decorator@upcap-decor.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000003a1', 'admin') on conflict (user_id) do update set role = 'admin';
update flow.producer_users set user_id = '00000000-0000-0000-0000-0000000003a2' where email = 'decorator@upcap-decor.test';

-- stand-in for Supabase storage
create schema storage;
create table storage.objects (id bigserial primary key, bucket_id text not null, name text not null, metadata jsonb);
grant usage on schema storage to authenticated, service_role; grant select on storage.objects to authenticated, service_role;
insert into flow.flow_settings (key, value, description) values ('portal.upload_limits', '{"max_files_per_job": 3, "max_bytes_per_job": 1000}'::jsonb, 'test') on conflict (key) do update set value = excluded.value;

-- 1. the limits have defaults and can be overridden
select pg_temp.assert((flow.portal_upload_limits()->>'max_files_per_job')::int = 3 and (flow.portal_upload_limits()->>'max_bytes_per_job')::int = 1000, 'limits come from the setting');
delete from flow.flow_settings where key = 'portal.upload_limits';
select pg_temp.assert((flow.portal_upload_limits()->>'max_files_per_job')::int = 40 and (flow.portal_upload_limits()->>'max_bytes_per_job')::bigint = 262144000, 'without a setting the defaults are 40 files and 250 MB');
insert into flow.flow_settings (key, value, description) values ('portal.upload_limits', '{"max_files_per_job": 3, "max_bytes_per_job": 1000}'::jsonb, 'test');

-- 2. a decorator login, file counts (folder = <producer>/<consignment>)
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(flow.is_portal_login(), 'the test decorator is a portal login');
reset role;
insert into storage.objects (bucket_id, name, metadata) values ('producer-evidence', :'up' || '/TP-1/a.jpg', '{"size": 100}'), ('producer-evidence', :'up' || '/TP-1/b.jpg', '{"size": 100}');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-1/c.jpg'), 'a third file is allowed when two are stored and the limit is three');
reset role;
insert into storage.objects (bucket_id, name, metadata) values ('producer-evidence', :'up' || '/TP-1/c.jpg', '{"size": 100}');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(not flow.portal_upload_allowed(:'up' || '/TP-1/d.jpg'), 'a fourth file is refused');
select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-2/a.jpg'), 'another job has its own allowance');
select pg_temp.assert(not flow.portal_upload_allowed('a.jpg') and not flow.portal_upload_allowed(''), 'a file outside any job folder is refused');
reset role;

-- 3. total size: the folder is full once what is stored reaches the limit
insert into storage.objects (bucket_id, name, metadata) values ('producer-evidence', :'up' || '/TP-3/big1.pdf', '{"size": 600}'), ('producer-evidence', :'up' || '/TP-3/big2.pdf', '{"size": 399}');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-3/next.pdf'), 'under the size limit (999 of 1000) the next file is allowed, and may take it a little over');
reset role;
insert into storage.objects (bucket_id, name, metadata) values ('producer-evidence', :'up' || '/TP-3/big3.pdf', '{"size": 10}');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(not flow.portal_upload_allowed(:'up' || '/TP-3/next.pdf'), 'once the stored total reaches the limit the next file is refused');
reset role;

-- 4. only the job's own folder is counted, and only this bucket
insert into storage.objects (bucket_id, name, metadata) values ('artwork', :'up' || '/TP-4/x.png', '{"size": 5}'), ('producer-evidence', :'up' || '/TP-40/x.jpg', '{"size": 5}'), ('producer-evidence', :'up' || '/TP-4/nested/y.jpg', '{"size": 5}'), ('producer-evidence', :'up' || '/TP-4/z.jpg', null), ('producer-evidence', :'up' || '/TP-7/w.jpg', '{"size": "not a number"}');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-4/new.jpg'), 'files in another bucket or in a folder that merely starts the same (TP-40) are not counted; a file with no recorded size counts as zero bytes');
select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-7/new.jpg'), 'a stored file whose size is not a number does not break the check (it counts as zero bytes)');
reset role;
insert into storage.objects (bucket_id, name, metadata) values ('producer-evidence', :'up' || '/TP-5/p%.jpg', '{"size": 1}'), ('producer-evidence', :'up' || '/TP-5/q_.jpg', '{"size": 1}'), ('producer-evidence', :'up' || '/TP-5/r.jpg', '{"size": 1}');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(not flow.portal_upload_allowed(:'up' || '/TP-5/s.jpg'), 'names with wildcard characters are counted as plain text');
reset role;

-- 5. the team and the service role are not limited
insert into storage.objects (bucket_id, name, metadata) select 'producer-evidence', :'up' || '/TP-6/' || g || '.jpg', '{"size": 9999}' from generate_series(1, 10) g;
select pg_temp.login('00000000-0000-0000-0000-0000000003a1'); set role authenticated;
select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-6/more.jpg'), 'a team member is not limited');
reset role;
select set_config('request.jwt.claim.sub', '', false); select set_config('request.jwt.claims', '{}', false);
set role service_role; select pg_temp.assert(flow.portal_upload_allowed(:'up' || '/TP-6/more.jpg'), 'the service role is not limited'); reset role;
select pg_temp.assert(not has_function_privilege('anon', 'flow.portal_upload_allowed(text)', 'execute'), 'signed-out visitors cannot run the upload rule');

-- 6b. the storage rule itself: run the real migration file against the stand-in table, then try real inserts as each kind of login
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(regexp_replace(name, '/[^/]*$', ''), '/') $$;
alter table storage.objects enable row level security;
grant insert on storage.objects to authenticated; grant usage, select on sequence storage.objects_id_seq to authenticated;
-- what Supabase already has: a decorator may insert into their own folder, the team may insert anywhere
create policy producer_evidence_insert on storage.objects for insert to authenticated with check (bucket_id = 'producer-evidence' and (storage.foldername(name))[1] = public.portal_my_producer()::text);
create policy team_insert on storage.objects for insert to authenticated with check (flow.is_member());
\getenv root ROOT
select pg_read_file(:'root' || '/supabase/migrations/20261110000062_flow_portal_upload_cap.sql') as mig \gset
select :'mig' as q \gexec
select pg_temp.assert(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portal_upload_cap' and permissive = 'RESTRICTIVE' and cmd = 'INSERT'), 'the migration creates a restrictive insert rule on storage objects');
select pg_temp.login('00000000-0000-0000-0000-0000000003a2'); set role authenticated;
select pg_temp.assert(pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', :'up' || '/TP-8/1.jpg', '{"size": 1}')) = 'ok'
  and pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', :'up' || '/TP-8/2.jpg', '{"size": 1}')) = 'ok'
  and pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', :'up' || '/TP-8/3.jpg', '{"size": 1}')) = 'ok', 'a decorator can store files up to the limit');
select pg_temp.assert(pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', :'up' || '/TP-8/4.jpg', '{"size": 1}')) like '%row-level security%', 'the storage rule itself refuses the next file');
select pg_temp.assert(pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', :'up' || '/TP-9/1.jpg', '{"size": 1}')) = 'ok', 'another job is not affected');
select pg_temp.assert(pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', gen_random_uuid()::text || '/TP-9/1.jpg', '{"size": 1}')) like '%row-level security%', 'a decorator still cannot write into someone else''s folder');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000003a1'); set role authenticated;
select pg_temp.assert(pg_temp.try(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)', 'producer-evidence', :'up' || '/TP-8/team.jpg', '{"size": 1}')) = 'ok', 'the team can still add to a full folder');
reset role;

-- 6. the check cannot be used to learn anything else, and fails closed
select pg_temp.assert(has_function_privilege('authenticated', 'flow.portal_upload_allowed(text)', 'execute'), 'logged-in users can run the upload rule (it is the storage rule)');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.portal_upload_limits()', 'execute'), 'the limits helper stays private');
rollback;
\echo portal_upload_cap_test OK
