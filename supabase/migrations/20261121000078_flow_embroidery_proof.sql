-- 21 Nov 2026: embroidery, step 2a: the proof sheet. The Embroidery list now also carries the stored file's path, so staff can download the stitch file
-- from the same place they print its proof sheet (APPLIED to the live project on 21 Nov 2026).
-- Only one column is added, at the end of public.ui_emb_areas. Staff already read the artwork files with their login (the same access the Artwork
-- screen uses); the proof sheet itself is made in the browser, so nothing else in the database changes.

create or replace view public.ui_emb_areas with (security_invoker = true) as
  select a.id as artwork_id, o.id as order_id, o.order_ref, o.customer_id, o.customer_name, o.due_date, flow.order_scope(o) as scope, o.order_status::text as order_status,
         coalesce(a.deco_line_id, '') as deco_line_id, a.area, a.thumbnail_url, a.stitch_count, a.width_mm, a.height_mm, a.file_format, a.storage_status, a.approval_status, a.version,
         d.id as design_id, d.name as design_name, d.status as design_status, d.round as design_round, d.status_by, d.status_at,
         coalesce(d.status, 'to_review') as area_status,
         case when d.id is null then s.id end as suggested_design_id, case when d.id is null then s.name end as suggested_design_name,
         case when d.id is null then s.status end as suggested_status, case when d.id is null then s.why end as suggested_why,
         a.storage_path
  from flow.artwork_files a
  join flow.orders o on o.id = a.order_id and o.is_active
  left join flow.emb_links l on l.order_id = a.order_id and l.deco_line_id = coalesce(a.deco_line_id, '') and l.area = a.area and l.is_active
  left join flow.emb_designs d on d.id = l.design_id
  left join lateral (
    select x.id, x.name, x.status, case when b.signature = a.signature then 'Same artwork' else 'Same stitch count and size' end as why
    from flow.emb_designs x
    join flow.emb_links xl on xl.design_id = x.id and xl.is_active
    join flow.artwork_files b on b.order_id = xl.order_id and coalesce(b.deco_line_id, '') = xl.deco_line_id and b.area = xl.area and b.is_current
    where l.id is null and x.customer_id = o.customer_id
      and (b.signature = a.signature or (coalesce(a.stitch_count, 0) > 0 and b.stitch_count = a.stitch_count and abs(coalesce(b.width_mm, 0) - coalesce(a.width_mm, 0)) <= 2 and abs(coalesce(b.height_mm, 0) - coalesce(a.height_mm, 0)) <= 2))
    order by (b.signature = a.signature) desc, x.created_at limit 1) s on true
  where a.is_current and lower(coalesce(a.process, '')) = 'embroidery';

grant select on public.ui_emb_areas to authenticated;
