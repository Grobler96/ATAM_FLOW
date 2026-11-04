-- Private storage bucket for artwork files. Nothing is public: staff read through their login, producers will only ever get short-lived signed URLs
-- issued by the portal; n8n writes with the service role. Skipped quietly where the storage schema does not exist (local test database).
do $$
begin
  if to_regclass('storage.buckets') is null then return; end if;
  insert into storage.buckets (id, name, public, file_size_limit) values ('artwork', 'artwork', false, 104857600) on conflict (id) do nothing;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'artwork_staff_read') then
    execute $p$create policy artwork_staff_read on storage.objects for select to authenticated using (bucket_id = 'artwork' and flow.is_member())$p$;
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'artwork_staff_upload') then
    execute $p$create policy artwork_staff_upload on storage.objects for insert to authenticated with check (bucket_id = 'artwork' and flow.has_role('admin','manager','production'))$p$;
  end if;
end $$;
