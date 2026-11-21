-- 21 Nov 2026: pre-production, phase B: the in-house DTF order to Super Print (applied to the live project 21 Nov 2026 as "flow_dtf_orders").
-- DTFs are bought from Super Print. For an IN-HOUSE order we order them from Super Print and apply them here; for a THIRD-PARTY order the third party orders
-- their own, so those placements are never put on a DTF order from here (they are skipped with the reason).
--   1. Super Print is added as a supplier (no email address yet: the DTF order email then waits as a draft that cannot be approved until an address is
--      added, exactly like a purchase order to a supplier with no address).
--   2. flow.dtf_batches: one DTF order (DTF-2026-00001). Status draft (its email is waiting for approval) -> ordered (the email was sent) -> received.
--      Cancelling the email cancels the DTF order and frees its placements.
--   3. flow.dtf_plan: what would go on a DTF order for some orders, and what is left out and why (read-only).
--      flow.dtf_build_order: makes the DTF order and queues its email through the normal approval queue (kind 'other', review required). The email lists
--      every artwork once with its total number of garments, a thumbnail, the orders it is for, and a time-limited download link for the file (the
--      links are made by the n8n action; the current sender cannot attach files).
--   4. When the email is SENT the placements go to "in progress" (amber, Prints ordered). flow.dtf_receive marks them received (green) in whole or part.
-- Nothing is sent by this change. Patches to existing functions are made in place and fail loudly if the line they patch is not found.

-- 1. The supplier --------------------------------------------------------------------------------------------------------------
insert into flow.suppliers (code, name) select 'SUPERPRINT', 'Super Print' where not exists (select 1 from flow.suppliers where code = 'SUPERPRINT' or lower(name) = 'super print');

-- 2. DTF orders ------------------------------------------------------------------------------------------------------------------
create sequence flow.dtf_batch_seq;
create table flow.dtf_batches (
  id          uuid primary key default gen_random_uuid(),
  batch_ref   text not null unique,
  supplier_id uuid not null references flow.suppliers(id),
  status      text not null default 'draft' check (status in ('draft', 'ordered', 'received', 'cancelled')),
  comm_id     uuid references flow.communications(id),
  note        text,
  created_by  text,
  created_at  timestamptz not null default now(),
  ordered_at  timestamptz,
  received_at timestamptz
);
alter table flow.dtf_items add column batch_id uuid references flow.dtf_batches(id);
create index dtf_items_batch on flow.dtf_items (batch_id) where batch_id is not null;

-- 3. What would go on a DTF order -----------------------------------------------------------------------------------------------
create or replace function flow.dtf_plan(p_order_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_in jsonb; v_out jsonb; v_designs jsonb;
begin
  if p_order_ids is null or cardinality(p_order_ids) = 0 then return jsonb_build_object('ok', false, 'error', 'Choose at least one order.'); end if;
  with cand as (
    select i.id, i.order_id, o.order_ref, i.area, i.qty, i.deco_line_id, flow.order_scope(o) as scope, ln.product_name, a.id as artwork_id, a.storage_path, a.thumbnail_url, a.file_format, a.content_hash, a.storage_status,
           (i.is_current and o.is_active) as live, i.status, i.batch_id
    from flow.dtf_items i join flow.orders o on o.id = i.order_id
    left join lateral (select l.product_name from flow.order_lines l where l.order_id = i.order_id and l.deco_line_id = i.deco_line_id order by l.id limit 1) ln on true
    left join lateral (select x.* from flow.artwork_files x where x.order_id = i.order_id and coalesce(x.deco_line_id, '') = i.deco_line_id and x.area = regexp_replace(i.area, ' \(\d+\)$', '')
                         and lower(coalesce(x.process, '')) = 'dtf' and x.is_current order by x.version desc limit 1) a on true
    where i.order_id = any (p_order_ids) and i.is_current
  ), judged as (
    select c.*, case when c.scope = 'third_party' then 'Third-party order: the decorator orders their own DTFs'
                     when not c.live then 'Order is not active'
                     when c.batch_id is not null then 'Already on a DTF order'
                     when c.status <> 'required' then 'Prints already ordered or done'
                     when c.qty <= 0 then 'No garments'
                     when c.artwork_id is null or c.storage_path is null or c.storage_status not in ('stored', 'manual') then 'No file yet'
                end as why
    from cand c
  )
  select coalesce(jsonb_agg(jsonb_build_object('item_id', id, 'order_id', order_id, 'order_ref', order_ref, 'area', area, 'qty', qty, 'product', product_name, 'storage_path', storage_path, 'thumbnail_url', thumbnail_url,
           'file_format', file_format, 'design_key', coalesce('h:' || content_hash, 'p:' || storage_path)) order by order_ref, area) filter (where why is null), '[]'::jsonb),
         coalesce(jsonb_agg(jsonb_build_object('item_id', id, 'order_ref', order_ref, 'area', area, 'qty', qty, 'reason', why) order by order_ref, area) filter (where why is not null), '[]'::jsonb)
    into v_in, v_out from judged;
  select coalesce(jsonb_agg(d order by (d->>'qty')::int desc, d->>'label'), '[]'::jsonb) into v_designs from (
    select jsonb_build_object('design_key', x.design_key, 'storage_path', min(x.storage_path), 'thumbnail_url', min(x.thumbnail_url), 'file_format', min(x.file_format), 'qty', sum(x.qty)::int, 'placements', count(*)::int,
             'orders', (select jsonb_agg(distinct y->>'order_ref') from jsonb_array_elements(v_in) y where y->>'design_key' = x.design_key),
             'areas', (select jsonb_agg(distinct y->>'area') from jsonb_array_elements(v_in) y where y->>'design_key' = x.design_key),
             'label', regexp_replace(min(x.storage_path), '^.*/', '')) as d
    from (select e->>'design_key' as design_key, e->>'storage_path' as storage_path, e->>'thumbnail_url' as thumbnail_url, e->>'file_format' as file_format, (e->>'qty')::int as qty from jsonb_array_elements(v_in) e) x
    group by x.design_key) q;
  return jsonb_build_object('ok', true, 'included', v_in, 'skipped', v_out, 'designs', v_designs);
end $$;

-- 4. Making the DTF order and queuing its email -------------------------------------------------------------------------------------
create or replace function flow.dtf_html_esc(p text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;') $$;

create or replace function flow.dtf_build_order(p_order_ids uuid[], p_links jsonb, p_actor text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_plan jsonb; v_sup flow.suppliers; v_id uuid; v_ref text; v_subj text; v_text text := ''; v_html text; v_rows text := ''; d jsonb; n int := 0; v_total int := 0; v_comm uuid;
        v_link text; v_missing int := 0; v_ids uuid[]; v_ordlist text;
begin
  v_plan := flow.dtf_plan(p_order_ids);
  if not (v_plan->>'ok')::bool then return v_plan; end if;
  if jsonb_array_length(v_plan->'included') = 0 then
    return jsonb_build_object('ok', false, 'error', 'Nothing can go on a DTF order from these orders.', 'skipped', v_plan->'skipped');
  end if;
  select * into v_sup from flow.suppliers where code = 'SUPERPRINT' and is_active;
  if v_sup.id is null then return jsonb_build_object('ok', false, 'error', 'Super Print is not set up as a supplier.'); end if;
  select array_agg((e->>'item_id')::uuid) into v_ids from jsonb_array_elements(v_plan->'included') e;
  v_ref := 'DTF-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.dtf_batch_seq')::text, 5, '0');
  insert into flow.dtf_batches (batch_ref, supplier_id, note, created_by) values (v_ref, v_sup.id, nullif(btrim(coalesce(p_note, '')), ''), p_actor) returning id into v_id;
  update flow.dtf_items set batch_id = v_id, updated_at = now() where id = any (v_ids);

  for d in select * from jsonb_array_elements(v_plan->'designs') loop
    n := n + 1; v_total := v_total + (d->>'qty')::int;
    v_link := p_links ->> (d->>'storage_path');
    if v_link is null or v_link = '' then v_missing := v_missing + 1; end if;
    v_ordlist := (select string_agg(x, ', ') from jsonb_array_elements_text(d->'orders') x);
    v_text := v_text || n || '. ' || (d->>'label') || ' - ' || (d->>'qty') || ' garment(s) - for ' || coalesce(v_ordlist, '') || coalesce(E'\n   Download: ' || v_link, E'\n   (download link not available)') || E'\n';
    v_rows := v_rows || '<tr><td style="padding:6px;border:1px solid #ccc;text-align:center">' || n || '</td><td style="padding:6px;border:1px solid #ccc">'
      || case when coalesce(d->>'thumbnail_url', '') <> '' then '<img src="' || flow.dtf_html_esc(d->>'thumbnail_url') || '" alt="" height="64" style="max-width:96px">' else '' end
      || '</td><td style="padding:6px;border:1px solid #ccc">' || flow.dtf_html_esc(d->>'label') || '<br><small>' || flow.dtf_html_esc(coalesce(v_ordlist, '')) || '</small></td>'
      || '<td style="padding:6px;border:1px solid #ccc;text-align:right"><b>' || (d->>'qty') || '</b></td><td style="padding:6px;border:1px solid #ccc">'
      || case when v_link is not null and v_link <> '' then '<a href="' || flow.dtf_html_esc(v_link) || '">Download the file</a>' else 'Link not available' end || '</td></tr>';
  end loop;
  v_subj := 'DTF order ' || v_ref || ' from ATAM (' || n || ' design' || case when n = 1 then '' else 's' end || ', ' || v_total || ' prints)';
  v_text := 'Hello,' || E'\n\n' || 'Please could we order the following DTF prints (' || v_ref || '). Quantities are the number of prints needed for each design.' || E'\n\n' || v_text
    || E'\nTotal: ' || v_total || E' prints.\nThe download links expire after 14 days; reply if you need them again.\n\nThank you\n';
  v_html := '<p>Hello,</p><p>Please could we order the following DTF prints (<b>' || flow.dtf_html_esc(v_ref) || '</b>). The quantity is the number of prints needed for each design.</p>'
    || '<table style="border-collapse:collapse;font-family:Arial,sans-serif;font-size:14px"><thead><tr><th style="padding:6px;border:1px solid #ccc">#</th><th style="padding:6px;border:1px solid #ccc">Picture</th><th style="padding:6px;border:1px solid #ccc">Design</th><th style="padding:6px;border:1px solid #ccc">Quantity</th><th style="padding:6px;border:1px solid #ccc">File</th></tr></thead><tbody>'
    || v_rows || '</tbody></table><p><b>Total: ' || v_total || ' prints.</b></p><p>The download links expire after 14 days; reply if you need them again.</p><p>Thank you</p>';
  v_comm := flow.queue_comm('other', case when coalesce(btrim(v_sup.email), '') = '' then '{}'::text[] else array[v_sup.email] end, v_subj, v_text, v_html, 'dtf_batch', v_id, v_sup.id, null, p_actor);
  update flow.dtf_batches set comm_id = v_comm where id = v_id;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'dtf_order_created', 'dtf_batches', v_id::text, jsonb_build_object('batch_ref', v_ref, 'items', cardinality(v_ids), 'designs', n, 'prints', v_total));
  return jsonb_build_object('ok', true, 'batch_id', v_id, 'batch_ref', v_ref, 'comm_id', v_comm, 'comm_ref', (select comm_ref from flow.communications where id = v_comm), 'comm_status', (select status from flow.communications where id = v_comm),
    'no_recipient', coalesce(btrim(v_sup.email), '') = '', 'designs', n, 'prints', v_total, 'placements', cardinality(v_ids), 'links_missing', v_missing, 'skipped', v_plan->'skipped');
end $$;

-- 5. Receiving the prints ----------------------------------------------------------------------------------------------------------
create or replace function flow.dtf_receive(p_batch uuid, p_item_ids uuid[], p_actor text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare b flow.dtf_batches; v_n int; v_left int;
begin
  select * into b from flow.dtf_batches where id = p_batch for update;
  if b.id is null then return jsonb_build_object('ok', false, 'error', 'That DTF order was not found.'); end if;
  if b.status <> 'ordered' then return jsonb_build_object('ok', false, 'error', case b.status when 'draft' then 'This DTF order has not been sent yet, so there is nothing to receive.' when 'received' then 'This DTF order has already been received.' else 'This DTF order was cancelled.' end); end if;
  update flow.dtf_items set status = 'done', updated_at = now() where batch_id = p_batch and status <> 'done' and (p_item_ids is null or id = any (p_item_ids));
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'Choose at least one print that arrived.'); end if;
  select count(*) into v_left from flow.dtf_items where batch_id = p_batch and status <> 'done';
  if v_left = 0 then update flow.dtf_batches set status = 'received', received_at = now() where id = p_batch; end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after, reason) values (p_actor, 'dtf_received', 'dtf_batches', p_batch::text, jsonb_build_object('received', v_n, 'left', v_left), nullif(btrim(coalesce(p_note, '')), ''));
  return jsonb_build_object('ok', true, 'batch_ref', b.batch_ref, 'received', v_n, 'left', v_left, 'complete', v_left = 0);
end $$;

-- 6. Sending the email moves the prints on; cancelling it frees them (patched in place) --------------------------------------------------
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.comm_mark_sent(uuid,text)'::regprocedure);
  v_new := replace(v_def, $a$  if c.kind = 'po_send' and c.entity_id is not null then$a$, $b$  if c.entity_type = 'dtf_batch' and c.entity_id is not null then
    update flow.dtf_batches set status = 'ordered', ordered_at = now() where id = c.entity_id and status = 'draft';
    update flow.dtf_items set status = 'in_progress', updated_at = now() where batch_id = c.entity_id and status = 'required';
  end if;
  if c.kind = 'po_send' and c.entity_id is not null then$b$);
  if v_new = v_def then raise exception 'comm_mark_sent: the line to patch was not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('flow.comm_cancel(uuid,text)'::regprocedure);
  v_new := replace(v_def, $a$  insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'cancel_comm', 'communication', p_id::text);$a$, $b$  update flow.dtf_batches set status = 'cancelled' where comm_id = p_id and status = 'draft';
  update flow.dtf_items set batch_id = null, updated_at = now() where batch_id in (select id from flow.dtf_batches where comm_id = p_id and status = 'cancelled');
  insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'cancel_comm', 'communication', p_id::text);$b$);
  if v_new = v_def then raise exception 'comm_cancel: the line to patch was not found'; end if;
  execute v_new;
end $$;

-- 7. What staff see ----------------------------------------------------------------------------------------------------------------------
create or replace view public.ui_dtf_items with (security_invoker = true) as
  select i.id, i.order_id, o.order_ref, o.customer_name, o.due_date, flow.order_scope(o) as scope, i.deco_line_id, ln.product_name, i.area, i.qty, i.status,
         a.id as artwork_id, a.thumbnail_url, a.file_format, a.storage_status, a.approval_status, a.content_hash, i.updated_at,
         i.batch_id, b.batch_ref, b.status as batch_status
  from flow.dtf_items i
  join flow.orders o on o.id = i.order_id
  left join flow.dtf_batches b on b.id = i.batch_id
  left join lateral (select l.product_name from flow.order_lines l where l.order_id = i.order_id and l.deco_line_id = i.deco_line_id order by l.id limit 1) ln on true
  left join lateral (select x.* from flow.artwork_files x where x.order_id = i.order_id and coalesce(x.deco_line_id, '') = i.deco_line_id and x.area = regexp_replace(i.area, ' \(\d+\)$', '')
                       and lower(coalesce(x.process, '')) = 'dtf' and x.is_current order by x.version desc limit 1) a on true
  where i.is_current and o.is_active;

create or replace view public.ui_dtf_batches with (security_invoker = true) as
  select b.id, b.batch_ref, b.status, s.name as supplier_name, (coalesce(btrim(s.email), '') <> '') as supplier_has_email, b.note, b.created_by, b.created_at, b.ordered_at, b.received_at,
         c.comm_ref, c.status as comm_status,
         (select count(*) from flow.dtf_items i where i.batch_id = b.id)::int as placements, (select coalesce(sum(i.qty), 0) from flow.dtf_items i where i.batch_id = b.id)::int as prints,
         (select count(*) from flow.dtf_items i where i.batch_id = b.id and i.status = 'done')::int as received
  from flow.dtf_batches b join flow.suppliers s on s.id = b.supplier_id left join flow.communications c on c.id = b.comm_id;

alter table flow.dtf_batches enable row level security;
create policy dtf_batches_read on flow.dtf_batches for select to authenticated using (flow.is_member());

create or replace function public.flow_dtf_plan(p_order_ids uuid[]) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.dtf_plan(p_order_ids) $$;
create or replace function public.flow_dtf_build_order(p_order_ids uuid[], p_links jsonb, p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.dtf_build_order(p_order_ids, p_links, p_actor, p_note) $$;
create or replace function public.flow_dtf_receive(p_batch uuid, p_item_ids uuid[], p_actor text, p_note text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.dtf_receive(p_batch, p_item_ids, p_actor, p_note) $$;

do $$
declare f text;
begin
  revoke all on flow.dtf_batches from public, anon, authenticated;
  grant select on flow.dtf_batches to authenticated;
  revoke all on public.ui_dtf_items, public.ui_dtf_batches from public, anon;
  grant select on public.ui_dtf_items, public.ui_dtf_batches to authenticated;
  foreach f in array array['flow.dtf_plan(uuid[])', 'flow.dtf_build_order(uuid[],jsonb,text,text)', 'flow.dtf_receive(uuid,uuid[],text,text)', 'flow.dtf_html_esc(text)',
                           'public.flow_dtf_plan(uuid[])', 'public.flow_dtf_build_order(uuid[],jsonb,text,text)', 'public.flow_dtf_receive(uuid,uuid[],text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_dtf_plan(uuid[]), public.flow_dtf_build_order(uuid[], jsonb, text, text), public.flow_dtf_receive(uuid, uuid[], text, text) to service_role;
end $$;
