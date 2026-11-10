-- Quality-check photos from a device. The existing private producer-evidence bucket (10 MB per file; jpeg, png, webp, heic or pdf) already holds decorators'
-- photos in <producer id>/<consignment>/. Staff could read it but not write to it. This lets a signed-in staff member with a working role add a file under
-- qc/<order>/ and nowhere else in the bucket. Staff already read the whole bucket (producer_evidence_select), so no read rule changes.
--   * Roles: admin, manager, production, warehouse. A viewer, a decorator login and a signed-out visitor cannot add files.
--   * Skipped quietly where there is no storage schema, as in the local test database; supabase/tests/qc_evidence_storage_test.sql runs this file
--     against a stand-in table.
do $$
begin
  if to_regclass('storage.objects') is not null and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'qc_evidence_staff_insert') then
    execute $p$create policy qc_evidence_staff_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'producer-evidence' and (storage.foldername(name))[1] = 'qc' and flow.has_role('admin', 'manager', 'production', 'warehouse'))$p$;
  end if;
end $$;
