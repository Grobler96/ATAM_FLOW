-- Staff can add quality-check photos under qc/ in the evidence bucket, and nothing else changes.
-- The local test database has no storage schema, so a stand-in is made inside a transaction (with the rules Supabase already has) and rolled back.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.login(p_uid text) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claim.sub', p_uid, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false); end $$;
create or replace function pg_temp.put(p_bucket text, p_name text) returns text language sql as
$$ select pg_temp.try(format('insert into storage.objects (bucket_id, name) values (%L, %L)', p_bucket, p_name)) $$;

begin;
insert into flow.producers (code, name, turnaround_days, capable_methods) values ('QCE', 'QC Evidence Decorators', 3, '{dtf}');
select id as qp from flow.producers where code = 'QCE' \gset
select (flow.pp_add_user(:'qp', 'decorator@qce-decor.test', 'D', 't')->>'ok')::bool as invited \gset
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000005a1', 'admin@qce.test', now()), ('00000000-0000-0000-0000-0000000005a2', 'manager@qce.test', now()), ('00000000-0000-0000-0000-0000000005a3', 'production@qce.test', now()),
  ('00000000-0000-0000-0000-0000000005a4', 'warehouse@qce.test', now()), ('00000000-0000-0000-0000-0000000005a5', 'viewer@qce.test', now()), ('00000000-0000-0000-0000-0000000005a6', 'decorator@qce-decor.test', now()), ('00000000-0000-0000-0000-0000000005a7', 'nobody@qce.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000005a1', 'admin'), ('00000000-0000-0000-0000-0000000005a2', 'manager'), ('00000000-0000-0000-0000-0000000005a3', 'production'),
  ('00000000-0000-0000-0000-0000000005a4', 'warehouse'), ('00000000-0000-0000-0000-0000000005a5', 'viewer') on conflict (user_id) do update set role = excluded.role;
update flow.producer_users set user_id = '00000000-0000-0000-0000-0000000005a6' where email = 'decorator@qce-decor.test';

-- stand-in for Supabase storage, with the rules that already exist for this bucket
create schema storage;
create table storage.objects (id bigserial primary key, bucket_id text not null, name text not null, metadata jsonb);
create function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(regexp_replace(name, '/[^/]*$', ''), '/') $$;
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated; grant insert on storage.objects to authenticated; grant usage, select on sequence storage.objects_id_seq to authenticated;
create policy producer_evidence_insert on storage.objects for insert to authenticated with check (bucket_id = 'producer-evidence' and (storage.foldername(name))[1] = public.portal_my_producer()::text);

-- 1. before the migration, no staff member can add a file
select pg_temp.login('00000000-0000-0000-0000-0000000005a4'); set role authenticated;
select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/before.jpg') like '%row-level security%', 'before the migration a staff member cannot add a file');
reset role;

-- 2. run the real migration file
\getenv root ROOT
select pg_read_file(:'root' || '/supabase/migrations/20261110000064_flow_qc_evidence_storage.sql') as mig \gset
select :'mig' as q \gexec
select pg_temp.assert(exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'qc_evidence_staff_insert' and cmd = 'INSERT'), 'the migration creates the staff rule');
select :'mig' as q \gexec   -- running it again changes nothing
select pg_temp.assert((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'qc_evidence_staff_insert') = 1, 'running it twice makes one rule');

-- 3. who may add a file under qc/
select pg_temp.login('00000000-0000-0000-0000-0000000005a1'); set role authenticated; select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/admin.jpg') = 'ok', 'an admin can add a QC photo'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005a2'); set role authenticated; select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/manager.jpg') = 'ok', 'a manager can add a QC photo'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005a3'); set role authenticated; select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/production.jpg') = 'ok', 'a production login can add a QC photo'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005a4'); set role authenticated; select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/warehouse.jpg') = 'ok', 'a warehouse login can add a QC photo'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005a5'); set role authenticated; select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/viewer.jpg') like '%row-level security%', 'a viewer cannot add a QC photo'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005a7'); set role authenticated; select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/nobody.jpg') like '%row-level security%', 'a login with no ATAM_FLOW role cannot add a QC photo'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005a6'); set role authenticated;
select pg_temp.assert(pg_temp.put('producer-evidence', 'qc/700101/decorator.jpg') like '%row-level security%', 'a decorator login cannot add a file under qc/');
select pg_temp.assert(pg_temp.put('producer-evidence', :'qp' || '/TP-1/own.jpg') = 'ok', 'a decorator can still add to their own folder (unchanged)');
reset role;
select set_config('request.jwt.claim.sub', '', false); select set_config('request.jwt.claims', '{}', false);
select pg_temp.assert(not has_table_privilege('anon', 'storage.objects', 'insert'), 'a signed-out visitor cannot add files');

-- 4. staff are allowed under qc/ only, in this bucket only
select pg_temp.login('00000000-0000-0000-0000-0000000005a4'); set role authenticated;
select pg_temp.assert(pg_temp.put('producer-evidence', 'other/700101/x.jpg') like '%row-level security%', 'staff cannot add files outside qc/');
select pg_temp.assert(pg_temp.put('producer-evidence', 'x.jpg') like '%row-level security%', 'staff cannot add a file at the top of the bucket');
select pg_temp.assert(pg_temp.put('producer-evidence', :'qp' || '/TP-1/theirs.jpg') like '%row-level security%', 'staff cannot add into a decorator''s folder');
select pg_temp.assert(pg_temp.put('artwork', 'qc/700101/x.jpg') like '%row-level security%', 'the rule does not open any other bucket');
select pg_temp.assert(pg_temp.put('producer-evidence', 'qc2/700101/x.jpg') like '%row-level security%', 'a folder that merely starts with qc is not qc');
reset role;
rollback;
\echo qc_evidence_storage_test OK
