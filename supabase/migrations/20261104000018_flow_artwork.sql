-- Artwork per decorated area (versioned), validation before anything goes to a producer, and producer job packs.
-- Artwork rows are filled by the DecoNetwork artwork sync (n8n) through artwork_upsert, or by hand through artwork_manual_replace.
-- Files themselves live in secure storage; only the storage path is kept here. Producers never see source URLs or costs.

create sequence flow.job_pack_seq start 1;

create table flow.artwork_files (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references flow.orders(id) on delete cascade,
  deco_line_id   text,                                   -- DecoNetwork product line (shared by all sizes); null = whole order
  area           text not null,                          -- decorated area / location, e.g. 'Left chest'
  process        text,                                   -- embroidery, dtf, uv, dtg, transfer ...
  source_url     text,
  production_url text,
  editable_url   text,
  proof_url      text,
  thumbnail_url  text,
  file_format    text,
  stitch_count   int,
  width_mm       numeric(8,1),
  height_mm      numeric(8,1),
  crop           jsonb,
  placement      text,
  transfer       jsonb not null default '{}'::jsonb,     -- transfer details: type, temperature, time, pressure, peel ...
  approval_status text not null default 'unknown' check (approval_status in ('approved','pending','rejected','unknown')),
  version        int not null default 1,
  signature      text not null,                          -- hash of everything that matters; a change creates a new version
  source         text not null default 'deconetwork' check (source in ('deconetwork','manual')),
  storage_status text not null default 'pending_download' check (storage_status in ('pending_download','stored','failed','manual')),
  storage_path   text,
  content_hash   text,
  readable       boolean,                                -- null = not yet checked
  storage_error  text,
  is_current     boolean not null default true,
  supersedes     uuid references flow.artwork_files(id),
  note           text,
  created_by     text,
  created_at     timestamptz not null default now(),
  stored_at      timestamptz,
  superseded_at  timestamptz
);
create unique index artwork_current_area on flow.artwork_files (order_id, coalesce(deco_line_id, ''), area) where is_current;
create index artwork_order on flow.artwork_files (order_id, is_current);
create index artwork_pending on flow.artwork_files (storage_status) where is_current and storage_status in ('pending_download','failed');

create table flow.job_packs (
  id            uuid primary key default gen_random_uuid(),
  pack_ref      text not null unique,
  order_id      uuid not null references flow.orders(id),
  producer_id   uuid not null references flow.producers(id),
  movement_id   uuid references flow.tp_movements(id),
  version       int not null default 1,
  status        text not null default 'draft' check (status in ('blocked','ready','sent','superseded')),
  issues        jsonb not null default '[]'::jsonb,
  contents      jsonb not null default '{}'::jsonb,       -- what the producer sees: no costs, no margins, no source URLs
  artwork_sig   text not null,
  content_hash  text not null,
  built_by      text,
  built_at      timestamptz not null default now(),
  sent_by       text,
  sent_at       timestamptz
);
create index job_packs_order on flow.job_packs (order_id, producer_id, built_at desc);

alter table flow.artwork_files enable row level security;
alter table flow.job_packs enable row level security;
create policy artwork_read on flow.artwork_files for select to authenticated using (flow.is_member());
create policy job_packs_read on flow.job_packs for select to authenticated using (flow.is_member());
grant select on flow.artwork_files, flow.job_packs to authenticated;
grant all on flow.artwork_files, flow.job_packs to service_role;
grant usage, select on sequence flow.job_pack_seq to service_role;

insert into flow.flow_settings (key, value, description) values
 ('artwork.options', '{"require_approved":true,"require_stored":true,"require_production_file":true,"enforce_before_dispatch":true,
   "stitch_count_required_for":["embroidery"],"max_download_attempts":5}'::jsonb,
  'Checks applied before artwork can go to a producer. Set a flag to false to relax that check.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
create or replace function flow.artwork_signature(p jsonb) returns text language sql immutable as $$
  select md5(concat_ws('|', p->>'process', p->>'source_url', p->>'production_url', p->>'editable_url', p->>'proof_url', p->>'file_format',
    p->>'stitch_count', p->>'width_mm', p->>'height_mm', p->>'crop', p->>'placement', p->>'transfer', coalesce(p->>'approval_status', 'unknown')))
$$;

-- p_items: [{deco_order_id | order_id, deco_line_id, area, process, source_url, production_url, editable_url, proof_url, thumbnail_url,
--            file_format, stitch_count, width_mm, height_mm, crop, placement, transfer, approval_status}]
-- Idempotent: an unchanged item does nothing; a changed one becomes version n+1 and is queued for download. Manual replacements are never overwritten.
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
    if v_had and cur.source = 'manual' then v_manual := v_manual + 1; continue; end if;
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

create or replace function flow.artwork_pending_downloads(p_limit int default 25) returns jsonb
language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
    select a.id, o.order_ref, a.area, a.version, a.file_format, coalesce(a.production_url, a.source_url) as url, a.editable_url, a.proof_url
    from flow.artwork_files a join flow.orders o on o.id = a.order_id
    where a.is_current and a.storage_status = 'pending_download' and coalesce(a.production_url, a.source_url) is not null
    order by a.created_at limit greatest(p_limit, 1)) x
$$;

create or replace function flow.artwork_mark_stored(p_id uuid, p_storage_path text, p_content_hash text, p_readable boolean, p_error text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  update flow.artwork_files set storage_status = case when p_storage_path is not null and coalesce(p_readable, true) then 'stored' else 'failed' end,
    storage_path = p_storage_path, content_hash = p_content_hash, readable = p_readable, storage_error = left(p_error, 300),
    stored_at = case when p_storage_path is not null then now() end where id = p_id and is_current;
  if not found then return jsonb_build_object('ok', false, 'error', 'artwork row not found or no longer current'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Hand-upload / replace. The file is already in storage at p_storage_path. Creates the next version, source = manual (the sync will not overwrite it).
create or replace function flow.artwork_manual_replace(p_order uuid, p_deco_line_id text, p_area text, p_storage_path text, p_actor text, p_note text,
    p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare cur flow.artwork_files; v_id uuid;
begin
  begin
    if coalesce(p_storage_path, '') = '' or coalesce(p_area, '') = '' then raise exception 'area and an uploaded file are required'; end if;
    if coalesce(p_note, '') = '' then raise exception 'a note explaining the replacement is required'; end if;
    select * into cur from flow.artwork_files where order_id = p_order and coalesce(deco_line_id, '') = coalesce(p_deco_line_id, '') and area = p_area and is_current for update;
    if found then update flow.artwork_files set is_current = false, superseded_at = now() where id = cur.id; end if;
    insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, stitch_count, width_mm, height_mm, placement, transfer, approval_status, version, signature,
        source, storage_status, storage_path, readable, stored_at, supersedes, note, created_by, thumbnail_url, proof_url, production_url)
    values (p_order, p_deco_line_id, p_area, coalesce(p_meta->>'process', cur.process), coalesce(p_meta->>'file_format', cur.file_format),
        coalesce(nullif(p_meta->>'stitch_count', '')::int, cur.stitch_count), coalesce(nullif(p_meta->>'width_mm', '')::numeric, cur.width_mm),
        coalesce(nullif(p_meta->>'height_mm', '')::numeric, cur.height_mm), coalesce(p_meta->>'placement', cur.placement), coalesce(p_meta->'transfer', cur.transfer, '{}'::jsonb),
        coalesce(p_meta->>'approval_status', 'approved'), coalesce(cur.version, 0) + 1, md5(p_storage_path || now()::text), 'manual', 'manual', p_storage_path, true, now(), cur.id, p_note, p_actor,
        cur.thumbnail_url, cur.proof_url, cur.production_url)
    returning id into v_id;
    insert into flow.audit_log (actor, action, entity, entity_id, reason) values (p_actor, 'artwork_manual_replace', 'artwork', v_id::text, p_note);
    return jsonb_build_object('ok', true, 'artwork_id', v_id, 'version', coalesce(cur.version, 0) + 1);
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function flow.artwork_set_approval(p_id uuid, p_status text, p_actor text, p_note text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if p_status not in ('approved','pending','rejected') then return jsonb_build_object('ok', false, 'error', 'status must be approved, pending or rejected'); end if;
  if coalesce(p_note, '') = '' then return jsonb_build_object('ok', false, 'error', 'a note is required'); end if;
  update flow.artwork_files set approval_status = p_status, note = concat_ws(E'\n', note, p_actor || ': approval set to ' || p_status || ' - ' || p_note) where id = p_id and is_current;
  if not found then return jsonb_build_object('ok', false, 'error', 'artwork not found or not current'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id, reason) values (p_actor, 'artwork_set_approval', 'artwork', p_id::text, p_status || ': ' || p_note);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Validation. Every decoration method on a product line needs artwork (embroidery needs one per area).
-- ---------------------------------------------------------------------------
create or replace function flow.artwork_issues(p_order uuid)
returns table (deco_line_id text, method text, area text, issue text, severity text, detail text)
language plpgsql stable security definer set search_path = flow, public as $$
declare o jsonb := coalesce(flow.setting('artwork.options'), '{}'::jsonb);
  req_app boolean := coalesce((o->>'require_approved')::boolean, true); req_sto boolean := coalesce((o->>'require_stored')::boolean, true);
  req_prod boolean := coalesce((o->>'require_production_file')::boolean, true);
begin
  return query
  with grp as (
    select coalesce(l.deco_line_id, l.id::text) as dl, m as method, max(coalesce(l.emb_areas, 1)) as areas_needed
    from flow.order_lines l, unnest(l.decoration_methods) m where l.order_id = p_order and l.is_active group by 1, 2
  ), have as (
    select a.* from flow.artwork_files a where a.order_id = p_order and a.is_current
  ), miss as (
    select g.dl, g.method, g.areas_needed, (select count(*) from have h where coalesce(h.deco_line_id, '') in (g.dl, '') and coalesce(h.process, g.method) = g.method) as present from grp g
  )
  select m.dl, m.method, null::text, 'missing_artwork', 'blocking',
         format('%s needs %s artwork area(s) but %s found', m.method, case when m.method = 'embroidery' then m.areas_needed else 1 end, m.present)
  from miss m where m.present < case when m.method = 'embroidery' then m.areas_needed else 1 end
  union all
  select h.deco_line_id, h.process, h.area, 'not_approved', case when req_app then 'blocking' else 'warning' end, 'approval status is ' || h.approval_status
  from have h where h.approval_status <> 'approved'
  union all
  select h.deco_line_id, h.process, h.area, 'no_production_file', case when req_prod then 'blocking' else 'warning' end, 'no production file URL or upload'
  from have h where h.production_url is null and h.storage_path is null
  union all
  select h.deco_line_id, h.process, h.area, 'not_stored', case when req_sto then 'blocking' else 'warning' end,
         case when h.storage_status = 'failed' then 'download failed: ' || coalesce(h.storage_error, 'unknown') else 'file not yet downloaded to secure storage' end
  from have h where h.storage_status in ('pending_download','failed') and (h.production_url is not null or h.source_url is not null)
  union all
  select h.deco_line_id, h.process, h.area, 'unreadable_file', 'blocking', 'stored file could not be read: ' || coalesce(h.storage_error, 'unknown')
  from have h where h.readable is false
  union all
  select h.deco_line_id, h.process, h.area, 'missing_stitch_count', 'blocking', 'embroidery artwork has no stitch count'
  from have h where coalesce(h.process, '') in (select jsonb_array_elements_text(coalesce(o->'stitch_count_required_for', '[]'::jsonb))) and h.stitch_count is null;
end $$;

create or replace function flow.artwork_validate(p_order uuid) returns jsonb
language sql stable security definer set search_path = flow, public as $$
  select jsonb_build_object('ok', not exists (select 1 from flow.artwork_issues(p_order) where severity = 'blocking'),
    'blocking', (select count(*) from flow.artwork_issues(p_order) where severity = 'blocking'),
    'warnings', (select count(*) from flow.artwork_issues(p_order) where severity = 'warning'),
    'issues', coalesce((select jsonb_agg(to_jsonb(i)) from flow.artwork_issues(p_order) i), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- Job packs
-- ---------------------------------------------------------------------------
create or replace function flow.order_artwork_sig(p_order uuid) returns text language sql stable security definer set search_path = flow, public as $$
  select coalesce(md5(string_agg(a.id::text || ':' || a.version || ':' || a.approval_status || ':' || a.storage_status, ',' order by a.id)), md5(''))
  from flow.artwork_files a where a.order_id = p_order and a.is_current
$$;

-- Build (or rebuild) the pack a producer receives. p_movement narrows quantities to that consignment. Never includes costs, margins or source URLs.
create or replace function flow.build_job_pack(p_order uuid, p_producer uuid, p_actor text, p_movement uuid default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; pr flow.producers; v_issues jsonb; v_blocking int; v_contents jsonb; v_sig text; v_hash text; last flow.job_packs; v_id uuid; v_status text; v_ver int;
begin
  begin
    select * into o from flow.orders where id = p_order; if not found then raise exception 'order not found'; end if;
    select * into pr from flow.producers where id = p_producer and is_active; if not found then raise exception 'producer not found or inactive'; end if;
    v_issues := coalesce((select jsonb_agg(to_jsonb(i)) from flow.artwork_issues(p_order) i), '[]'::jsonb);
    v_blocking := (select count(*) from jsonb_array_elements(v_issues) x where x->>'severity' = 'blocking');
    v_sig := flow.order_artwork_sig(p_order);
    v_contents := jsonb_build_object(
      'order_ref', o.order_ref, 'due_date', (o.due_date at time zone 'Europe/London')::date,
      'special_instructions', pr.special_instructions,
      'lines', coalesce((
        select jsonb_agg(jsonb_build_object('deco_line_id', g.dl, 'product', g.product_name, 'sku_base', g.product_code, 'colour', g.colour, 'methods', g.methods,
            'placement', g.placement, 'sizes', g.sizes, 'total_qty', g.total) order by g.dl)
        from (select b.dl, max(b.product_name) product_name, max(b.product_code) product_code, b.colour,
                     (select array_agg(distinct m) from flow.order_lines x, unnest(x.decoration_methods) m where x.order_id = p_order and coalesce(x.deco_line_id, x.id::text) = b.dl) methods,
                     max(b.decoration_placement) placement,
                     jsonb_agg(jsonb_build_object('size', b.size, 'qty', b.q) order by b.size) sizes, sum(b.q) total
              from (select coalesce(l.deco_line_id, l.id::text) dl, l.product_name, l.product_code, l.colour, l.decoration_placement, l.size,
                           case when p_movement is null then greatest(l.qty_required - l.qty_produced, 0)
                                else coalesce((select sum(i.qty_sent) from flow.tp_movement_items i where i.movement_id = p_movement and i.order_line_id = l.id), 0) end q
                    from flow.order_lines l where l.order_id = p_order and l.is_active) b
              group by b.dl, b.colour) g), '[]'::jsonb),
      'artwork', coalesce((
        select jsonb_agg(jsonb_build_object('artwork_id', a.id, 'deco_line_id', a.deco_line_id, 'area', a.area, 'process', a.process, 'version', a.version, 'file_format', a.file_format,
            'file', a.storage_path, 'stitch_count', a.stitch_count, 'width_mm', a.width_mm, 'height_mm', a.height_mm, 'crop', a.crop, 'placement', a.placement,
            'transfer', a.transfer, 'approval', a.approval_status, 'has_proof', a.proof_url is not null) order by a.area)
        from flow.artwork_files a where a.order_id = p_order and a.is_current), '[]'::jsonb));
    v_hash := md5(v_contents::text || v_blocking::text);
    select * into last from flow.job_packs where order_id = p_order and producer_id = p_producer and coalesce(movement_id, '00000000-0000-0000-0000-000000000000') = coalesce(p_movement, '00000000-0000-0000-0000-000000000000')
      and status <> 'superseded' order by version desc limit 1;
    if found and last.content_hash = v_hash and last.artwork_sig = v_sig then
      return jsonb_build_object('ok', true, 'unchanged', true, 'pack_id', last.id, 'pack_ref', last.pack_ref, 'status', last.status, 'blocking', v_blocking, 'issues', v_issues);
    end if;
    if found and last.status <> 'sent' then update flow.job_packs set status = 'superseded' where id = last.id; end if;
    v_status := case when v_blocking > 0 then 'blocked' else 'ready' end;
    v_ver := coalesce(last.version, 0) + 1;
    insert into flow.job_packs (pack_ref, order_id, producer_id, movement_id, version, status, issues, contents, artwork_sig, content_hash, built_by)
    values ('JP-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.job_pack_seq')::text, 5, '0'), p_order, p_producer, p_movement, v_ver, v_status, v_issues, v_contents, v_sig, v_hash, p_actor)
    returning id into v_id;
    if v_blocking > 0 then
      perform flow.notify('job_pack_blocked', 'warning', 'Job pack blocked for ' || o.order_ref, v_blocking || ' artwork issue(s) must be fixed before this can go to ' || pr.name, 'order', p_order);
    end if;
    insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'build_job_pack', 'job_pack', v_id::text, jsonb_build_object('status', v_status, 'version', v_ver));
    return jsonb_build_object('ok', true, 'pack_id', v_id, 'pack_ref', (select pack_ref from flow.job_packs where id = v_id), 'status', v_status, 'version', v_ver, 'blocking', v_blocking, 'issues', v_issues);
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function flow.job_pack_mark_sent(p_pack uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare jp flow.job_packs;
begin
  select * into jp from flow.job_packs where id = p_pack for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'job pack not found'); end if;
  if jp.status = 'sent' then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  if jp.status <> 'ready' then return jsonb_build_object('ok', false, 'error', 'job pack is ' || jp.status || ' and cannot be sent'); end if;
  if jp.artwork_sig <> flow.order_artwork_sig(jp.order_id) then return jsonb_build_object('ok', false, 'error', 'artwork changed since this pack was built: rebuild it'); end if;
  update flow.job_packs set status = 'sent', sent_by = p_actor, sent_at = now() where id = p_pack;
  insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'job_pack_sent', 'job_pack', p_pack::text);
  return jsonb_build_object('ok', true);
end $$;

-- Dispatch gate: a consignment cannot be dispatched unless every order in it has a ready, current job pack for that producer.
create or replace function flow.trg_artwork_dispatch_gate() returns trigger language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; r record;
begin
  if new.event <> 'dispatched' or not coalesce((flow.setting('artwork.options')->>'enforce_before_dispatch')::boolean, true) then return new; end if;
  select * into m from flow.tp_movements where id = new.movement_id;
  if m.movement_type <> 'outbound_to_producer' then return new; end if;
  for r in select distinct i.order_id, o.order_ref from flow.tp_movement_items i join flow.orders o on o.id = i.order_id where i.movement_id = new.movement_id loop
    if not exists (select 1 from flow.job_packs j where j.order_id = r.order_id and j.producer_id = m.producer_id and j.status in ('ready','sent')
                   and j.artwork_sig = flow.order_artwork_sig(r.order_id)) then
      raise exception 'order % has no ready, up-to-date job pack for this producer: fix the artwork and rebuild the pack before dispatch', r.order_ref;
    end if;
  end loop;
  return new;
end $$;
create trigger tp_events_artwork_gate before insert on flow.tp_movement_events for each row execute function flow.trg_artwork_dispatch_gate();

-- ---------------------------------------------------------------------------
-- Dashboard read models
-- ---------------------------------------------------------------------------
create or replace view flow.v_artwork_status with (security_invoker = true) as
select o.id as order_id, o.order_ref, o.customer_name, o.due_date::date as due_date, o.deco_status, o.order_status,
       (select count(*) from flow.artwork_files a where a.order_id = o.id and a.is_current) as areas,
       (select count(*) from flow.artwork_files a where a.order_id = o.id and a.is_current and a.approval_status = 'approved') as approved,
       (select count(*) from flow.artwork_files a where a.order_id = o.id and a.is_current and a.storage_status in ('stored','manual')) as stored,
       (select count(*) from flow.artwork_issues(o.id) i where i.severity = 'blocking') as blocking_issues,
       (select string_agg(distinct i.issue, ', ') from flow.artwork_issues(o.id) i where i.severity = 'blocking') as issue_types,
       (select max(j.status) from flow.job_packs j where j.order_id = o.id and j.status <> 'superseded') as pack_status
from flow.orders o
where o.is_active and o.order_status <> 'dispatched' and exists (select 1 from flow.order_lines l where l.order_id = o.id and cardinality(l.decoration_methods) > 0);

create or replace view flow.v_job_packs with (security_invoker = true) as
select j.id, j.pack_ref, j.version, j.status, j.order_id, o.order_ref, j.producer_id, p.name as producer_name, j.movement_id, j.built_at, j.built_by, j.sent_at,
       jsonb_array_length(j.issues) as issue_count, (j.status in ('ready','blocked') and j.artwork_sig <> flow.order_artwork_sig(j.order_id)) as is_stale
from flow.job_packs j join flow.orders o on o.id = j.order_id join flow.producers p on p.id = j.producer_id where j.status <> 'superseded';

create or replace view flow.v_artwork_versions with (security_invoker = true) as
select a.id, o.order_ref, a.deco_line_id, a.area, a.process, a.version, a.is_current, a.source, a.approval_status, a.storage_status, a.file_format, a.stitch_count,
       a.width_mm, a.height_mm, a.created_at, a.created_by, a.note, a.thumbnail_url
from flow.artwork_files a join flow.orders o on o.id = a.order_id;

-- ---------------------------------------------------------------------------
-- n8n wrappers
-- ---------------------------------------------------------------------------
create or replace function public.flow_artwork_upsert(p_items jsonb, p_actor text default 'sync') returns jsonb language sql security definer set search_path = flow, public as $$ select flow.artwork_upsert(p_items, p_actor) $$;
create or replace function public.flow_artwork_pending_downloads(p_limit int default 25) returns jsonb language sql security definer set search_path = flow, public as $$ select jsonb_build_object('ok', true, 'items', flow.artwork_pending_downloads(p_limit)) $$;
create or replace function public.flow_artwork_mark_stored(p_id uuid, p_storage_path text, p_content_hash text, p_readable boolean, p_error text default null) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.artwork_mark_stored(p_id, p_storage_path, p_content_hash, p_readable, p_error) $$;
create or replace function public.flow_artwork_manual_replace(p_order uuid, p_deco_line_id text, p_area text, p_storage_path text, p_actor text, p_note text, p_meta jsonb default '{}'::jsonb) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.artwork_manual_replace(p_order, p_deco_line_id, p_area, p_storage_path, p_actor, p_note, p_meta) $$;
create or replace function public.flow_artwork_set_approval(p_id uuid, p_status text, p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.artwork_set_approval(p_id, p_status, p_actor, p_note) $$;
create or replace function public.flow_artwork_validate(p_order uuid) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.artwork_validate(p_order) $$;
create or replace function public.flow_build_job_pack(p_order uuid, p_producer uuid, p_actor text, p_movement uuid default null) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.build_job_pack(p_order, p_producer, p_actor, p_movement) $$;
create or replace function public.flow_job_pack_mark_sent(p_pack uuid, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.job_pack_mark_sent(p_pack, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'flow.artwork_signature(jsonb)', 'flow.artwork_upsert(jsonb,text)', 'flow.artwork_pending_downloads(int)', 'flow.artwork_mark_stored(uuid,text,text,boolean,text)',
    'flow.artwork_manual_replace(uuid,text,text,text,text,text,jsonb)', 'flow.artwork_set_approval(uuid,text,text,text)', 'flow.artwork_issues(uuid)', 'flow.artwork_validate(uuid)',
    'flow.order_artwork_sig(uuid)', 'flow.build_job_pack(uuid,uuid,text,uuid)', 'flow.job_pack_mark_sent(uuid,text)', 'flow.trg_artwork_dispatch_gate()',
    'public.flow_artwork_upsert(jsonb,text)', 'public.flow_artwork_pending_downloads(int)', 'public.flow_artwork_mark_stored(uuid,text,text,boolean,text)',
    'public.flow_artwork_manual_replace(uuid,text,text,text,text,text,jsonb)', 'public.flow_artwork_set_approval(uuid,text,text,text)', 'public.flow_artwork_validate(uuid)',
    'public.flow_build_job_pack(uuid,uuid,text,uuid)', 'public.flow_job_pack_mark_sent(uuid,text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on flow.v_artwork_status, flow.v_job_packs, flow.v_artwork_versions to authenticated;
