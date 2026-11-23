-- 23 Nov 2026: staff side of third-party DTF prints (NOT YET APPLIED).
-- The decorator portal already lets a decorator mark their own transfers "in production" and "made". This adds the office side:
--  1. public.ui_dtf_third_party: every current third-party transfer with the decorator who is making it (the order's producer, or the
--     third_party.default_producer setting), the print file state, and who last moved it on and when. Team members only.
--  2. public.dtf_third_party_set(p_item_ids, p_to): lets a manager, admin or production planner move transfers forward ("in_progress" or "done")
--     on a decorator's behalf, e.g. when they confirm by phone or email. Forward moves only, third-party and not on an in-house DTF order,
--     written to the audit log with the person who did it.
create or replace view public.ui_dtf_third_party with (security_invoker = true) as
  select i.id, i.order_id, o.order_ref, o.customer_name, o.due_date, i.deco_line_id, ln.product_name, i.area, i.qty, i.status,
         flow.dtf_decorator(o) as producer_id, p.name as producer_name,
         a.id as artwork_id, a.thumbnail_url, a.file_format, a.storage_status, a.content_hash, i.status_by, i.status_at, i.updated_at
  from flow.dtf_items i
  join flow.orders o on o.id = i.order_id
  left join flow.producers p on p.id = flow.dtf_decorator(o)
  left join lateral (select l.product_name from flow.order_lines l where l.order_id = i.order_id and l.deco_line_id = i.deco_line_id order by l.id limit 1) ln on true
  left join lateral (select x.* from flow.artwork_files x where x.order_id = i.order_id and coalesce(x.deco_line_id, '') = i.deco_line_id and x.area = regexp_replace(i.area, ' \(\d+\)$', '')
                       and lower(coalesce(x.process, '')) = 'dtf' and x.is_current order by x.version desc limit 1) a on true
  where i.is_current and o.is_active and i.batch_id is null and flow.order_scope(o) = 'third_party' and flow.is_member();

create or replace function public.dtf_third_party_set(p_item_ids uuid[], p_to text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_n int; v_ids uuid[]; v_who text;
begin
  if not flow.has_role('admin', 'manager', 'production') then return jsonb_build_object('ok', false, 'error', 'Your role cannot confirm a decorator''s transfers.'); end if;
  if p_to not in ('in_progress', 'done') then return jsonb_build_object('ok', false, 'error', 'A transfer can only be moved to in production or made.'); end if;
  if p_item_ids is null or cardinality(p_item_ids) = 0 then return jsonb_build_object('ok', false, 'error', 'Choose at least one transfer.'); end if;
  if cardinality(p_item_ids) > 500 then return jsonb_build_object('ok', false, 'error', 'Choose 500 transfers or fewer at a time.'); end if;
  v_who := 'staff:' || coalesce(auth.uid()::text, 'unknown');
  with moved as (
    update flow.dtf_items i set status = p_to, status_by = v_who, status_at = now(), updated_at = now()
    from flow.orders o
    where i.id = any (p_item_ids) and o.id = i.order_id and i.is_current and o.is_active and i.batch_id is null and flow.order_scope(o) = 'third_party'
      and ((p_to = 'in_progress' and i.status = 'required') or (p_to = 'done' and i.status in ('required', 'in_progress')))
    returning i.id)
  select count(*)::int, array_agg(id) into v_n, v_ids from moved;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'Nothing was changed. These transfers may already be at that stage, or are not third-party work.'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_who, case when p_to = 'done' then 'staff_dtf_done' else 'staff_dtf_start' end, 'dtf_items', v_ids[1]::text, jsonb_build_object('count', v_n, 'ids', v_ids));
  return jsonb_build_object('ok', true, 'changed', v_n, 'requested', cardinality(p_item_ids));
end $$;

do $$
begin
  revoke all on public.ui_dtf_third_party from public, anon;
  grant select on public.ui_dtf_third_party to authenticated;
  revoke all on function public.dtf_third_party_set(uuid[], text) from public, anon;
  grant execute on function public.dtf_third_party_set(uuid[], text) to authenticated;
end $$;
