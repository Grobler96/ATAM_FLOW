-- Regression guard for database permissions. Fails the build if a privileged function becomes callable from the browser
-- or a flow table loses row level security.
do $$
declare v_bad text;
begin
  -- 1. anon must never run a security definer function in flow, or the flow_ / ui_ wrappers in public
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.prokind = 'f' and p.prosecdef
    and (n.nspname = 'flow' or (n.nspname = 'public' and (left(p.proname, 5) = 'flow_' or left(p.proname, 3) = 'ui_')))
    and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then raise exception 'SECURITY: anon can execute: %', v_bad; end if;

  -- 2. logged-in users may only run the allow-listed helpers (write actions go through n8n with the service role).
  --    flow.portal_can_read_artwork(text) is the storage rule behind decorator job pack downloads: it runs as the logged-in user, only answers yes/no
  --    about files in that decorator's own current packs, and returns nothing else.
  --    flow.dispatch_address / dispatch_state feed the dispatch views, which run as the logged-in user; both return null unless the caller is a team member.
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.prokind = 'f' and p.prosecdef
    and (n.nspname = 'flow' or (n.nspname = 'public' and left(p.proname, 5) = 'flow_'))
    and has_function_privilege('authenticated', p.oid, 'execute')
    and p.oid::regprocedure::text not in ('flow.is_member()', 'flow.has_role(flow.app_role[])', 'flow.order_blocking_exceptions(uuid,text)', 'flow.portal_can_read_artwork(text)',
      'flow.dispatch_address(uuid)', 'flow.dispatch_state(uuid)',
      -- read-only configuration helpers used inside views that staff query (they only return settings values)
      'flow.exc_digest_cfg()', 'flow.purchasing_rules()', 'flow.portal_security()');
  if v_bad is not null then raise exception 'SECURITY: logged-in users can execute: %', v_bad; end if;

  -- 3. every flow table has row level security switched on
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'flow' and c.relkind = 'r' and not c.relrowsecurity;
  if v_bad is not null then raise exception 'SECURITY: flow tables without RLS: %', v_bad; end if;

  raise notice 'permissions_test: OK';
end $$;
