-- Decorator upload cap (audit observation, 10 Nov 2026): "Decorators can upload unlimited files (10 MB each) into their own folder."
-- A decorator login may now put only a limited number of files, and a limited total size, into one job's folder in the producer-evidence bucket.
--   * Photos and documents live at <producer id>/<consignment>/<file>; the "job folder" is everything before the file name.
--   * The limits are PLACEHOLDERS in flow_settings 'portal.upload_limits' until the business sets real ones: 40 files and 250 MB per job.
--     (Each file is already limited to 10 MB by the bucket.)
--   * The size check looks at what is already stored, because a new file's size is not known when the rule runs, so the last file in
--     a job can take it a little over the size limit (by at most one file). The file count is exact.
--   * Only decorator logins are limited. The team and the service role are not.
--   * Enforced by a restrictive storage rule that calls flow.portal_upload_allowed(name). The rule is skipped quietly where there is no
--     storage schema, as in the local test database; the function itself is tested there with a stand-in table.
insert into flow.flow_settings (key, value, description) values
 ('portal.upload_limits', '{"max_files_per_job": 40, "max_bytes_per_job": 262144000}'::jsonb,
  'PLACEHOLDERS. The most files, and the most total bytes, a decorator login may store in one job''s folder (producer-evidence bucket). Each file is also limited to 10 MB by the bucket.')
on conflict (key) do nothing;

create or replace function flow.portal_upload_limits() returns jsonb language sql stable set search_path = flow, public as $$
  select '{"max_files_per_job": 40, "max_bytes_per_job": 262144000}'::jsonb || coalesce(flow.setting('portal.upload_limits'), '{}'::jsonb)
$$;

-- True when this file may be stored. Runs as the logged-in user (it is the storage rule), answers yes or no and nothing else.
create or replace function flow.portal_upload_allowed(p_name text) returns boolean
language plpgsql stable security definer set search_path = flow, public as $$
declare v_lim jsonb := flow.portal_upload_limits(); v_folder text; v_files bigint; v_bytes numeric;
begin
  if not flow.is_portal_login() then return true; end if;               -- only decorator logins are limited
  if to_regclass('storage.objects') is null then return true; end if;   -- no storage here (local test database)
  v_folder := regexp_replace(coalesce(p_name, ''), '/[^/]*$', '');
  if v_folder = '' or v_folder = p_name then return false; end if;      -- a file outside any job folder is never allowed
  execute 'select count(*), coalesce(sum(case when (metadata->>''size'') ~ ''^[0-9]+$'' then (metadata->>''size'')::numeric else 0 end), 0)
           from storage.objects where bucket_id = ''producer-evidence'' and starts_with(name, $1)'
    into v_files, v_bytes using v_folder || '/';
  return v_files < (v_lim->>'max_files_per_job')::bigint and v_bytes < (v_lim->>'max_bytes_per_job')::numeric;
exception when others then
  return false;   -- if the check itself fails, do not let an unchecked upload through
end $$;

do $$
begin
  if to_regclass('storage.objects') is not null and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'portal_upload_cap') then
    execute $p$create policy portal_upload_cap on storage.objects as restrictive for insert to authenticated
      with check (bucket_id <> 'producer-evidence' or flow.portal_upload_allowed(name))$p$;
  end if;
end $$;

-- The storage rule runs as whoever is uploading, so logged-in users must be able to run it (it is allow-listed in permissions_test.sql).
revoke all on function flow.portal_upload_limits() from public, anon, authenticated;   -- the helper stays private; only the rule above reads it
revoke all on function flow.portal_upload_allowed(text) from public, anon;
grant execute on function flow.portal_upload_allowed(text) to authenticated, service_role;
