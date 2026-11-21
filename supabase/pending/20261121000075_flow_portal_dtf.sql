-- 21 Nov 2026: pre-production, phase C: DTF prints in the decorator portal (written and tested locally; NOT applied to the live project).
-- For a THIRD-PARTY order the decorator orders their own DTFs (from Super Print). They need to see what to order BEFORE the goods are sent, so these
-- functions work from the decorator assigned to the order (the order's decorator, or the default third-party decorator), not from a sent consignment.
--   * public.portal_dtf():        the DTF placements on the orders assigned to the signed-in decorator: order number, customer, due date, placement, product,
--                                 garments, status, and (only when Flow holds the real file) the file name and path, plus the picture. No prices, no addresses,
--                                 no internal links, nothing about other decorators or in-house orders. Finished prints stay visible for 14 days.
--   * public.portal_dtf_start(ids):  mark placements "in production" (amber) after the files are downloaded and the prints are being ordered.
--   * public.portal_dtf_done(ids):   mark placements produced / received (green).
--     Both only touch the decorator's own placements, only move forward, and are audited as "producer:<name>". Staff see the new status on the same
--     lights as everything else.
--   * flow.portal_can_read_dtf(path): the storage rule that lets a decorator fetch ONLY the current DTF files of their own assigned third-party orders
--     (it answers yes or no, nothing else). Created as a second, separate rule beside the job pack rule, only where the storage schema exists.
-- Placements on an in-house DTF order (a batch) are never visible here, and an order that stops being third party disappears from the decorator at once.

-- 1. Who makes an order's DTFs ------------------------------------------------------------------------------------------------------
create or replace function flow.dtf_decorator(o flow.orders) returns uuid language sql stable set search_path = flow, public as $$
  select case when flow.order_scope(o) = 'third_party'
              then coalesce(o.producer_id, nullif(flow.setting('third_party.default_producer')->>'producer_id', '')::uuid) end $$;

-- 2. Who changed a status, and when --------------------------------------------------------------------------------------------------
alter table flow.dtf_items add column status_by text;
alter table flow.dtf_items add column status_at timestamptz;

-- 3. What the decorator sees ---------------------------------------------------------------------------------------------------------------
create or replace function public.portal_dtf() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users;
begin
  pu := flow.portal_ctx();
  return jsonb_build_object('ok', true, 'items', coalesce((select jsonb_agg(x order by x->>'order_ref', x->>'area') from (
    select jsonb_build_object('id', i.id, 'order_ref', o.order_ref, 'customer', o.customer_name, 'due_date', o.due_date, 'area', i.area, 'product', ln.product_name, 'qty', i.qty, 'status', i.status,
             'file', case when a.storage_status in ('stored', 'manual') then a.storage_path end,
             'file_name', case when a.storage_status in ('stored', 'manual') then regexp_replace(a.storage_path, '^.*/', '') end,
             'file_format', case when a.storage_status in ('stored', 'manual') then a.file_format end,
             'thumbnail_url', a.thumbnail_url,
             'design_key', case when a.storage_status in ('stored', 'manual') then coalesce('h:' || a.content_hash, 'p:' || a.storage_path) end) as x
    from flow.dtf_items i
    join flow.orders o on o.id = i.order_id
    left join lateral (select l.product_name from flow.order_lines l where l.order_id = i.order_id and l.deco_line_id = i.deco_line_id order by l.id limit 1) ln on true
    left join lateral (select y.* from flow.artwork_files y where y.order_id = i.order_id and coalesce(y.deco_line_id, '') = i.deco_line_id and y.area = regexp_replace(i.area, ' \(\d+\)$', '')
                         and lower(coalesce(y.process, '')) = 'dtf' and y.is_current order by y.version desc limit 1) a on true
    where i.is_current and o.is_active and i.batch_id is null and flow.dtf_decorator(o) = pu.producer_id
      and (i.status <> 'done' or i.status_at > now() - interval '14 days')) q), '[]'::jsonb));
end $$;

-- 4. Moving placements forward -------------------------------------------------------------------------------------------------------------
create or replace function flow.portal_dtf_set(p_ids uuid[], p_to text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; v_name text; v_n int; v_ids uuid[];
begin
  pu := flow.portal_ctx();
  if p_ids is null or cardinality(p_ids) = 0 then return jsonb_build_object('ok', false, 'error', 'Choose at least one print.'); end if;
  if cardinality(p_ids) > 500 then return jsonb_build_object('ok', false, 'error', 'Choose 500 prints or fewer at a time.'); end if;
  select name into v_name from flow.producers where id = pu.producer_id;
  with moved as (
    update flow.dtf_items i set status = p_to, status_by = 'producer:' || coalesce(v_name, 'decorator'), status_at = now(), updated_at = now()
    from flow.orders o
    where i.id = any (p_ids) and o.id = i.order_id and i.is_current and o.is_active and i.batch_id is null and flow.dtf_decorator(o) = pu.producer_id
      and ((p_to = 'in_progress' and i.status = 'required') or (p_to = 'done' and i.status in ('required', 'in_progress')))
    returning i.id)
  select count(*)::int, array_agg(id) into v_n, v_ids from moved;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'Nothing was changed. These prints may already be at that stage, or they are not on your list.'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values ('producer:' || coalesce(v_name, 'decorator'), case when p_to = 'done' then 'portal_dtf_done' else 'portal_dtf_start' end, 'dtf_items', v_ids[1]::text, jsonb_build_object('count', v_n, 'ids', v_ids));
  return jsonb_build_object('ok', true, 'changed', v_n, 'requested', cardinality(p_ids));
end $$;
create or replace function public.portal_dtf_start(p_item_ids uuid[]) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.portal_dtf_set(p_item_ids, 'in_progress') $$;
create or replace function public.portal_dtf_done(p_item_ids uuid[]) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.portal_dtf_set(p_item_ids, 'done') $$;

-- 5. The storage rule: only the current DTF files of the decorator's own assigned third-party orders ---------------------------------------
create or replace function flow.portal_can_read_dtf(p_path text) returns boolean language sql stable security definer set search_path = flow, public as $$
  select p_path is not null and auth.uid() is not null and exists (
    select 1
    from flow.producer_users u
    join flow.producers pr on pr.id = u.producer_id and pr.is_active
    join flow.dtf_items i on i.is_current and i.batch_id is null
    join flow.orders o on o.id = i.order_id and o.is_active
    join flow.artwork_files a on a.order_id = i.order_id and coalesce(a.deco_line_id, '') = i.deco_line_id and a.area = regexp_replace(i.area, ' \(\d+\)$', '')
                             and lower(coalesce(a.process, '')) = 'dtf' and a.is_current and a.storage_status in ('stored', 'manual')
    where u.user_id = auth.uid() and u.is_active and flow.dtf_decorator(o) = u.producer_id and a.storage_path = p_path)
$$;

do $$
begin
  if to_regclass('storage.objects') is not null and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'artwork_dtf_decorator_read') then
    execute $p$create policy artwork_dtf_decorator_read on storage.objects for select to authenticated using (bucket_id = 'artwork' and flow.portal_can_read_dtf(name))$p$;
  end if;
end $$;

-- 6. Staff see who moved a print on ---------------------------------------------------------------------------------------------------------
create or replace view public.ui_dtf_items with (security_invoker = true) as
  select i.id, i.order_id, o.order_ref, o.customer_name, o.due_date, flow.order_scope(o) as scope, i.deco_line_id, ln.product_name, i.area, i.qty, i.status,
         a.id as artwork_id, a.thumbnail_url, a.file_format, a.storage_status, a.approval_status, a.content_hash, i.updated_at,
         i.batch_id, b.batch_ref, b.status as batch_status, i.status_by, i.status_at
  from flow.dtf_items i
  join flow.orders o on o.id = i.order_id
  left join flow.dtf_batches b on b.id = i.batch_id
  left join lateral (select l.product_name from flow.order_lines l where l.order_id = i.order_id and l.deco_line_id = i.deco_line_id order by l.id limit 1) ln on true
  left join lateral (select x.* from flow.artwork_files x where x.order_id = i.order_id and coalesce(x.deco_line_id, '') = i.deco_line_id and x.area = regexp_replace(i.area, ' \(\d+\)$', '')
                       and lower(coalesce(x.process, '')) = 'dtf' and x.is_current order by x.version desc limit 1) a on true
  where i.is_current and o.is_active;

do $$
begin
  revoke all on function public.portal_dtf() from public, anon;
  revoke all on function public.portal_dtf_start(uuid[]) from public, anon;
  revoke all on function public.portal_dtf_done(uuid[]) from public, anon;
  grant execute on function public.portal_dtf(), public.portal_dtf_start(uuid[]), public.portal_dtf_done(uuid[]) to authenticated;
  revoke all on function flow.portal_dtf_set(uuid[], text) from public, anon, authenticated;
  revoke all on function flow.dtf_decorator(flow.orders) from public, anon, authenticated;
  revoke all on function flow.portal_can_read_dtf(text) from public, anon;
  grant execute on function flow.portal_can_read_dtf(text) to authenticated;
end $$;
