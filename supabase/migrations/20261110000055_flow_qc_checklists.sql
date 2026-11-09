-- Real QC checklists: the mechanism only. The starter items are marked as placeholders and nobody can
-- "confirm" the checklist until they have been replaced by the business's own standards. Checks are now
-- validated against the checklist that applies (method + stage): required items must be answered, a failed
-- item needs a note, and a failed "photo needed" item needs evidence. Results keep a snapshot of the item.

alter table flow.qc_criteria
  add column if not exists gates          text[],                          -- null = every stage
  add column if not exists is_required    boolean not null default true,
  add column if not exists is_critical    boolean not null default false,  -- a failure here is serious: shown in red, always reworked
  add column if not exists needs_photo    boolean not null default false,  -- a failure must come with a photo or link
  add column if not exists is_placeholder boolean not null default false,
  add column if not exists version        int not null default 1,
  add column if not exists updated_by     text,
  add column if not exists updated_at     timestamptz;

-- The starter items were never the business's own standards: mark them, and stop them blocking a check until replaced.
update flow.qc_criteria set is_placeholder = true, is_required = false where created_by = 'seed (placeholder)' and is_placeholder = false and version = 1 and updated_at is null;

insert into flow.flow_settings (key, value, description) values
 ('qc.checklist', '{}'::jsonb, 'Quality checklist sign-off: confirmed_at, confirmed_by and a note, set by a manager or admin once the placeholder items are replaced by real standards.')
on conflict (key) do nothing;

create or replace function flow.qc_checklist_for(p_order uuid, p_gate text, p_line uuid) returns setof flow.qc_criteria
language sql stable security definer set search_path = flow, public as $$
  select c.* from flow.qc_criteria c
  where c.is_active and (c.gates is null or p_gate = any (c.gates))
    and (c.method_code is null or c.method_code in (
      select m from flow.order_lines l, unnest(l.decoration_methods) m where l.order_id = p_order and (p_line is null or l.id = p_line)))
  order by c.sort_order, c.name
$$;

-- Returns null when the answers are acceptable, otherwise a plain-English reason.
create or replace function flow.qc_check_results(p_order uuid, p_gate text, p_line uuid, p_results jsonb, p_evidence jsonb, p_notes text) returns text
language plpgsql stable security definer set search_path = flow, public as $$
declare r jsonb := case when jsonb_typeof(p_results) = 'array' then p_results else '[]'::jsonb end; e record; v_has_note boolean := length(btrim(coalesce(p_notes, ''))) > 0;
  v_has_ev boolean := jsonb_typeof(p_evidence) = 'array' and jsonb_array_length(p_evidence) > 0; v_missing text;
begin
  if exists (select 1 from jsonb_array_elements(r) x where (x->>'criterion_id') is null or (x->>'passed') is null) then return 'Each checklist answer needs an item and a pass or fail.'; end if;
  if exists (select 1 from jsonb_array_elements(r) x where not exists (select 1 from flow.qc_criteria c where c.id::text = x->>'criterion_id')) then return 'A checklist item in this check no longer exists. Reload the page and try again.'; end if;
  select string_agg(c.name, ', ' order by c.sort_order) into v_missing from flow.qc_checklist_for(p_order, p_gate, p_line) c
   where c.is_required and not exists (select 1 from jsonb_array_elements(r) x where x->>'criterion_id' = c.id::text);
  if v_missing is not null then return 'Answer every required checklist item. Still to do: ' || v_missing || '.'; end if;
  for e in select c.name, c.needs_photo, (x->>'note') as note, (x->'evidence') as ev
           from jsonb_array_elements(r) x join flow.qc_criteria c on c.id::text = x->>'criterion_id' where (x->>'passed')::boolean is false loop
    if length(btrim(coalesce(e.note, ''))) = 0 and not v_has_note then return format('"%s" failed: say what is wrong in the item note or the check notes.', e.name); end if;
    if e.needs_photo and not v_has_ev and not coalesce(jsonb_typeof(e.ev) = 'array' and jsonb_array_length(e.ev) > 0, false) then return format('"%s" failed: add a photo or a link as evidence.', e.name); end if;
  end loop;
  return null;
end $$;

-- Stores the answers with a snapshot of each item, so later edits to the checklist never rewrite history.
create or replace function flow.qc_enrich_results(p_results jsonb) returns jsonb
language sql stable security definer set search_path = flow, public as $$
  select case when jsonb_typeof(p_results) <> 'array' then '[]'::jsonb else coalesce((
    select jsonb_agg(x || jsonb_build_object('name', c.name, 'critical', c.is_critical, 'required', c.is_required, 'version', c.version) order by ord)
    from jsonb_array_elements(p_results) with ordinality t(x, ord) left join flow.qc_criteria c on c.id::text = x->>'criterion_id'), '[]'::jsonb) end
$$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.qc_record_check(uuid,uuid,text,int,int,jsonb,text,text,text,jsonb,uuid,text,int,text)'::regprocedure) into v_def;
  if v_def not like '%qc_check_results%' then
    v_def := replace(v_def, 'v_failed int := coalesce(p_failed, 0);', 'v_failed int := coalesce(p_failed, 0); v_chk text;');
    v_def := replace(v_def, '''A checklist item failed, so at least one unit must be marked as failed.''); end if;',
      '''A checklist item failed, so at least one unit must be marked as failed.''); end if;
  v_chk := flow.qc_check_results(o.id, v_gate, p_line, p_results, p_evidence, p_notes);
  if v_chk is not null then return jsonb_build_object(''ok'', false, ''error'', v_chk); end if;');
    v_def := replace(v_def, 'coalesce(p_results, ''[]''::jsonb)', 'flow.qc_enrich_results(p_results)');
    if v_def not like '%qc_check_results%' or v_def not like '%v_chk text%' or v_def not like '%qc_enrich_results%' then raise exception 'qc_record_check anchors not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- Edit or add an item. Editing bumps the version and clears the placeholder flag; items are switched off, never removed.
create or replace function flow.qc_criterion_save(p jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_method text := nullif(p->>'method', ''); v_name text := btrim(coalesce(p->>'name', '')); v_gates text[];
  v_valid text[] := array['pre_production', 'in_line', 'final', 'producer_return', 'recheck'];
begin
  if length(v_name) < 3 then return jsonb_build_object('ok', false, 'error', 'Give the checklist item a name.'); end if;
  if v_method is not null and not exists (select 1 from flow.production_methods where code = v_method) then return jsonb_build_object('ok', false, 'error', 'Unknown decoration method.'); end if;
  if jsonb_typeof(p->'gates') = 'array' and jsonb_array_length(p->'gates') > 0 then
    select array_agg(g) into v_gates from jsonb_array_elements_text(p->'gates') g;
    if exists (select 1 from unnest(v_gates) g where g <> all (v_valid)) then return jsonb_build_object('ok', false, 'error', 'Unknown stage.'); end if;
  end if;
  if v_id is null then
    insert into flow.qc_criteria (method_code, name, description, sort_order, created_by, gates, is_required, is_critical, needs_photo, updated_by, updated_at)
    values (v_method, v_name, nullif(btrim(coalesce(p->>'description', '')), ''), coalesce(nullif(p->>'sort_order', '')::int, (select coalesce(max(sort_order), 0) + 10 from flow.qc_criteria)), p_actor, v_gates,
            coalesce((p->>'required')::boolean, true), coalesce((p->>'critical')::boolean, false), coalesce((p->>'needs_photo')::boolean, false), p_actor, now())
    on conflict do nothing;
    if not found then return jsonb_build_object('ok', false, 'error', 'That checklist item already exists.'); end if;
  else
    update flow.qc_criteria set name = v_name, description = nullif(btrim(coalesce(p->>'description', '')), ''), gates = v_gates,
      sort_order = coalesce(nullif(p->>'sort_order', '')::int, sort_order), is_required = coalesce((p->>'required')::boolean, is_required), is_critical = coalesce((p->>'critical')::boolean, is_critical),
      needs_photo = coalesce((p->>'needs_photo')::boolean, needs_photo), is_active = coalesce((p->>'active')::boolean, is_active), is_placeholder = false, version = version + 1, updated_by = p_actor, updated_at = now()
     where id = v_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'Checklist item not found.'); end if;
  end if;
  perform flow.wh_audit(p_actor, 'qc_criterion_save', 'qc_criteria', coalesce(v_method, 'all'), null, jsonb_build_object('name', v_name, 'gates', v_gates, 'required', p->'required', 'critical', p->'critical', 'needs_photo', p->'needs_photo', 'active', p->'active'), null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.qc_confirm_checklist(p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_left int;
begin
  select count(*) into v_left from flow.qc_criteria where is_active and is_placeholder;
  if v_left > 0 then return jsonb_build_object('ok', false, 'error', format('%s starter item(s) are still in use. Edit each one to match your real standard, or switch it off, then confirm.', v_left)); end if;
  if not exists (select 1 from flow.qc_criteria where is_active) then return jsonb_build_object('ok', false, 'error', 'There are no checklist items in use. Add your real ones first.'); end if;
  insert into flow.flow_settings (key, value, description) values ('qc.checklist', jsonb_build_object('confirmed_at', now(), 'confirmed_by', p_actor, 'note', nullif(btrim(coalesce(p_note, '')), '')), 'Quality checklist sign-off.')
  on conflict (key) do update set value = excluded.value;
  perform flow.wh_audit(p_actor, 'qc_checklist_confirm', 'qc_criteria', 'checklist', null, jsonb_build_object('items', (select count(*) from flow.qc_criteria where is_active)), p_note);
  return jsonb_build_object('ok', true);
end $$;

create or replace view public.ui_qc_criteria with (security_invoker = true) as
  select id, method_code, name, description, sort_order, is_active, gates, is_required, is_critical, needs_photo, is_placeholder, version, updated_by, updated_at from flow.qc_criteria;

create or replace view public.ui_qc_standards with (security_invoker = true) as
  select (select count(*) from flow.qc_criteria where is_active) as active_items,
         (select count(*) from flow.qc_criteria where is_active and is_placeholder) as placeholder_items,
         nullif(flow.setting('qc.checklist')->>'confirmed_at', '')::timestamptz as confirmed_at,
         flow.setting('qc.checklist')->>'confirmed_by' as confirmed_by,
         (nullif(flow.setting('qc.checklist')->>'confirmed_at', '') is not null
           and not exists (select 1 from flow.qc_criteria where is_active and is_placeholder)
           and not exists (select 1 from flow.qc_criteria where updated_at > nullif(flow.setting('qc.checklist')->>'confirmed_at', '')::timestamptz)) as is_confirmed;

insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('qc_checklist_unconfirmed', 'Quality checks are being done against an unconfirmed checklist', 'quality', 'medium', '{}', 'manager', 'Replace the starter checklist items with your real standards on the Quality page, then confirm the checklist.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_qc_checklist() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select case when not coalesce((select is_confirmed from public.ui_qc_standards), false)
              and exists (select 1 from flow.qc_checks where checked_at > now() - interval '14 days')
    then jsonb_build_array(jsonb_build_object('type', 'qc_checklist_unconfirmed', 'key', 'qc_checklist',
      'description', format('%s quality check(s) were recorded in the last 14 days while the checklist is not confirmed (%s starter item(s) still in use)', (select count(*) from flow.qc_checks where checked_at > now() - interval '14 days'), (select placeholder_items from public.ui_qc_standards)),
      'links', '[]'::jsonb, 'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'internal_process', 'detected_by', 'automation', 'source_type', 'qc_checklist', 'source_id', 'checklist')))
    else '[]'::jsonb end
$$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%''qc_checklist''%' then
    v_def := replace(v_def, '''stocktakes''] loop', '''stocktakes'',''qc_checklist''] loop');
    if v_def not like '%''qc_checklist''%' then raise exception 'detector list anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

create or replace function public.flow_qc_criterion_save(p jsonb, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.qc_criterion_save(p, p_actor) $$;
create or replace function public.flow_qc_confirm_checklist(p_note text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.qc_confirm_checklist(p_note, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_qc_criterion_save(jsonb,text)', 'public.flow_qc_confirm_checklist(text,text)', 'flow.qc_criterion_save(jsonb,text)', 'flow.qc_confirm_checklist(text,text)',
                           'flow.qc_checklist_for(uuid,text,uuid)', 'flow.qc_check_results(uuid,text,uuid,jsonb,jsonb,text)', 'flow.qc_enrich_results(jsonb)', 'flow.exc_detect_qc_checklist()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_qc_criterion_save(jsonb, text), public.flow_qc_confirm_checklist(text, text) to service_role;
  revoke all on public.ui_qc_criteria, public.ui_qc_standards from public, anon;
  grant select on public.ui_qc_criteria, public.ui_qc_standards to authenticated;
end $$;

-- Fix for migration 54: its detector used root-cause values the exceptions table does not allow
-- ('stock', 'process'), so a stale stock-take would have made the detector error instead of raising an exception.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exc_detect_stocktakes()'::regprocedure) into v_def;
  if v_def like '%''root_cause'', ''stock''%' or v_def like '%''root_cause'', ''process''%' then
    v_def := replace(replace(v_def, '''root_cause'', ''stock''', '''root_cause'', ''internal_process'''), '''root_cause'', ''process''', '''root_cause'', ''internal_process''');
    execute v_def;
  end if;
end $$;
