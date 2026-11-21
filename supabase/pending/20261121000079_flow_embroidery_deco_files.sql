-- 21 Nov 2026: embroidery, step 3: files to update in DecoNetwork, the old-file warning, and a bulk "done before".
-- (written and tested locally; NOT applied to the live project)
-- THE PROBLEM: while doing a job we rework the stitch file and upload it into Flow, which is right for that job. But DecoNetwork still holds the OLD file,
-- so when the next order for the same logo arrives we come close to using the old one.
-- WHAT THIS DOES:
--   * Approving a swatch FROM AN AREA (flow.emb_approve) records which file was approved for the design. If that file was uploaded by hand (it is not the
--     file DecoNetwork holds), the design goes on a "Files to update in DecoNetwork" list (deco_status = update_needed), and Flow remembers the signature of
--     the DecoNetwork file it replaced, so the next order that arrives carrying the old file is still recognised as the same logo.
--   * A person updates the file in DecoNetwork and ticks it off (flow.emb_deco_updated: who and when). That list is also the log.
--   * Until it is ticked off, every area that carries the old file shows a warning, with the approved file to use instead.
--   * A bulk "done before" (flow.emb_bulk_known): for ticked areas that are not yet linked, group identical logos for a customer into one design marked
--     done before, or link to an existing design that is already done. A design still in progress is never touched. Needed because Flow's history
--     starts in September 2026, so older logos look new.
-- Nothing is sent. Staff write through the n8n "Pre-production actions" workflow (service role only).

alter table flow.emb_designs
  add column approved_artwork_id uuid references flow.artwork_files(id),
  add column approved_signature  text,
  add column deco_signature      text,
  add column approved_by         text,
  add column approved_at         timestamptz,
  add column deco_status         text not null default 'in_sync' check (deco_status in ('in_sync', 'update_needed', 'updated')),
  add column deco_updated_by     text,
  add column deco_updated_at     timestamptz,
  add column deco_note           text;

-- 1. Approve a swatch from an area: records the approved file ----------------------------------------------------------------------------
create or replace function flow.emb_approve(p_design uuid, p_order uuid, p_deco_line text, p_area text, p_actor text, p_note text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare a flow.artwork_files; prev flow.artwork_files; r jsonb; v_actor text := flow.emb_actor(p_actor); v_manual boolean; v_status text; i int := 0;
begin
  select * into a from flow.artwork_files where order_id = p_order and coalesce(deco_line_id, '') = coalesce(p_deco_line, '') and area = p_area and is_current and lower(coalesce(process, '')) = 'embroidery';
  if not found then return jsonb_build_object('ok', false, 'error', 'That embroidery area is not on this order.'); end if;
  if not exists (select 1 from flow.emb_links l where l.design_id = p_design and l.order_id = p_order and l.deco_line_id = coalesce(p_deco_line, '') and l.area = p_area and l.is_active) then
    return jsonb_build_object('ok', false, 'error', 'This area is not linked to that design.'); end if;
  r := flow.emb_set_status(p_design, 'swatch_approved', v_actor, p_note);
  if not coalesce((r->>'ok')::boolean, false) then return r; end if;
  v_manual := a.source = 'manual';
  if v_manual then  -- find the DecoNetwork file this one replaced
    prev := a;
    while prev.source = 'manual' and prev.supersedes is not null and i < 25 loop select * into prev from flow.artwork_files where id = prev.supersedes; i := i + 1; exit when not found; end loop;
  end if;
  v_status := case when v_manual then 'update_needed' else 'in_sync' end;
  update flow.emb_designs set approved_artwork_id = a.id, approved_signature = a.signature, approved_by = v_actor, approved_at = now(),
         deco_signature = case when v_manual and prev.source = 'deconetwork' then prev.signature else deco_signature end,
         deco_status = v_status, deco_updated_by = case when v_manual then null else deco_updated_by end, deco_updated_at = case when v_manual then null else deco_updated_at end
   where id = p_design;
  insert into flow.emb_events (design_id, event, to_status, round, actor, note, order_ref)
    select p_design, 'file_approved', v_status, d.round, v_actor, case when v_manual then 'Approved file was uploaded by hand: DecoNetwork still holds the old one' else 'Approved file is the one DecoNetwork holds' end, o.order_ref
    from flow.emb_designs d, flow.orders o where d.id = p_design and o.id = p_order;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_design_file_approved', 'emb_designs', p_design::text, jsonb_build_object('artwork_id', a.id, 'version', a.version, 'source', a.source, 'deco_status', v_status));
  return r || jsonb_build_object('deco_status', v_status, 'file_source', a.source);
end $$;

-- 2. Tick it off once DecoNetwork has the new file ---------------------------------------------------------------------------------------------
create or replace function flow.emb_deco_updated(p_design uuid, p_actor text, p_note text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d flow.emb_designs; v_actor text := flow.emb_actor(p_actor); v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into d from flow.emb_designs where id = p_design for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'That design does not exist.'); end if;
  if d.deco_status <> 'update_needed' then return jsonb_build_object('ok', false, 'error', 'This design is not waiting for a DecoNetwork update.'); end if;
  update flow.emb_designs set deco_status = 'updated', deco_updated_by = v_actor, deco_updated_at = now(), deco_note = v_note where id = p_design;
  insert into flow.emb_events (design_id, event, to_status, round, actor, note) values (p_design, 'deco_updated', 'updated', d.round, v_actor, v_note);
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_design_deco_updated', 'emb_designs', p_design::text, jsonb_build_object('note', v_note));
  return jsonb_build_object('ok', true, 'deco_status', 'updated');
end $$;

-- 3. Bulk "done before" ------------------------------------------------------------------------------------------------------------------------
create or replace function flow.emb_bulk_known(p_areas jsonb, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare e jsonb; o flow.orders; a flow.artwork_files; x flow.emb_designs; v_actor text := flow.emb_actor(p_actor); v_map jsonb := '{}'::jsonb; v_key text; v_id uuid; v_line text;
        v_created int := 0; v_linked int := 0; v_skipped int := 0; v_busy int := 0; v_name text;
begin
  if p_areas is null or jsonb_typeof(p_areas) <> 'array' or jsonb_array_length(p_areas) = 0 then return jsonb_build_object('ok', false, 'error', 'Choose at least one area.'); end if;
  if jsonb_array_length(p_areas) > 300 then return jsonb_build_object('ok', false, 'error', 'Choose 300 areas or fewer at a time.'); end if;
  for e in select value from jsonb_array_elements(p_areas) loop
    v_line := coalesce(e->>'deco_line_id', '');
    select * into o from flow.orders where id = (e->>'order_id')::uuid;
    if not found or not o.is_active or o.customer_id is null then v_skipped := v_skipped + 1; continue; end if;
    select * into a from flow.artwork_files where order_id = o.id and coalesce(deco_line_id, '') = v_line and area = e->>'area' and is_current and lower(coalesce(process, '')) = 'embroidery';
    if not found then v_skipped := v_skipped + 1; continue; end if;
    if exists (select 1 from flow.emb_links l where l.order_id = o.id and l.deco_line_id = v_line and l.area = a.area and l.is_active) then v_skipped := v_skipped + 1; continue; end if;
    -- a design this customer already holds for the same artwork
    select d.* into x from flow.emb_designs d
      join flow.emb_links dl on dl.design_id = d.id and dl.is_active
      join flow.artwork_files b on b.order_id = dl.order_id and coalesce(b.deco_line_id, '') = dl.deco_line_id and b.area = dl.area and b.is_current
     where d.customer_id = o.customer_id and (b.signature = a.signature or d.deco_signature = a.signature) order by d.created_at limit 1;
    if found then
      if x.status in ('known', 'swatch_approved') then
        insert into flow.emb_links (order_id, deco_line_id, area, design_id, linked_by) values (o.id, v_line, a.area, x.id, v_actor);
        insert into flow.emb_events (design_id, event, round, actor, order_ref, note) values (x.id, 'linked', x.round, v_actor, o.order_ref, a.area);
        v_linked := v_linked + 1;
      else v_busy := v_busy + 1; end if;
      continue;
    end if;
    v_key := o.customer_id || '|' || a.signature;
    if v_map ? v_key then
      v_id := (v_map->>v_key)::uuid;
      insert into flow.emb_links (order_id, deco_line_id, area, design_id, linked_by) values (o.id, v_line, a.area, v_id, v_actor);
      insert into flow.emb_events (design_id, event, round, actor, order_ref, note) values (v_id, 'linked', 1, v_actor, o.order_ref, a.area);
      v_linked := v_linked + 1;
    else
      v_name := coalesce(o.customer_name, 'Customer') || ' · ' || a.area || ' · ' || o.order_ref;
      insert into flow.emb_designs (customer_id, customer_name, name, status, round, status_by, status_at, created_by) values (o.customer_id, o.customer_name, v_name, 'known', 1, v_actor, now(), v_actor) returning id into v_id;
      insert into flow.emb_links (order_id, deco_line_id, area, design_id, linked_by) values (o.id, v_line, a.area, v_id, v_actor);
      insert into flow.emb_events (design_id, event, to_status, round, actor, order_ref, note) values (v_id, 'created', 'known', 1, v_actor, o.order_ref, 'Marked as done before');
      insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_design_created', 'emb_designs', v_id::text, jsonb_build_object('order', o.order_ref, 'area', a.area, 'name', v_name, 'status', 'known', 'bulk', true));
      v_map := v_map || jsonb_build_object(v_key, v_id::text); v_created := v_created + 1;
    end if;
  end loop;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_bulk_known', 'emb_designs', null, jsonb_build_object('created', v_created, 'linked', v_linked, 'skipped', v_skipped, 'in_progress', v_busy));
  return jsonb_build_object('ok', true, 'created', v_created, 'linked', v_linked, 'skipped', v_skipped, 'in_progress', v_busy);
end $$;

create or replace function public.flow_emb_approve(p_design uuid, p_order uuid, p_deco_line text, p_area text, p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_approve(p_design, p_order, p_deco_line, p_area, p_actor, p_note) $$;
create or replace function public.flow_emb_deco_updated(p_design uuid, p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_deco_updated(p_design, p_actor, p_note) $$;
create or replace function public.flow_emb_bulk_known(p_areas jsonb, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_bulk_known(p_areas, p_actor) $$;

-- 4. Reading: the areas carry the old-file warning; the designs carry the update list ----------------------------------------------------------
create or replace view public.ui_emb_areas with (security_invoker = true) as
  select a.id as artwork_id, o.id as order_id, o.order_ref, o.customer_id, o.customer_name, o.due_date, flow.order_scope(o) as scope, o.order_status::text as order_status,
         coalesce(a.deco_line_id, '') as deco_line_id, a.area, a.thumbnail_url, a.stitch_count, a.width_mm, a.height_mm, a.file_format, a.storage_status, a.approval_status, a.version,
         d.id as design_id, d.name as design_name, d.status as design_status, d.round as design_round, d.status_by, d.status_at,
         coalesce(d.status, 'to_review') as area_status,
         case when d.id is null then s.id end as suggested_design_id, case when d.id is null then s.name end as suggested_design_name,
         case when d.id is null then s.status end as suggested_status, case when d.id is null then s.why end as suggested_why,
         a.storage_path,
         coalesce(d.deco_status, s.deco_status) as deco_status,
         (coalesce(d.deco_status, s.deco_status) = 'update_needed' and a.id is distinct from coalesce(d.approved_artwork_id, s.approved_artwork_id)) as deco_stale,
         ap.storage_path as approved_file_path
  from flow.artwork_files a
  join flow.orders o on o.id = a.order_id and o.is_active
  left join flow.emb_links l on l.order_id = a.order_id and l.deco_line_id = coalesce(a.deco_line_id, '') and l.area = a.area and l.is_active
  left join flow.emb_designs d on d.id = l.design_id
  left join lateral (
    select x.id, x.name, x.status, x.deco_status, x.approved_artwork_id,
           case when b.signature = a.signature or x.deco_signature = a.signature then 'Same artwork' else 'Same stitch count and size' end as why
    from flow.emb_designs x
    join flow.emb_links xl on xl.design_id = x.id and xl.is_active
    join flow.artwork_files b on b.order_id = xl.order_id and coalesce(b.deco_line_id, '') = xl.deco_line_id and b.area = xl.area and b.is_current
    where l.id is null and x.customer_id = o.customer_id
      and (b.signature = a.signature or x.deco_signature = a.signature or (coalesce(a.stitch_count, 0) > 0 and b.stitch_count = a.stitch_count and abs(coalesce(b.width_mm, 0) - coalesce(a.width_mm, 0)) <= 2 and abs(coalesce(b.height_mm, 0) - coalesce(a.height_mm, 0)) <= 2))
    order by (b.signature = a.signature or x.deco_signature = a.signature) desc, x.created_at limit 1) s on true
  left join flow.artwork_files ap on ap.id = coalesce(d.approved_artwork_id, s.approved_artwork_id)
  where a.is_current and lower(coalesce(a.process, '')) = 'embroidery';

create or replace view public.ui_emb_designs with (security_invoker = true) as
  select d.id, d.customer_id, d.customer_name, d.name, d.status, d.round, d.status_by, d.status_at, d.note, d.created_at,
         (select count(*)::int from flow.emb_links l where l.design_id = d.id and l.is_active) as orders_using,
         d.approved_artwork_id, d.approved_by, d.approved_at, d.deco_status, d.deco_updated_by, d.deco_updated_at, d.deco_note,
         ap.storage_path as approved_file_path, ap.file_format as approved_file_format, ap.thumbnail_url as approved_thumbnail_url, ap.version as approved_version
  from flow.emb_designs d
  left join flow.artwork_files ap on ap.id = d.approved_artwork_id;

do $$
declare f text;
begin
  revoke all on public.ui_emb_areas, public.ui_emb_designs from public, anon;
  grant select on public.ui_emb_areas, public.ui_emb_designs to authenticated;
  foreach f in array array['flow.emb_approve(uuid,uuid,text,text,text,text)', 'flow.emb_deco_updated(uuid,text,text)', 'flow.emb_bulk_known(jsonb,text)',
                           'public.flow_emb_approve(uuid,uuid,text,text,text,text)', 'public.flow_emb_deco_updated(uuid,text,text)', 'public.flow_emb_bulk_known(jsonb,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_emb_approve(uuid, uuid, text, text, text, text), public.flow_emb_deco_updated(uuid, text, text), public.flow_emb_bulk_known(jsonb, text) to service_role;
end $$;
