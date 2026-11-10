-- Audit observation (10 Nov 2026): "Admins and managers can still write some set-up tables directly (machines, bins, settings, producers, suppliers,
-- roles) through database rules that pre-date the 'all writes go through n8n' pattern. Those writes skip the audit trail."
-- Every direct write by a logged-in person to one of those tables now leaves a row in flow.audit_log: who, what table, which row, and the row before
-- and after. Nothing about who may write changes. A direct write cannot give a reason; a reason is only recorded when the change goes through an action.
--   * Only a logged-in person writing through the API is recorded (the role is 'authenticated'). Migrations, the service role and the functions n8n
--     calls are not, because those paths record their own audit rows, and syncs and seeds would flood the log.
--   * An update that changes nothing (or only updated_at) is not recorded.
--   * supabase/tests/config_audit_test.sql fails if a table a logged-in person can write directly has no audit trigger, so a new table cannot be forgotten.
create or replace function flow.audit_direct_write() returns trigger
language plpgsql security definer set search_path = flow, public as $$
declare v_old jsonb; v_new jsonb; v_id text;
begin
  if current_setting('role', true) is distinct from 'authenticated' then return null; end if;
  v_old := case when TG_OP = 'INSERT' then null else to_jsonb(OLD) end;
  v_new := case when TG_OP = 'DELETE' then null else to_jsonb(NEW) end;
  if TG_OP = 'UPDATE' and (v_old - 'updated_at') = (v_new - 'updated_at') then return null; end if;
  select string_agg(coalesce(coalesce(v_new, v_old) ->> a.attname, ''), ',' order by k.ord) into v_id
  from pg_index i cross join lateral unnest(i.indkey::int2[]) with ordinality as k(attnum, ord)
  join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
  where i.indrelid = TG_RELID and i.indisprimary;
  insert into flow.audit_log (actor, action, entity, entity_id, before, after)
  values ('direct:' || coalesce(auth.uid()::text, 'unknown'), 'direct_' || lower(TG_OP), TG_TABLE_NAME, v_id, v_old, v_new);
  return null;
end $$;

-- A trigger function needs no one to be allowed to call it; keep it private.
revoke all on function flow.audit_direct_write() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['bin_zones', 'bins', 'changeover_rules', 'deco_status_map', 'exception_types', 'flow_settings', 'garment_type_rules', 'machine_shifts',
                           'machines', 'process_code_map', 'producer_rates', 'producers', 'production_methods', 'supplier_offers', 'suppliers', 'user_roles'] loop
    execute format('create or replace trigger audit_direct_write after insert or update or delete on flow.%I for each row execute function flow.audit_direct_write()', t);
  end loop;
end $$;
