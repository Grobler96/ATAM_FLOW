-- 19 Nov 2026: artwork files from Google Drive (written and tested locally, NOT yet applied to the live project).
-- DecoNetwork writes each order's production files into a Google Drive folder:
--   DecoNetwork Files / order-<order number> / <item number> / order-<order>-<item>-<location>-<area>-<PROCESS>.dst
-- An n8n workflow lists the folder and asks flow.drive_plan which files to fetch, uploads them to the private artwork bucket, then calls
-- flow.drive_import, which attaches each one to its artwork row (order + order line + area) as a new version. New versions arrive unapproved.
-- Anything that cannot be matched yet stays on a list (public.ui_drive_files) and is retried every run. A hand upload is never overwritten.

-- 1. A Drive-sourced version -----------------------------------------------------------------------------------------------
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'flow.artwork_files'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%source%deconetwork%' loop
    execute format('alter table flow.artwork_files drop constraint %I', c);
  end loop;
end $$;
alter table flow.artwork_files add constraint artwork_files_source_check check (source in ('deconetwork', 'manual', 'google_drive'));

-- The DecoNetwork sync must not replace a Drive version either (a changed design arrives as a new Drive file).
create or replace function flow.artwork_upsert(p_items jsonb, p_actor text default 'sync') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare it jsonb; v_order uuid; cur flow.artwork_files; v_sig text; v_new int := 0; v_upd int := 0; v_same int := 0; v_manual int := 0; v_skip jsonb := '[]'::jsonb; v_id uuid; v_status text; v_had boolean;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then return jsonb_build_object('ok', false, 'error', 'p_items must be an array'); end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_order := coalesce(nullif(it->>'order_id', '')::uuid, (select id from flow.orders where deco_order_id = it->>'deco_order_id'));
    if v_order is null or coalesce(it->>'area', '') = '' then
      v_skip := v_skip || jsonb_build_array(jsonb_build_object('item', it->>'deco_order_id', 'reason', 'unknown order or missing area')); continue; end if;
    v_status := case lower(coalesce(it->>'approval_status', 'unknown')) when 'approved' then 'approved' when 'pending' then 'pending' when 'rejected' then 'rejected' else 'unknown' end;
    it := it || jsonb_build_object('approval_status', v_status);
    v_sig := flow.artwork_signature(it);
    select * into cur from flow.artwork_files where order_id = v_order and coalesce(deco_line_id, '') = coalesce(it->>'deco_line_id', '') and area = it->>'area' and is_current;
    v_had := found;
    if v_had and cur.source in ('manual', 'google_drive') then v_manual := v_manual + 1; continue; end if;
    if v_had and cur.signature = v_sig then
      update flow.artwork_files set thumbnail_url = coalesce(it->>'thumbnail_url', thumbnail_url) where id = cur.id and thumbnail_url is distinct from coalesce(it->>'thumbnail_url', thumbnail_url);
      v_same := v_same + 1; continue; end if;
    if v_had then update flow.artwork_files set is_current = false, superseded_at = now() where id = cur.id; end if;
    insert into flow.artwork_files (order_id, deco_line_id, area, process, source_url, production_url, editable_url, proof_url, thumbnail_url, file_format, stitch_count, width_mm,
        height_mm, crop, placement, transfer, approval_status, version, signature, source, storage_status, supersedes, created_by)
    values (v_order, it->>'deco_line_id', it->>'area', it->>'process', it->>'source_url', it->>'production_url', it->>'editable_url', it->>'proof_url', it->>'thumbnail_url',
        it->>'file_format', nullif(it->>'stitch_count', '')::int, nullif(it->>'width_mm', '')::numeric, nullif(it->>'height_mm', '')::numeric, it->'crop', it->>'placement',
        coalesce(it->'transfer', '{}'::jsonb), v_status, coalesce(cur.version, 0) + 1, v_sig, 'deconetwork',
        case when coalesce(it->>'production_url', it->>'source_url') is null then 'failed' else 'pending_download' end, cur.id, p_actor)
    returning id into v_id;
    if v_status in ('approved') and v_had and cur.approval_status = 'approved' then
      perform flow.notify('artwork_changed', 'warning', 'Approved artwork changed on an order', 'Order ' || (select order_ref from flow.orders where id = v_order) || ', area ' || (it->>'area') || ': v' || (coalesce(cur.version, 0) + 1) || ' replaces v' || cur.version || '. Any job pack already built is now stale.', 'order', v_order);
    end if;
    if v_had then v_upd := v_upd + 1; else v_new := v_new + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'new', v_new, 'updated', v_upd, 'unchanged', v_same, 'manual_kept', v_manual, 'skipped', v_skip);
end $$;
-- 2. The Drive files Flow has seen --------------------------------------------------------------------------------------------
create table flow.drive_files (
  drive_file_id text primary key,
  name          text not null,
  md5           text,
  size_bytes    bigint,
  modified_at   timestamptz,
  web_link      text,
  kind          text not null default 'other' check (kind in ('design', 'worksheet', 'other')),
  deco_order_id text,
  line_id       text,
  location      text,
  area          text,
  process_code  text,
  extension     text,
  status        text not null default 'ready' check (status in ('ready', 'waiting', 'imported', 'ignored', 'failed')),
  reason        text,
  attempts      int not null default 0,
  storage_path  text,
  imported_md5  text,
  artwork_id    uuid references flow.artwork_files(id),
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  imported_at   timestamptz
);
create index drive_files_status on flow.drive_files (status);
alter table flow.drive_files enable row level security;
create policy drive_files_read on flow.drive_files for select to authenticated using (flow.is_member());

-- 3. Reading a file name ---------------------------------------------------------------------------------------------------------
-- order-636894-3730138646-Front-Left_Chest-EMB.dst  ->  order 636894, line 3730138646, location Front, area "Left Chest", process EMB, ext dst
-- order-636894-3730138646-_Right_Sleeve-Right_Sleeve_(Long)-EMB.dst -> area "Right Sleeve (Long)" (underscores are spaces)
create or replace function flow.drive_parse_name(p_name text) returns jsonb language plpgsql immutable as $$
declare m text[];
begin
  m := regexp_match(coalesce(p_name, ''), '^order-([0-9]+)-([0-9]+)-(.+)-([^-]+)-([A-Za-z0-9]+)\.([A-Za-z0-9]+)$');
  if m is not null then
    return jsonb_build_object('kind', 'design', 'order', m[1], 'line', m[2], 'location', nullif(btrim(replace(m[3], '_', ' ')), ''), 'area', btrim(replace(m[4], '_', ' ')), 'process', upper(m[5]), 'ext', lower(m[6]));
  end if;
  m := regexp_match(coalesce(p_name, ''), '^order-([0-9]+)-([0-9]+)-([^-]+)-([A-Za-z0-9]+)\.([A-Za-z0-9]+)$');
  if m is not null then
    return jsonb_build_object('kind', 'design', 'order', m[1], 'line', m[2], 'location', null, 'area', btrim(replace(m[3], '_', ' ')), 'process', upper(m[4]), 'ext', lower(m[5]));
  end if;
  m := regexp_match(coalesce(p_name, ''), '^worksheet-([0-9]+)\.pdf$', 'i');
  if m is not null then return jsonb_build_object('kind', 'worksheet', 'order', m[1]); end if;
  return jsonb_build_object('kind', 'other');
end $$;

create or replace function flow.drive_process(p_code text) returns text language sql immutable as $$
  select case upper(coalesce(p_code, '')) when 'EMB' then 'embroidery' when 'DTF' then 'dtf' when 'DTG' then 'dtg' when 'UV' then 'uv' when '' then null else lower(p_code) end $$;

-- 4. Which files need fetching ---------------------------------------------------------------------------------------------------
-- p_files: [{id, name, md5, size, modified, link}] = every file DecoNetwork has put in Drive recently.
-- Returns {to_import: [...]} (at most p_limit, each tried at most 5 times). Files whose order or order line is not in Flow yet are kept as
-- "waiting" and cost nothing: they are looked at again next time. Worksheets and unrecognised names are recorded as ignored.
create or replace function flow.drive_plan(p_files jsonb, p_limit int default 25) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare f jsonb; pr jsonb; cur flow.drive_files; v_ord uuid; v_status text; v_reason text; v_out jsonb := '[]'::jsonb; v_n int := 0; c_ready int := 0; c_wait int := 0; c_ign int := 0; c_done int := 0; c_fail int := 0;
begin
  if p_files is null or jsonb_typeof(p_files) <> 'array' then return jsonb_build_object('ok', false, 'error', 'p_files must be an array'); end if;
  for f in select * from jsonb_array_elements(p_files) loop
    if coalesce(f->>'id', '') = '' then continue; end if;
    pr := flow.drive_parse_name(f->>'name');
    select * into cur from flow.drive_files where drive_file_id = f->>'id';
    if pr->>'kind' = 'worksheet' then v_status := 'ignored'; v_reason := 'Job worksheet: not imported';
    elsif pr->>'kind' = 'other' then v_status := 'ignored'; v_reason := 'The file name is not one Flow recognises';
    elsif cur.drive_file_id is not null and cur.status = 'imported' and cur.imported_md5 is not distinct from nullif(f->>'md5', '') then v_status := 'imported'; v_reason := null;
    elsif cur.drive_file_id is not null and cur.status = 'failed' and cur.attempts >= 5 and cur.md5 is not distinct from nullif(f->>'md5', '') then v_status := 'failed'; v_reason := cur.reason;
    else
      select id into v_ord from flow.orders where deco_order_id = pr->>'order' and is_active;
      if v_ord is null then v_status := 'waiting'; v_reason := 'Order ' || (pr->>'order') || ' is not in Flow yet';
      elsif not exists (select 1 from flow.order_lines where order_id = v_ord and deco_line_id = pr->>'line') then v_status := 'waiting'; v_reason := 'Order line ' || (pr->>'line') || ' is not on the order in Flow yet';
      else v_status := 'ready'; v_reason := null; end if;
    end if;
    insert into flow.drive_files (drive_file_id, name, md5, size_bytes, modified_at, web_link, kind, deco_order_id, line_id, location, area, process_code, extension, status, reason)
    values (f->>'id', f->>'name', nullif(f->>'md5', ''), nullif(f->>'size', '')::bigint, nullif(f->>'modified', '')::timestamptz, f->>'link', pr->>'kind', pr->>'order', pr->>'line', pr->>'location', pr->>'area', pr->>'process', pr->>'ext', v_status, v_reason)
    on conflict (drive_file_id) do update set name = excluded.name, md5 = excluded.md5, size_bytes = excluded.size_bytes, modified_at = excluded.modified_at, web_link = excluded.web_link, kind = excluded.kind,
      deco_order_id = excluded.deco_order_id, line_id = excluded.line_id, location = excluded.location, area = excluded.area, process_code = excluded.process_code, extension = excluded.extension,
      status = excluded.status, reason = excluded.reason, last_seen = now(),
      attempts = case when flow.drive_files.md5 is distinct from excluded.md5 then 0 else flow.drive_files.attempts end;
    if v_status = 'ready' then
      c_ready := c_ready + 1;
      if v_n < greatest(p_limit, 1) then
        update flow.drive_files set attempts = attempts + 1 where drive_file_id = f->>'id' and attempts < 5 returning * into cur;
        if cur.drive_file_id is not null then
          v_n := v_n + 1;
          v_out := v_out || jsonb_build_array(jsonb_build_object('drive_file_id', cur.drive_file_id, 'name', cur.name, 'md5', cur.md5, 'size', cur.size_bytes,
            'storage_path', 'drive/' || cur.deco_order_id || '/' || cur.line_id || '/' || cur.drive_file_id || '-' || regexp_replace(cur.name, '[^A-Za-z0-9._-]', '_', 'g')));
        else
          update flow.drive_files set status = 'failed', reason = 'Could not be fetched or stored after 5 tries' where drive_file_id = f->>'id';
          c_fail := c_fail + 1;
        end if;
      end if;
    elsif v_status = 'waiting' then c_wait := c_wait + 1;
    elsif v_status = 'ignored' then c_ign := c_ign + 1;
    elsif v_status = 'failed' then c_fail := c_fail + 1;
    else c_done := c_done + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'to_import', v_out, 'ready', c_ready, 'waiting', c_wait, 'ignored', c_ign, 'already_imported', c_done, 'failed', c_fail);
end $$;

-- 5. Attach a fetched file --------------------------------------------------------------------------------------------------------
-- The file is already in the artwork bucket at p_storage_path. Creates the next version of the matching area (or the first one), unapproved.
create or replace function flow.drive_import(p_drive_file_id text, p_storage_path text, p_actor text default 'drive-sync') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare d flow.drive_files; v_ord uuid; cur flow.artwork_files; v_id uuid; v_area text; v_have bigint; v_proc text;
begin
  select * into d from flow.drive_files where drive_file_id = p_drive_file_id for update;
  if d.drive_file_id is null then return jsonb_build_object('ok', false, 'error', 'unknown Drive file'); end if;
  if d.kind <> 'design' then return jsonb_build_object('ok', false, 'error', 'not a design file'); end if;
  if coalesce(d.size_bytes, 0) < 100 then
    update flow.drive_files set status = 'failed', reason = 'The file is empty or too small to be a design' where drive_file_id = d.drive_file_id;
    return jsonb_build_object('ok', false, 'error', 'The file is empty or too small to be a design');
  end if;
  -- the upload must really be there (checked wherever the storage schema exists)
  if to_regclass('storage.objects') is not null then
    execute 'select coalesce((metadata->>''size'')::bigint, 0) from storage.objects where bucket_id = ''artwork'' and name = $1' into v_have using p_storage_path;
    if v_have is null or v_have = 0 then
      update flow.drive_files set reason = 'The upload to secure storage did not arrive' where drive_file_id = d.drive_file_id;
      return jsonb_build_object('ok', false, 'error', 'The upload to secure storage did not arrive');
    end if;
  end if;
  select id into v_ord from flow.orders where deco_order_id = d.deco_order_id and is_active;
  if v_ord is null or not exists (select 1 from flow.order_lines where order_id = v_ord and deco_line_id = d.line_id) then
    update flow.drive_files set status = 'waiting', reason = 'The order or order line is not in Flow yet' where drive_file_id = d.drive_file_id;
    return jsonb_build_object('ok', false, 'error', 'order or order line not in Flow');
  end if;
  v_proc := flow.drive_process(d.process_code);
  select * into cur from flow.artwork_files where order_id = v_ord and deco_line_id = d.line_id and lower(area) = lower(d.area) and is_current
    order by (area = d.area) desc, created_at desc limit 1 for update;
  if cur.id is not null and cur.source = 'manual' then
    update flow.drive_files set status = 'ignored', reason = 'A hand-uploaded version exists, so this Drive file was not applied', storage_path = p_storage_path where drive_file_id = d.drive_file_id;
    return jsonb_build_object('ok', true, 'outcome', 'kept_manual');
  end if;
  if cur.id is not null and cur.source = 'google_drive' and cur.content_hash is not distinct from d.md5 then
    update flow.drive_files set status = 'imported', reason = null, imported_md5 = d.md5, imported_at = now(), storage_path = p_storage_path, artwork_id = cur.id where drive_file_id = d.drive_file_id;
    return jsonb_build_object('ok', true, 'outcome', 'unchanged', 'artwork_id', cur.id);
  end if;
  v_area := coalesce(cur.area, d.area);
  if cur.id is not null then update flow.artwork_files set is_current = false, superseded_at = now() where id = cur.id; end if;
  insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, stitch_count, width_mm, height_mm, crop, placement, transfer, thumbnail_url, proof_url,
      approval_status, version, signature, source, storage_status, storage_path, content_hash, readable, stored_at, supersedes, note, created_by)
  values (v_ord, d.line_id, v_area, coalesce(v_proc, cur.process), d.extension, cur.stitch_count, cur.width_mm, cur.height_mm, cur.crop, cur.placement, coalesce(cur.transfer, '{}'::jsonb), cur.thumbnail_url, cur.proof_url,
      'pending', coalesce(cur.version, 0) + 1, md5(coalesce(d.md5, '') || '|' || p_storage_path), 'google_drive', 'stored', p_storage_path, d.md5, true, now(), cur.id,
      'From Google Drive: ' || d.name, p_actor)
  returning id into v_id;
  if cur.id is not null and cur.approval_status = 'approved' then
    perform flow.notify('artwork_changed', 'warning', 'Approved artwork changed on an order', 'Order #' || d.deco_order_id || ', area ' || v_area || ': a new file arrived from Google Drive (v' || (cur.version + 1) || '). It needs approving again, and any job pack already built is now stale.', 'order', v_ord);
  end if;
  insert into flow.audit_log (actor, action, entity, entity_id, reason) values (p_actor, 'artwork_drive_import', 'artwork', v_id::text, d.name);
  update flow.drive_files set status = 'imported', reason = null, imported_md5 = d.md5, imported_at = now(), storage_path = p_storage_path, artwork_id = v_id where drive_file_id = d.drive_file_id;
  return jsonb_build_object('ok', true, 'outcome', case when cur.id is null then 'new_area' else 'new_version' end, 'artwork_id', v_id, 'version', coalesce(cur.version, 0) + 1);
end $$;

-- 6. For the screen and for n8n ----------------------------------------------------------------------------------------------------
-- What is waiting, failed, or was not applied. (Worksheets are left out: they are expected.)
create or replace view public.ui_drive_files with (security_invoker = true) as
select drive_file_id, name, deco_order_id, line_id, area, process_code, status, reason, attempts, web_link, first_seen, last_seen
from flow.drive_files where status in ('waiting', 'failed') or (status = 'ignored' and kind <> 'worksheet');

create or replace function public.flow_drive_plan(p_files jsonb, p_limit int default 25) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.drive_plan(p_files, p_limit) $$;
create or replace function public.flow_drive_import(p_drive_file_id text, p_storage_path text, p_actor text default 'drive-sync') returns jsonb language sql security definer set search_path = flow, public as $$ select flow.drive_import(p_drive_file_id, p_storage_path, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['flow.drive_plan(jsonb,int)', 'flow.drive_import(text,text,text)', 'public.flow_drive_plan(jsonb,int)', 'public.flow_drive_import(text,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    if f like 'public.%' then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
  revoke all on flow.drive_files, public.ui_drive_files from public, anon;
  grant select on flow.drive_files, public.ui_drive_files to authenticated;
end $$;
