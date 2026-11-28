-- The how-to videos bucket: private, every Flow role can watch, only an admin can add or replace a video, nothing else is opened.
-- The local test database has no storage schema, so a stand-in is made inside a transaction and rolled back; the real migration file is run against it.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.login(p_uid text) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claim.sub', p_uid, false); perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false); end $$;
create or replace function pg_temp.put(p_bucket text, p_name text) returns text language sql as
$$ select pg_temp.try(format('insert into storage.objects (bucket_id, name) values (%L, %L)', p_bucket, p_name)) $$;
-- how many files this login can see / changes / removes in a bucket
create or replace function pg_temp.can_see(p_bucket text) returns bigint language plpgsql as $$ declare n bigint; begin select count(*) into n from storage.objects where bucket_id = p_bucket; return n; end $$;
create or replace function pg_temp.changed(p_bucket text, p_name text) returns int language plpgsql as
$$ declare n int; begin update storage.objects set metadata = '{"replaced": true}' where bucket_id = p_bucket and name = p_name; get diagnostics n = row_count; return n; end $$;
create or replace function pg_temp.removed(p_bucket text, p_name text) returns int language plpgsql as
$$ declare n int; begin delete from storage.objects where bucket_id = p_bucket and name = p_name; get diagnostics n = row_count; return n; end $$;

begin;
insert into flow.producers (code, name, turnaround_days, capable_methods) values ('TUT', 'Tutorial Decorators', 3, '{dtf}');
select id as tp from flow.producers where code = 'TUT' \gset
select (flow.pp_add_user(:'tp', 'decorator@tut-decor.test', 'D', 't')->>'ok')::bool as invited \gset
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000006a1', 'admin@tut.test', now()), ('00000000-0000-0000-0000-0000000006a2', 'manager@tut.test', now()), ('00000000-0000-0000-0000-0000000006a3', 'production@tut.test', now()),
  ('00000000-0000-0000-0000-0000000006a4', 'warehouse@tut.test', now()), ('00000000-0000-0000-0000-0000000006a5', 'viewer@tut.test', now()), ('00000000-0000-0000-0000-0000000006a6', 'decorator@tut-decor.test', now()), ('00000000-0000-0000-0000-0000000006a7', 'nobody@tut.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000006a1', 'admin'), ('00000000-0000-0000-0000-0000000006a2', 'manager'), ('00000000-0000-0000-0000-0000000006a3', 'production'),
  ('00000000-0000-0000-0000-0000000006a4', 'warehouse'), ('00000000-0000-0000-0000-0000000006a5', 'viewer') on conflict (user_id) do update set role = excluded.role;
update flow.producer_users set user_id = '00000000-0000-0000-0000-0000000006a6' where email = 'decorator@tut-decor.test';

-- stand-in for Supabase storage
create schema storage;
create table storage.buckets (id text primary key, name text not null, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id bigserial primary key, bucket_id text not null, name text not null, metadata jsonb);
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated;
grant select, insert, update, delete on storage.objects to authenticated; grant usage, select on sequence storage.objects_id_seq to authenticated;
insert into storage.objects (bucket_id, name) values ('tutorials', 'cc-tour.mp4'), ('artwork', 'orders/700101/logo.dst');   -- put in by the owner of the database (as the service role would)

-- 1. before the migration nobody can see or add anything in the new bucket
select pg_temp.login('00000000-0000-0000-0000-0000000006a1'); set role authenticated;
select pg_temp.assert(pg_temp.can_see('tutorials') = 0, 'before the migration an admin cannot see tutorial videos');
select pg_temp.assert(pg_temp.put('tutorials', 'before.mp4') like '%row-level security%', 'before the migration an admin cannot add one');
reset role;

-- 2. run the real migration file, twice
\getenv root ROOT
select pg_read_file(:'root' || '/supabase/migrations/20261127000092_flow_tutorials_bucket.sql') as mig \gset
select :'mig' as q \gexec
select pg_temp.assert((select count(*) from storage.buckets where id = 'tutorials') = 1, 'the migration makes the bucket');
select pg_temp.assert((select not public and file_size_limit = 209715200 and allowed_mime_types = array['video/mp4'] from storage.buckets where id = 'tutorials'), 'the bucket is private, 200 MB, mp4 only');
select pg_temp.assert((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname in ('tutorials_staff_read', 'tutorials_admin_insert', 'tutorials_admin_update')) = 3, 'the migration makes the three rules');
select :'mig' as q \gexec
select pg_temp.assert((select count(*) from storage.buckets where id = 'tutorials') = 1, 'running it twice makes one bucket');
select pg_temp.assert((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'tutorials_%') = 3, 'running it twice makes the same three rules');

-- 3. who can watch: every Flow role, nobody else
select pg_temp.login('00000000-0000-0000-0000-0000000006a1'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 1, 'an admin can see the videos'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a2'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 1, 'a manager can see the videos'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a3'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 1, 'a production login can see the videos'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a4'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 1, 'a warehouse login can see the videos'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a5'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 1, 'a viewer can see the videos'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a7'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 0, 'a login with no ATAM_FLOW role cannot see the videos'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a6'); set role authenticated; select pg_temp.assert(pg_temp.can_see('tutorials') = 0, 'a decorator login cannot see the videos'); reset role;
select set_config('request.jwt.claim.sub', '', false); select set_config('request.jwt.claims', '{}', false);
select pg_temp.assert(not has_table_privilege('anon', 'storage.objects', 'select'), 'a signed-out visitor cannot read storage');

-- 4. who can add or replace a video: an admin only
select pg_temp.login('00000000-0000-0000-0000-0000000006a1'); set role authenticated;
select pg_temp.assert(pg_temp.put('tutorials', 'po-approve.mp4') = 'ok', 'an admin can add a video');
select pg_temp.assert(pg_temp.changed('tutorials', 'cc-tour.mp4') = 1, 'an admin can replace a video');
select pg_temp.assert(pg_temp.removed('tutorials', 'po-approve.mp4') = 0, 'there is no delete rule, so even an admin cannot remove one through the app');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a2'); set role authenticated;
select pg_temp.assert(pg_temp.put('tutorials', 'manager.mp4') like '%row-level security%', 'a manager cannot add a video');
select pg_temp.assert(pg_temp.changed('tutorials', 'cc-tour.mp4') = 0, 'a manager cannot replace a video');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a3'); set role authenticated; select pg_temp.assert(pg_temp.put('tutorials', 'production.mp4') like '%row-level security%', 'a production login cannot add a video'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a4'); set role authenticated; select pg_temp.assert(pg_temp.put('tutorials', 'warehouse.mp4') like '%row-level security%', 'a warehouse login cannot add a video'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a5'); set role authenticated;
select pg_temp.assert(pg_temp.put('tutorials', 'viewer.mp4') like '%row-level security%', 'a viewer cannot add a video');
select pg_temp.assert(pg_temp.changed('tutorials', 'cc-tour.mp4') = 0, 'a viewer cannot replace a video');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a7'); set role authenticated; select pg_temp.assert(pg_temp.put('tutorials', 'nobody.mp4') like '%row-level security%', 'a login with no ATAM_FLOW role cannot add a video'); reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000006a6'); set role authenticated;
select pg_temp.assert(pg_temp.put('tutorials', 'decorator.mp4') like '%row-level security%', 'a decorator login cannot add a video');
select pg_temp.assert(pg_temp.changed('tutorials', 'cc-tour.mp4') = 0, 'a decorator login cannot replace a video');
reset role;

-- 5. no other bucket is touched
select pg_temp.login('00000000-0000-0000-0000-0000000006a1'); set role authenticated;
select pg_temp.assert(pg_temp.can_see('artwork') = 0, 'the rules do not open the artwork bucket for reading');
select pg_temp.assert(pg_temp.put('artwork', 'orders/700101/x.dst') like '%row-level security%', 'the rules do not open the artwork bucket for adding');
select pg_temp.assert(pg_temp.put('tutorials2', 'x.mp4') like '%row-level security%', 'a bucket whose name merely starts with tutorials is not this one');
reset role;
rollback;
\echo tutorials_bucket_test OK
