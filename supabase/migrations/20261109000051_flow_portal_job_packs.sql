-- Decorators can read and download the job pack for their own jobs.
-- One function decides which packs a decorator may see for a consignment (the latest ready/sent pack for each order on it, never an older, blocked or
-- superseded one), and the same function decides which artwork files they may fetch from the private `artwork` bucket. So a decorator can only ever
-- reach files that belong to a job sent to them, always the current version, and nothing else in the bucket. Job pack contents already contain no
-- costs or margins; the portal function also returns only a fixed list of fields.

create or replace function flow.portal_packs(p_mv flow.tp_movements) returns setof flow.job_packs
language sql stable security definer set search_path = flow, public as $$
  select * from (
    select distinct on (p.order_id) p.*
    from flow.job_packs p
    where p.producer_id = p_mv.producer_id and p.status in ('ready', 'sent')
      and (p.movement_id = p_mv.id or (p.movement_id is null and p.order_id in (select i.order_id from flow.tp_movement_items i where i.movement_id = p_mv.id)))
    order by p.order_id, p.version desc, p.built_at desc) x
$$;

-- May the signed-in decorator read this file in the artwork bucket? Used by the storage rule below.
create or replace function flow.portal_can_read_artwork(p_path text) returns boolean
language sql stable security definer set search_path = flow, public as $$
  select p_path is not null and auth.uid() is not null and exists (
    select 1
    from flow.producer_users u
    join flow.tp_movements m on m.producer_id = u.producer_id
    cross join lateral flow.portal_packs(m) p
    cross join lateral jsonb_array_elements(coalesce(p.contents->'artwork', '[]'::jsonb)) a
    where u.user_id = auth.uid() and u.is_active
      and exists (select 1 from flow.producers pr where pr.id = u.producer_id and pr.is_active)
      and m.status not in ('draft', 'picked', 'packed', 'cancelled') and m.portal_declined_at is null
      and a->>'file' = p_path)
$$;

create or replace function public.portal_job_pack(p_code text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id);
  if m.portal_declined_at is not null then return jsonb_build_object('ok', true, 'packs', '[]'::jsonb); end if;
  return jsonb_build_object('ok', true, 'packs', coalesce((
    select jsonb_agg(jsonb_build_object(
      'pack_ref', p.pack_ref, 'version', p.version, 'order_ref', p.contents->>'order_ref', 'due_date', p.contents->>'due_date',
      'instructions', p.contents->>'special_instructions',
      'lines', coalesce((select jsonb_agg(jsonb_build_object('product', l->>'product', 'sku_base', l->>'sku_base', 'colour', l->>'colour', 'methods', l->'methods',
            'placement', l->>'placement', 'sizes', coalesce((select jsonb_agg(jsonb_build_object('size', z->>'size', 'qty', z->'qty')) from jsonb_array_elements(coalesce(l->'sizes', '[]'::jsonb)) z), '[]'::jsonb),
            'total_qty', l->'total_qty') order by l->>'product', l->>'colour')
          from jsonb_array_elements(coalesce(p.contents->'lines', '[]'::jsonb)) l), '[]'::jsonb),
      'artwork', coalesce((select jsonb_agg(jsonb_build_object(
            'area', a->>'area', 'process', a->>'process', 'version', a->'version', 'file_format', a->>'file_format', 'file', a->>'file',
            'file_name', case when a->>'file' is null then null else regexp_replace(a->>'file', '^.*/', '') end,
            'stitch_count', a->'stitch_count', 'width_mm', a->'width_mm', 'height_mm', a->'height_mm', 'placement', a->>'placement', 'approval', a->>'approval') order by a->>'area')
          from jsonb_array_elements(coalesce(p.contents->'artwork', '[]'::jsonb)) a), '[]'::jsonb))
      order by p.contents->>'order_ref')
    from flow.portal_packs(m) p), '[]'::jsonb));
end $$;

-- Storage rule: a signed-in decorator may read an artwork file only when flow.portal_can_read_artwork says it is part of one of their jobs.
-- (Skipped quietly where there is no storage schema, as in the local test database.)
do $$
begin
  if to_regclass('storage.objects') is not null and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'artwork_decorator_read') then
    execute $p$create policy artwork_decorator_read on storage.objects for select to authenticated using (bucket_id = 'artwork' and flow.portal_can_read_artwork(name))$p$;
  end if;
end $$;

do $$
begin
  revoke all on function flow.portal_packs(flow.tp_movements) from public, anon, authenticated;
  revoke all on function flow.portal_can_read_artwork(text) from public, anon;
  grant execute on function flow.portal_can_read_artwork(text) to authenticated;
  revoke all on function public.portal_job_pack(text) from public, anon;
  grant execute on function public.portal_job_pack(text) to authenticated;
end $$;
