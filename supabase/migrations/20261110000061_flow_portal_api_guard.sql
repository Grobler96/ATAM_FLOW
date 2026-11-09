-- CRITICAL finding from the independent audit (10 Nov 2026).
-- This Supabase project is shared with another app whose tables and functions trust ANY logged-in user
-- (policies "to authenticated using (true)", functions that only check "is someone signed in").
-- Every invited decorator is a logged-in user of the same project, so a decorator's login could read that
-- app's customers, quotes, invoices and costs, and call its write functions, by talking to the API directly.
--
-- This confines a decorator login to the decorator portal, at one choke point, without changing the other app:
--  1. flow.is_portal_login(): is the caller a decorator login (claimed, or invited and matched on email, active or not)?
--  2. public.portal_api_guard(): runs before every API request. A decorator login may only call public.portal_* functions.
--     Everyone else (the team, the service role, signed-out visitors) passes straight through.
--  3. A restrictive storage rule: a decorator login can only touch the two buckets the portal uses.
--  4. Inviting an address that already has a login is refused, so a team member can never be turned into a decorator.
create or replace function flow.is_portal_login() returns boolean
language plpgsql stable security definer set search_path = flow, public as $$
declare u uuid := auth.uid();
begin
  if u is null then return false; end if;
  if exists (select 1 from flow.user_roles r where r.user_id = u) then return false; end if;
  return exists (select 1 from flow.producer_users pu where pu.user_id = u)
      or exists (select 1 from flow.producer_users pu join auth.users au on lower(au.email) = lower(pu.email) where au.id = u);
exception when others then
  return false;   -- never take the shared API down because of this check
end $$;

create or replace function public.portal_api_guard() returns void
language plpgsql security definer set search_path = flow, public as $$
begin
  if current_setting('role', true) is distinct from 'authenticated' then return; end if;
  if not flow.is_portal_login() then return; end if;
  if coalesce(current_setting('request.path', true), '') ~ '^/rpc/portal_[a-z_]+$' then return; end if;
  raise exception 'This login can only use the ATAM decorator portal.' using errcode = '42501';
end $$;

-- The guard runs as whoever is making the request, so every API role must be able to run it.
revoke all on function public.portal_api_guard() from public;
grant execute on function public.portal_api_guard() to anon, authenticated, service_role;
revoke all on function flow.is_portal_login() from public, anon;
grant execute on function flow.is_portal_login() to authenticated, service_role;

do $$
begin
  if to_regclass('storage.objects') is not null and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portal_login_scope') then
    execute $p$create policy portal_login_scope on storage.objects as restrictive for all to authenticated
      using (not flow.is_portal_login() or bucket_id in ('producer-evidence', 'artwork'))
      with check (not flow.is_portal_login() or bucket_id in ('producer-evidence', 'artwork'))$p$;
  end if;
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.pp_add_user(uuid,text,text,text)'::regprocedure) into v_def;
  if v_def not like '%already has a login%' then
    v_def := replace(v_def, 'if exists (select 1 from flow.user_roles ur join auth.users u on u.id = ur.user_id where lower(u.email) = v_email)',
      'if exists (select 1 from auth.users u where lower(u.email) = v_email) then return jsonb_build_object(''ok'', false, ''error'', ''That email already has a login with us. A decorator needs their own separate address.''); end if;
  if exists (select 1 from flow.user_roles ur join auth.users u on u.id = ur.user_id where lower(u.email) = v_email)');
    if v_def not like '%already has a login%' then raise exception 'pp_add_user anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- Switch the guard on for the API (the role exists only on the hosted project, not in the local test database).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    execute 'alter role authenticator set pgrst.db_pre_request = ''public.portal_api_guard''';
    perform pg_notify('pgrst', 'reload config');
  end if;
end $$;
