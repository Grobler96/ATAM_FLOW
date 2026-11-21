-- 21 Nov 2026: pre-production, phase A: DTF prints and the traffic lights (written and tested locally; NOT applied to the live project).
-- Before an order can go into production three things happen at the same time: the DTF prints are made or ordered, the embroidery is checked, and the
-- stock is bought. This change adds what Flow needs to SHOW that, read-only. It sends nothing, changes no order and creates no purchase order.
--   1. A new tag condition, "the order uses a process" (method_includes), usable in tag rules and routing rules. It starts one tag: Needs DTF prints.
--   2. flow.dtf_items: one row per DTF placement on an order line (line + placement), with the number of garments that carry it and a status
--      (required = red, in_progress = amber, done = green). In this phase every row is "required": nothing changes the status yet.
--      Rows arrive from the order facts reader (the n8n workflow reads each order's lines, placements and processes); a read that has no "dtf"
--      list leaves the rows alone, and a placement that disappears from DecoNetwork is marked not current, never deleted.
--   3. public.ui_dtf_items (each DTF placement with its artwork thumbnail when Flow has one) and public.ui_preproduction (the three lights per
--      active order: prints, embroidery, stock, and whether the order is ready).
-- Lights: prints red = DTF needed and none started, amber = some started or finished, green = all done, none = no DTF. Embroidery red = artwork not
-- recorded or not approved and stored, amber = some approved or stored, green = every embroidery area approved and stored, none = no embroidery.
-- Stock green = secured, amber = partly allocated, red = not secured. Patches to existing functions are made in place from their current
-- definitions and fail loudly if the line they patch is not found.

-- 1. A tag / routing condition: the order uses a process (for example dtf) --------------------------------------------------
alter table flow.tag_rules drop constraint tag_rules_kind_check;
alter table flow.tag_rules add constraint tag_rules_kind_check check (kind in ('custom_field_filled', 'decorations_over', 'units_over', 'method_includes'));
alter table flow.routing_rules drop constraint routing_rules_kind_check;
alter table flow.routing_rules add constraint routing_rules_kind_check check (kind in ('decorations_over', 'units_over', 'tag_present', 'custom_field_filled', 'method_includes'));

do $$
declare v_def text; v_new text;
begin
  -- rule_check: evaluate the new condition (garments on active lines whose methods include the process)
  v_def := pg_get_functiondef('flow.rule_check(text,jsonb,uuid)'::regprocedure);
  v_new := replace(v_def, $a$  elsif p_kind = 'tag_present' then$a$, $b$  elsif p_kind = 'method_includes' then
    v_field := lower(btrim(coalesce(p_params->>'method', '')));
    if v_field = '' then return jsonb_build_object('matched', false, 'quantity', 0); end if;
    select coalesce(sum(l.qty_required), 0)::int, count(*)::int into v_qty, v_n from flow.order_lines l where l.order_id = p_order and l.is_active and v_field = any (l.decoration_methods);
    return jsonb_build_object('matched', v_n > 0, 'quantity', v_qty, 'evidence', v_qty || ' garment(s) use ' || v_field);
  elsif p_kind = 'tag_present' then$b$);
  if v_new = v_def then raise exception 'rule_check: the line to patch was not found'; end if;
  execute v_new;

  -- rr_check_params: the settings must name a process
  v_def := pg_get_functiondef('flow.rr_check_params(text,jsonb)'::regprocedure);
  v_new := replace(v_def, $a$  elsif p_kind = 'tag_present' then$a$, $b$  elsif p_kind = 'method_includes' then
    if btrim(coalesce(p_params->>'method', '')) = '' then return 'Give the name of the process.'; end if;
  elsif p_kind = 'tag_present' then$b$);
  if v_new = v_def then raise exception 'rr_check_params: the line to patch was not found'; end if;
  execute v_new;

  -- rr_save_tag_rule: the new condition is allowed for a tag
  v_def := pg_get_functiondef('flow.rr_save_tag_rule(uuid,text,text,text,text,jsonb,boolean,text,text)'::regprocedure);
  v_new := replace(v_def, $a$p_kind not in ('custom_field_filled', 'decorations_over', 'units_over')$a$, $b$p_kind not in ('custom_field_filled', 'decorations_over', 'units_over', 'method_includes')$b$);
  if v_new = v_def then raise exception 'rr_save_tag_rule: the line to patch was not found'; end if;
  execute v_new;
end $$;

insert into flow.tag_definitions (code, label, description) values
  ('needs_dtf', 'Needs DTF prints', 'The order has garments decorated with DTF, so the prints have to be made or ordered before it can go into production. The tag carries the number of garments.');
insert into flow.tag_rules (tag_code, name, kind, params, created_by) values
  ('needs_dtf', 'Garments decorated with DTF', 'method_includes', '{"method": "dtf"}', 'seed');

-- 2. DTF placements -----------------------------------------------------------------------------------------------------------
create table flow.dtf_items (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references flow.orders(id) on delete cascade,
  deco_line_id text not null,                     -- DecoNetwork product line (the same number the artwork rows use)
  area         text not null,                     -- the placement, for example Back or Left Chest (a repeat on the same line gets a number)
  qty          int not null check (qty >= 0),     -- garments on the line that carry this print
  status       text not null default 'required' check (status in ('required', 'in_progress', 'done')),
  is_current   boolean not null default true,
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (order_id, deco_line_id, area)
);
create index dtf_items_order on flow.dtf_items (order_id) where is_current;

create or replace function flow.dtf_sync(p_order uuid, p_items jsonb) returns int
language plpgsql security definer set search_path = flow, public as $$
declare it jsonb; v_n int := 0; v_qty int; v_ids uuid[] := '{}'; v_id uuid;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then return 0; end if;   -- a read with no list leaves the rows alone
  for it in select * from jsonb_array_elements(p_items) loop
    if coalesce(btrim(it->>'deco_line_id'), '') = '' or coalesce(btrim(it->>'area'), '') = '' then continue; end if;
    begin v_qty := (it->>'qty')::int; exception when others then v_qty := null; end;
    if v_qty is null or v_qty < 0 then continue; end if;
    insert into flow.dtf_items (order_id, deco_line_id, area, qty) values (p_order, btrim(it->>'deco_line_id'), btrim(it->>'area'), v_qty)
    on conflict (order_id, deco_line_id, area) do update
      set qty = excluded.qty, last_seen = now(), updated_at = case when flow.dtf_items.qty is distinct from excluded.qty or not flow.dtf_items.is_current then now() else flow.dtf_items.updated_at end, is_current = true
    returning id into v_id;
    v_ids := array_append(v_ids, v_id); v_n := v_n + 1;
  end loop;
  -- placements that are no longer on the order are marked not current, never deleted
  update flow.dtf_items set is_current = false, updated_at = now() where order_id = p_order and is_current and not (id = any (v_ids));
  return v_n;
end $$;

-- the order facts reader's save also keeps the DTF placements (patched in place)
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.order_facts_ingest(jsonb,text)'::regprocedure);
  v_new := replace(v_def, $a$    perform flow.rules_evaluate_order(v_order);$a$, $b$    perform flow.dtf_sync(v_order, it->'dtf');
    perform flow.rules_evaluate_order(v_order);$b$);
  if v_new = v_def then raise exception 'order_facts_ingest: the line to patch was not found'; end if;
  execute v_new;
end $$;

-- 3. What staff see ------------------------------------------------------------------------------------------------------------
create or replace view public.ui_dtf_items with (security_invoker = true) as
  select i.id, i.order_id, o.order_ref, o.customer_name, o.due_date, flow.order_scope(o) as scope, i.deco_line_id, ln.product_name, i.area, i.qty, i.status,
         a.id as artwork_id, a.thumbnail_url, a.file_format, a.storage_status, a.approval_status, a.content_hash, i.updated_at
  from flow.dtf_items i
  join flow.orders o on o.id = i.order_id
  left join lateral (select l.product_name from flow.order_lines l where l.order_id = i.order_id and l.deco_line_id = i.deco_line_id order by l.id limit 1) ln on true
  left join lateral (select x.* from flow.artwork_files x where x.order_id = i.order_id and coalesce(x.deco_line_id, '') = i.deco_line_id and x.area = regexp_replace(i.area, ' \(\d+\)$', '')
                       and lower(coalesce(x.process, '')) = 'dtf' and x.is_current order by x.version desc limit 1) a on true
  where i.is_current and o.is_active;

create or replace view public.ui_preproduction with (security_invoker = true) as
  select o.id as order_id, o.order_ref, o.customer_name, o.due_date, o.order_status::text as order_status, flow.order_scope(o) as scope, o.total_units, o.decoration_methods,
         case when di.n = 0 and not ('dtf' = any (o.decoration_methods)) then 'none' when di.n = 0 then 'red' when di.done = di.n then 'green' when di.done = 0 and di.started = 0 then 'red' else 'amber' end as prints,
         di.n as prints_items, di.units as prints_units, di.done as prints_done,
         case when not ('embroidery' = any (o.decoration_methods)) then 'none' when em.n = 0 then 'red' when em.approved = em.n and em.stored = em.n then 'green' when em.approved > 0 or em.stored > 0 then 'amber' else 'red' end as embroidery,
         em.n as embroidery_areas, em.approved as embroidery_approved, em.stored as embroidery_stored,
         case when o.stock_secured then 'green' when o.alloc_state::text = 'partial' then 'amber' else 'red' end as stock
  from flow.orders o
  cross join lateral (select count(*)::int as n, coalesce(sum(i.qty), 0)::int as units, count(*) filter (where i.status = 'done')::int as done, count(*) filter (where i.status = 'in_progress')::int as started
                      from flow.dtf_items i where i.order_id = o.id and i.is_current) di
  cross join lateral (select count(*)::int as n, count(*) filter (where a.approval_status = 'approved')::int as approved, count(*) filter (where a.storage_status in ('stored', 'manual'))::int as stored
                      from flow.artwork_files a where a.order_id = o.id and a.is_current and lower(coalesce(a.process, '')) = 'embroidery') em
  where o.is_active;

alter table flow.dtf_items enable row level security;
create policy dtf_items_read on flow.dtf_items for select to authenticated using (flow.is_member());

do $$
begin
  revoke all on flow.dtf_items from public, anon, authenticated;
  grant select on flow.dtf_items to authenticated;
  revoke all on public.ui_dtf_items, public.ui_preproduction from public, anon;
  grant select on public.ui_dtf_items, public.ui_preproduction to authenticated;
  revoke all on function flow.dtf_sync(uuid, jsonb) from public, anon, authenticated;
end $$;

-- Tag every order that has DTF now (shadow-safe: tags only).
select flow.rules_evaluate_all('migration 73');
