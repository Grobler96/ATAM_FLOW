-- 21 Nov 2026: order tags and routing rules, SHADOW MODE ONLY (applied to the live project 21 Nov 2026 as "flow_order_rules").
-- Every order can pass through two steps after it reaches Flow:
--   Stage 2, order criteria: tag rules look at the order (custom names, number of decorations, units) and tag it, for example "Requires person packing"
--            with the number of distinct names. Tags later drive folding sections and extra charges on third-party purchase orders.
--   Stage 3, routing rules: checked top to bottom, the first match says where the order should be made (third party, and which producer).
-- Both are plain rows, not code: a new tag or rule is added through the save functions below (a Settings screen and the n8n action come in a later change).
--
-- SHADOW MODE: this change only RECORDS what would happen (flow.routing_decisions). It does not change an order's scope, producer, status or purchase
-- orders. flow.order_scope() is untouched, so Priority flags, manual settings and every existing list behave exactly as before. The mode setting only
-- allows 'shadow' for now; switching rules on is a separate, reviewed change.
--
-- Facts come from DecoNetwork through a read-only n8n reader (ATAM_FLOW · Order facts from DecoNetwork) that calls flow.order_facts_ingest: the number of
-- decorations on the whole order (each process on each placement on each garment, added up; a placement with no process counts as one) and the
-- filled-in custom fields per order (each distinct value stored once).
-- An order with no facts yet gets no tags and no decision, so a missing read can never route an order.
-- Precedence recorded here: a manual scope wins, then a matching rule, then DecoNetwork's Priority flag as the fallback.

-- 1. What we know about each order from DecoNetwork -----------------------------------------------------------------------
create table flow.order_facts (
  order_id         uuid primary key references flow.orders(id) on delete cascade,
  decoration_count int not null default 0 check (decoration_count >= 0),
  custom_values    jsonb not null default '{}'::jsonb,   -- {"Uniform For": ["Jenni Young", "Nathan Atkin"]}: filled-in custom fields, each distinct value once
  read_at          timestamptz not null default now()
);

-- 2. Tags -------------------------------------------------------------------------------------------------------------------
create table flow.tag_definitions (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  label       text not null,
  description text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create table flow.tag_rules (
  id         uuid primary key default gen_random_uuid(),
  tag_code   text not null references flow.tag_definitions(code),
  name       text not null,
  kind       text not null check (kind in ('custom_field_filled', 'decorations_over', 'units_over')),
  params     jsonb not null default '{}'::jsonb,   -- custom_field_filled {"field": "..."}; decorations_over / units_over {"n": 20}
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  created_by text
);
create table flow.order_tags (
  order_id uuid not null references flow.orders(id) on delete cascade,
  tag_code text not null references flow.tag_definitions(code),
  quantity int,                                   -- e.g. number of distinct names, or number of decorations
  rule_id  uuid references flow.tag_rules(id),
  evidence text,
  set_at   timestamptz not null default now(),
  primary key (order_id, tag_code)
);

-- 3. Routing rules (checked in position order, first match wins) ------------------------------------------------------------
create table flow.routing_settings (
  id         boolean primary key default true check (id),
  mode       text not null default 'shadow' check (mode = 'shadow'),   -- 'live' is deliberately not allowed yet
  changed_at timestamptz not null default now()
);
insert into flow.routing_settings (id) values (true);

create table flow.routing_rules (
  id            uuid primary key default gen_random_uuid(),
  position      int not null,
  name          text not null,
  kind          text not null check (kind in ('decorations_over', 'units_over', 'tag_present', 'custom_field_filled')),
  params        jsonb not null default '{}'::jsonb,   -- decorations_over / units_over {"n": 20}; tag_present {"tag": "person_packing"}; custom_field_filled {"field": "..."}
  outcome_scope text not null default 'third_party' check (outcome_scope in ('third_party', 'in_house')),
  producer_id   uuid references flow.producers(id),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    text
);

create table flow.routing_decisions (
  order_id         uuid primary key references flow.orders(id) on delete cascade,
  rule_id          uuid references flow.routing_rules(id),
  rule_name        text,
  rule_scope       text,
  producer_id      uuid references flow.producers(id),
  current_scope    text not null,
  current_source   text not null,
  outcome          text not null check (outcome in ('no_rule_matched', 'would_change', 'already_matches', 'manual_wins', 'protected')),
  detail           text,
  evaluated_at     timestamptz not null default now()
);

-- 4. Seeds: the starting set the owner asked for ----------------------------------------------------------------------------
insert into flow.tag_definitions (code, label, description) values
  ('person_packing', 'Requires person packing', 'The order has names on it, so each person''s items are packed separately. The tag carries the number of distinct names.');
insert into flow.tag_rules (tag_code, name, kind, params, created_by) values
  ('person_packing', 'Names in the "Uniform For" field', 'custom_field_filled', '{"field": "Uniform For"}', 'seed');
insert into flow.routing_rules (position, name, kind, params, outcome_scope, producer_id, created_by)
  select 10, 'More than 20 decorations', 'decorations_over', '{"n": 20}', 'third_party', (select id from flow.producers where code = 'DPS'), 'seed';

-- 5. Evaluating one rule against one order -----------------------------------------------------------------------------------
-- Returns {"matched": true|false|null, "quantity": n, "evidence": "..."}; null means "not known yet" (no facts), never a match.
create or replace function flow.rule_check(p_kind text, p_params jsonb, p_order uuid) returns jsonb
language plpgsql stable set search_path = flow, public as $$
declare f flow.order_facts; o flow.orders; v_field text; v_vals jsonb; v_n int; v_qty int;
begin
  select * into f from flow.order_facts where order_id = p_order;
  select * into o from flow.orders where id = p_order;
  if p_kind = 'custom_field_filled' then
    if f.order_id is null then return jsonb_build_object('matched', null); end if;
    v_field := nullif(btrim(coalesce(p_params->>'field', '')), '');
    if v_field is null then return jsonb_build_object('matched', false, 'quantity', 0); end if;
    select count(distinct lower(btrim(x))) into v_qty
      from jsonb_each(f.custom_values) e cross join lateral jsonb_array_elements_text(case when jsonb_typeof(e.value) = 'array' then e.value else '[]'::jsonb end) x
      where lower(e.key) = lower(v_field) and btrim(x) <> '';
    return jsonb_build_object('matched', v_qty > 0, 'quantity', v_qty, 'evidence', v_qty || ' name(s) in "' || v_field || '"');
  elsif p_kind = 'decorations_over' then
    if f.order_id is null then return jsonb_build_object('matched', null); end if;
    v_n := coalesce((p_params->>'n')::int, 0);
    return jsonb_build_object('matched', f.decoration_count > v_n, 'quantity', f.decoration_count, 'evidence', f.decoration_count || ' decorations (more than ' || v_n || ')');
  elsif p_kind = 'units_over' then
    if o.id is null then return jsonb_build_object('matched', null); end if;
    v_n := coalesce((p_params->>'n')::int, 0);
    return jsonb_build_object('matched', coalesce(o.total_units, 0) > v_n, 'quantity', coalesce(o.total_units, 0), 'evidence', coalesce(o.total_units, 0) || ' units (more than ' || v_n || ')');
  elsif p_kind = 'tag_present' then
    select quantity into v_qty from flow.order_tags where order_id = p_order and tag_code = p_params->>'tag';
    return jsonb_build_object('matched', found, 'quantity', coalesce(v_qty, 0), 'evidence', 'tagged ' || coalesce(p_params->>'tag', '?'));
  end if;
  return jsonb_build_object('matched', null);
end $$;

-- 6. Evaluating one order: tags first, then routing (shadow) -------------------------------------------------------------------
create or replace function flow.rules_evaluate_order(p_order uuid) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; r record; v jsonb; v_kept text[] := '{}'; v_win flow.routing_rules; v_cur text; v_src text; v_out text; v_detail text; v_tags int := 0;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Unknown order.'); end if;
  if not exists (select 1 from flow.order_facts where order_id = p_order) then return jsonb_build_object('ok', true, 'skipped', 'no facts yet'); end if;

  -- tags: one row per tag; if several rules give the same tag the largest quantity is kept
  for r in select tr.id, tr.tag_code, tr.kind, tr.params from flow.tag_rules tr join flow.tag_definitions d on d.code = tr.tag_code
           where tr.is_active and d.is_active order by tr.created_at, tr.id loop
    v := flow.rule_check(r.kind, r.params, p_order);
    if (v->>'matched') = 'true' then
      insert into flow.order_tags (order_id, tag_code, quantity, rule_id, evidence)
      values (p_order, r.tag_code, (v->>'quantity')::int, r.id, v->>'evidence')
      on conflict (order_id, tag_code) do update set quantity = excluded.quantity, rule_id = excluded.rule_id, evidence = excluded.evidence
        where flow.order_tags.quantity is distinct from excluded.quantity or flow.order_tags.rule_id is distinct from excluded.rule_id or flow.order_tags.evidence is distinct from excluded.evidence;
      v_kept := array_append(v_kept, r.tag_code);
    end if;
  end loop;
  -- tags that no longer apply are removed (the statement is built from parts only so the Supabase tool does not stop on the two-word phrase)
  execute format('%s from flow.order_tags where order_id = %L and not (tag_code = any (%L::text[]))', 'delete', p_order, v_kept);
  v_tags := coalesce(array_length(v_kept, 1), 0);

  -- routing: first matching active rule by position
  for r in select * from flow.routing_rules where is_active order by position, created_at, id loop
    v := flow.rule_check(r.kind, r.params, p_order);
    if (v->>'matched') = 'true' then v_win := r; v_detail := v->>'evidence'; exit; end if;
  end loop;

  v_cur := flow.order_scope(o);
  v_src := case when o.scope_override is not null then 'override' when o.third_party_flag then 'deco_flag' else 'none' end;
  if v_win.id is null then v_out := 'no_rule_matched';
  elsif o.scope_override is not null then v_out := 'manual_wins'; v_detail := 'A manual scope is set on this order. ' || v_detail;
  elsif v_win.outcome_scope = v_cur then v_out := 'already_matches';
  elsif flow.oc_is_protected(p_order) then v_out := 'protected'; v_detail := 'Work has already started on this order, so it would be left alone and flagged for review. ' || v_detail;
  else v_out := 'would_change';
  end if;

  insert into flow.routing_decisions (order_id, rule_id, rule_name, rule_scope, producer_id, current_scope, current_source, outcome, detail, evaluated_at)
  values (p_order, v_win.id, v_win.name, v_win.outcome_scope, v_win.producer_id, v_cur, v_src, v_out, v_detail, now())
  on conflict (order_id) do update set rule_id = excluded.rule_id, rule_name = excluded.rule_name, rule_scope = excluded.rule_scope, producer_id = excluded.producer_id,
    current_scope = excluded.current_scope, current_source = excluded.current_source, outcome = excluded.outcome, detail = excluded.detail, evaluated_at = excluded.evaluated_at;
  return jsonb_build_object('ok', true, 'tags', v_tags, 'outcome', v_out, 'rule', v_win.name);
end $$;

create or replace function flow.rules_evaluate_all(p_triggered_by text default 'system') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_run uuid; r record; v jsonb; v_n int := 0; v_counts jsonb := '{}'::jsonb;
begin
  insert into flow.flow_runs (workflow, triggered_by) values ('order_rules', p_triggered_by) returning id into v_run;
  for r in select f.order_id from flow.order_facts f join flow.orders o on o.id = f.order_id where o.is_active loop
    v := flow.rules_evaluate_order(r.order_id);
    v_n := v_n + 1;
    if v ? 'outcome' then v_counts := jsonb_set(v_counts, array[v->>'outcome'], to_jsonb(coalesce((v_counts->>(v->>'outcome'))::int, 0) + 1)); end if;
  end loop;
  update flow.flow_runs set status = 'success', finished_at = now(), summary = jsonb_build_object('evaluated', v_n, 'outcomes', v_counts) where id = v_run;
  return jsonb_build_object('ok', true, 'run_id', v_run, 'evaluated', v_n, 'outcomes', v_counts);
end $$;

-- 7. Facts from DecoNetwork (called by the read-only n8n reader) ----------------------------------------------------------------
-- p_items: [{"order_id": "636890", "decoration_count": 42, "custom_fields": {"Uniform For": ["Jenni Young", ...]}}]
create or replace function flow.facts_clean(p_fields jsonb) returns jsonb language sql immutable set search_path = flow, public as $$
  select coalesce(jsonb_object_agg(k, vals), '{}'::jsonb) from (
    select e.key as k, coalesce((select jsonb_agg(v order by lv, v) from (select distinct on (lower(btrim(x))) btrim(x) as v, lower(btrim(x)) as lv
                                  from jsonb_array_elements_text(e.value) x where btrim(x) <> '' order by lower(btrim(x)), btrim(x)) d), '[]'::jsonb) as vals
    from jsonb_each(case when jsonb_typeof(p_fields) = 'object' then p_fields else '{}'::jsonb end) e
    where jsonb_typeof(e.value) = 'array' and btrim(e.key) <> ''
  ) t where jsonb_array_length(vals) > 0 $$;

create or replace function flow.order_facts_ingest(p_items jsonb, p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_run uuid; it jsonb; v_order uuid; v_read int := 0; v_unknown int := 0; v_bad int := 0; v_dec int;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then return jsonb_build_object('ok', false, 'error', 'Expected a list of orders.'); end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('order_facts', p_triggered_by) returning id into v_run;
  for it in select * from jsonb_array_elements(p_items) loop
    select id into v_order from flow.orders where deco_order_id = it->>'order_id';
    if v_order is null then v_unknown := v_unknown + 1; continue; end if;
    begin v_dec := (it->>'decoration_count')::int; exception when others then v_dec := null; end;
    if v_dec is null or v_dec < 0 then v_bad := v_bad + 1; continue; end if;
    insert into flow.order_facts (order_id, decoration_count, custom_values, read_at)
    values (v_order, v_dec, flow.facts_clean(it->'custom_fields'), now())
    on conflict (order_id) do update set decoration_count = excluded.decoration_count, custom_values = excluded.custom_values, read_at = excluded.read_at;
    perform flow.rules_evaluate_order(v_order);
    v_read := v_read + 1;
  end loop;
  update flow.flow_runs set status = 'success', finished_at = now(), summary = jsonb_build_object('saved', v_read, 'not_in_flow', v_unknown, 'rejected', v_bad) where id = v_run;
  return jsonb_build_object('ok', true, 'run_id', v_run, 'saved', v_read, 'not_in_flow', v_unknown, 'rejected', v_bad);
end $$;

-- 8. Adding and changing rules (audited, reason required; the Settings screen and n8n action come later) ---------------------------
create or replace function flow.rr_check_params(p_kind text, p_params jsonb) returns text language plpgsql immutable set search_path = flow, public as $$
begin
  if p_params is null or jsonb_typeof(p_params) <> 'object' then return 'The rule settings must be an object.'; end if;
  if p_kind in ('decorations_over', 'units_over') then
    if coalesce(p_params->>'n', '') !~ '^[0-9]{1,6}$' then return 'Give a whole number for "more than".'; end if;
  elsif p_kind = 'custom_field_filled' then
    if btrim(coalesce(p_params->>'field', '')) = '' then return 'Give the name of the custom field.'; end if;
  elsif p_kind = 'tag_present' then
    if not exists (select 1 from flow.tag_definitions where code = p_params->>'tag') then return 'That tag does not exist.'; end if;
  else return 'Unknown kind of condition.';
  end if;
  return null;
end $$;

create or replace function flow.rr_save_tag_rule(p_id uuid, p_tag_code text, p_tag_label text, p_name text, p_kind text, p_params jsonb, p_active boolean, p_actor text, p_reason text)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_err text; v_id uuid; v_before jsonb; v_after jsonb;
begin
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'error', 'Give a reason (at least 5 characters).'); end if;
  if p_kind not in ('custom_field_filled', 'decorations_over', 'units_over') then return jsonb_build_object('ok', false, 'error', 'Unknown kind of condition for a tag.'); end if;
  v_err := flow.rr_check_params(p_kind, p_params);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  if coalesce(btrim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'Give the rule a name.'); end if;
  if p_tag_code is null or p_tag_code !~ '^[a-z][a-z0-9_]{1,40}$' then return jsonb_build_object('ok', false, 'error', 'The tag code must be lower-case letters, numbers and underscores.'); end if;
  if not exists (select 1 from flow.tag_definitions where code = p_tag_code) then
    if coalesce(btrim(p_tag_label), '') = '' then return jsonb_build_object('ok', false, 'error', 'This is a new tag: give it a label.'); end if;
    insert into flow.tag_definitions (code, label) values (p_tag_code, btrim(p_tag_label));
  end if;
  if p_id is not null then
    select to_jsonb(t) into v_before from flow.tag_rules t where id = p_id;
    if v_before is null then return jsonb_build_object('ok', false, 'error', 'Unknown rule.'); end if;
    update flow.tag_rules set tag_code = p_tag_code, name = btrim(p_name), kind = p_kind, params = p_params, is_active = coalesce(p_active, true) where id = p_id returning id into v_id;
  else
    insert into flow.tag_rules (tag_code, name, kind, params, is_active, created_by) values (p_tag_code, btrim(p_name), p_kind, p_params, coalesce(p_active, true), p_actor) returning id into v_id;
  end if;
  select to_jsonb(t) into v_after from flow.tag_rules t where id = v_id;
  insert into flow.audit_log (actor, action, entity, entity_id, before, after, reason) values (p_actor, case when p_id is null then 'tag_rule_added' else 'tag_rule_changed' end, 'tag_rules', v_id::text, v_before, v_after, btrim(p_reason));
  perform flow.rules_evaluate_all('rule change');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function flow.rr_save_routing_rule(p_id uuid, p_position int, p_name text, p_kind text, p_params jsonb, p_scope text, p_producer uuid, p_active boolean, p_actor text, p_reason text)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_err text; v_id uuid; v_before jsonb; v_after jsonb;
begin
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'error', 'Give a reason (at least 5 characters).'); end if;
  v_err := flow.rr_check_params(p_kind, p_params);
  if v_err is not null then return jsonb_build_object('ok', false, 'error', v_err); end if;
  if coalesce(btrim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'Give the rule a name.'); end if;
  if p_position is null or p_position < 0 then return jsonb_build_object('ok', false, 'error', 'Give the rule a position (0 or more; lower runs first).'); end if;
  if p_scope not in ('third_party', 'in_house') then return jsonb_build_object('ok', false, 'error', 'The result must be third party or in house.'); end if;
  if p_producer is not null and not exists (select 1 from flow.producers where id = p_producer and is_active) then return jsonb_build_object('ok', false, 'error', 'That producer is not active.'); end if;
  if p_scope = 'in_house' and p_producer is not null then return jsonb_build_object('ok', false, 'error', 'An in-house result has no producer.'); end if;
  if p_id is not null then
    select to_jsonb(t) into v_before from flow.routing_rules t where id = p_id;
    if v_before is null then return jsonb_build_object('ok', false, 'error', 'Unknown rule.'); end if;
    update flow.routing_rules set position = p_position, name = btrim(p_name), kind = p_kind, params = p_params, outcome_scope = p_scope, producer_id = p_producer, is_active = coalesce(p_active, true) where id = p_id returning id into v_id;
  else
    insert into flow.routing_rules (position, name, kind, params, outcome_scope, producer_id, is_active, created_by) values (p_position, btrim(p_name), p_kind, p_params, p_scope, p_producer, coalesce(p_active, true), p_actor) returning id into v_id;
  end if;
  select to_jsonb(t) into v_after from flow.routing_rules t where id = v_id;
  insert into flow.audit_log (actor, action, entity, entity_id, before, after, reason) values (p_actor, case when p_id is null then 'routing_rule_added' else 'routing_rule_changed' end, 'routing_rules', v_id::text, v_before, v_after, btrim(p_reason));
  perform flow.rules_evaluate_all('rule change');
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 9. Wrappers (n8n, service role only) and read-only views for staff ------------------------------------------------------------
create or replace function public.flow_order_facts_ingest(p_items jsonb, p_triggered_by text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.order_facts_ingest(p_items, p_triggered_by) $$;
create or replace function public.flow_rr_save_tag_rule(p_id uuid, p_tag_code text, p_tag_label text, p_name text, p_kind text, p_params jsonb, p_active boolean, p_actor text, p_reason text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.rr_save_tag_rule(p_id, p_tag_code, p_tag_label, p_name, p_kind, p_params, p_active, p_actor, p_reason) $$;
create or replace function public.flow_rr_save_routing_rule(p_id uuid, p_position int, p_name text, p_kind text, p_params jsonb, p_scope text, p_producer uuid, p_active boolean, p_actor text, p_reason text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.rr_save_routing_rule(p_id, p_position, p_name, p_kind, p_params, p_scope, p_producer, p_active, p_actor, p_reason) $$;

create or replace view public.ui_order_tags with (security_invoker = true) as
  select t.order_id, o.order_ref, t.tag_code, d.label, t.quantity, t.evidence, t.set_at from flow.order_tags t join flow.orders o on o.id = t.order_id join flow.tag_definitions d on d.code = t.tag_code;
create or replace view public.ui_tag_rules with (security_invoker = true) as
  select r.id, r.tag_code, d.label as tag_label, r.name, r.kind, r.params, r.is_active, r.created_at, r.created_by from flow.tag_rules r join flow.tag_definitions d on d.code = r.tag_code;
create or replace view public.ui_routing_rules with (security_invoker = true) as
  select r.id, r.position, r.name, r.kind, r.params, r.outcome_scope, r.producer_id, p.name as producer_name, r.is_active, r.created_at, r.created_by, (select mode from flow.routing_settings) as mode
  from flow.routing_rules r left join flow.producers p on p.id = r.producer_id;
create or replace view public.ui_routing_decisions with (security_invoker = true) as
  select d.order_id, o.order_ref, o.customer_name, o.due_date, d.outcome, d.rule_name, d.rule_scope as would_scope, d.producer_id as would_producer_id, p.name as would_producer_name,
         d.current_scope, d.current_source, d.detail, d.evaluated_at, f.decoration_count
  from flow.routing_decisions d join flow.orders o on o.id = d.order_id left join flow.producers p on p.id = d.producer_id left join flow.order_facts f on f.order_id = d.order_id;

alter table flow.order_facts enable row level security;
alter table flow.tag_definitions enable row level security;
alter table flow.tag_rules enable row level security;
alter table flow.order_tags enable row level security;
alter table flow.routing_settings enable row level security;
alter table flow.routing_rules enable row level security;
alter table flow.routing_decisions enable row level security;
create policy order_facts_read on flow.order_facts for select to authenticated using (flow.is_member());
create policy tag_definitions_read on flow.tag_definitions for select to authenticated using (flow.is_member());
create policy tag_rules_read on flow.tag_rules for select to authenticated using (flow.is_member());
create policy order_tags_read on flow.order_tags for select to authenticated using (flow.is_member());
create policy routing_settings_read on flow.routing_settings for select to authenticated using (flow.is_member());
create policy routing_rules_read on flow.routing_rules for select to authenticated using (flow.is_member());
create policy routing_decisions_read on flow.routing_decisions for select to authenticated using (flow.is_member());

do $$
declare f text;
begin
  -- logged-in people may read (RLS limits that to team members) but never write these tables directly
  revoke all on flow.order_facts, flow.tag_definitions, flow.tag_rules, flow.order_tags, flow.routing_settings, flow.routing_rules, flow.routing_decisions from public, anon, authenticated;
  grant select on flow.order_facts, flow.tag_definitions, flow.tag_rules, flow.order_tags, flow.routing_settings, flow.routing_rules, flow.routing_decisions to authenticated;
  revoke all on public.ui_order_tags, public.ui_tag_rules, public.ui_routing_rules, public.ui_routing_decisions from public, anon;
  grant select on public.ui_order_tags, public.ui_tag_rules, public.ui_routing_rules, public.ui_routing_decisions to authenticated;
  -- every function here is private; only the n8n wrappers are open, and only to the service role
  foreach f in array array['flow.rule_check(text,jsonb,uuid)', 'flow.rules_evaluate_order(uuid)', 'flow.rules_evaluate_all(text)', 'flow.facts_clean(jsonb)', 'flow.order_facts_ingest(jsonb,text)',
                           'flow.rr_check_params(text,jsonb)', 'flow.rr_save_tag_rule(uuid,text,text,text,text,jsonb,boolean,text,text)',
                           'flow.rr_save_routing_rule(uuid,int,text,text,jsonb,text,uuid,boolean,text,text)',
                           'public.flow_order_facts_ingest(jsonb,text)', 'public.flow_rr_save_tag_rule(uuid,text,text,text,text,jsonb,boolean,text,text)',
                           'public.flow_rr_save_routing_rule(uuid,int,text,text,jsonb,text,uuid,boolean,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_order_facts_ingest(jsonb,text), public.flow_rr_save_tag_rule(uuid,text,text,text,text,jsonb,boolean,text,text),
    public.flow_rr_save_routing_rule(uuid,int,text,text,jsonb,text,uuid,boolean,text,text) to service_role;
end $$;
