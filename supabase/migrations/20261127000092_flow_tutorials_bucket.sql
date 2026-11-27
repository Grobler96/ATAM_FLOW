-- Private storage bucket for the how-to videos (the How-to videos page, docs/how-to-videos.md). Each video is one file named <tutorial id>.mp4.
--   * Private: nothing is public. The page opens a video with a short-lived link, which only works for a signed-in person who may read the bucket.
--   * Read: anyone with a working Flow role (flow.is_member()), including viewers. Decorator logins are never in flow.user_roles, so they cannot.
--   * Write: admin only, to add a video (insert) or replace one (update). There is no delete rule: remove a file from the Supabase dashboard.
--   * Videos only (mp4), up to 200 MB each, enforced by the bucket itself.
--   * Skipped quietly where there is no storage schema, as in the local test database; supabase/tests/tutorials_bucket_test.sql runs this file
--     against a stand-in. Running it twice changes nothing.
do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then return; end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('tutorials', 'tutorials', false, 209715200, array['video/mp4']) on conflict (id) do nothing;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tutorials_staff_read') then
    execute $p$create policy tutorials_staff_read on storage.objects for select to authenticated using (bucket_id = 'tutorials' and flow.is_member())$p$;
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tutorials_admin_insert') then
    execute $p$create policy tutorials_admin_insert on storage.objects for insert to authenticated with check (bucket_id = 'tutorials' and flow.has_role('admin'))$p$;
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'tutorials_admin_update') then
    execute $p$create policy tutorials_admin_update on storage.objects for update to authenticated
      using (bucket_id = 'tutorials' and flow.has_role('admin')) with check (bucket_id = 'tutorials' and flow.has_role('admin'))$p$;
  end if;
end $$;
