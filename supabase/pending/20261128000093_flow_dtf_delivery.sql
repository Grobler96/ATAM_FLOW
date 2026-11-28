-- 28 Nov 2026: a delivery choice when raising a DTF order (NOT APPLIED yet).
-- Daniel's suggestion: when raising a DTF order we need to be able to ask Super Print for next day delivery (before 12) when we need the prints quickly.
--   1. flow.dtf_batches.delivery: 'standard' (default) or 'next_day_pre12'.
--   2. flow.dtf_build_order / public.flow_dtf_build_order take a fifth argument p_delivery (default null = standard). The old four-argument versions are removed so the
--      call is never ambiguous. For next day the email carries one extra line in bold: "Please can we have this Tomorrow on Pre 12 next day delivery." (plain text copy too).
--   3. public.ui_dtf_batches also shows comm_id and delivery, so the DTF orders page can approve its own email.
-- The live function is patched in place from its current text; it raises if a piece it expects is missing.
alter table flow.dtf_batches add column if not exists delivery text not null default 'standard';
alter table flow.dtf_batches drop constraint if exists dtf_batches_delivery_chk;
alter table flow.dtf_batches add constraint dtf_batches_delivery_chk check (delivery in ('standard', 'next_day_pre12'));

do $$
declare v text; v_new text;
  procedure_text constant text := 'Please can we have this Tomorrow on Pre 12 next day delivery.';
begin
  v := pg_get_functiondef('flow.dtf_build_order(uuid[],jsonb,text,text)'::regprocedure);
  v_new := v;
  -- header: a fifth argument
  v_new := replace(v_new, 'p_note text DEFAULT NULL::text)', 'p_note text DEFAULT NULL::text, p_delivery text DEFAULT NULL::text)');
  if v_new = v then raise exception 'patch anchor missing: header'; end if;
  -- check the choice first
  v := v_new;
  v_new := replace(v_new, E'begin\n  v_plan := flow.dtf_plan(p_order_ids);', E'begin\n  if coalesce(p_delivery, \'standard\') not in (\'standard\', \'next_day_pre12\') then return jsonb_build_object(\'ok\', false, \'error\', \'Delivery must be standard or next day before 12.\'); end if;\n  v_plan := flow.dtf_plan(p_order_ids);');
  if v_new = v then raise exception 'patch anchor missing: begin'; end if;
  -- store it
  v := v_new;
  v_new := replace(v_new, 'insert into flow.dtf_batches (batch_ref, supplier_id, note, created_by) values (v_ref, v_sup.id, nullif(btrim(coalesce(p_note, '''')), ''''), p_actor)',
                          'insert into flow.dtf_batches (batch_ref, supplier_id, note, created_by, delivery) values (v_ref, v_sup.id, nullif(btrim(coalesce(p_note, '''')), ''''), p_actor, coalesce(nullif(p_delivery, ''''), ''standard''))');
  if v_new = v then raise exception 'patch anchor missing: insert'; end if;
  -- plain text line, straight after the opening paragraph
  v := v_new;
  v_new := replace(v_new, 'v_text := ''Hi Supa print,'' || E''\n\n'' || ''Please could we order the following DTF prints ('' || v_ref || ''). Quantities are the number of prints needed for each design.'' || E''\n\n'' || v_text',
    'v_text := ''Hi Supa print,'' || E''\n\n'' || ''Please could we order the following DTF prints ('' || v_ref || ''). Quantities are the number of prints needed for each design.'' || E''\n\n'' || case when p_delivery = ''next_day_pre12'' then ''' || procedure_text || ''' || E''\n\n'' else '''' end || v_text');
  if v_new = v then raise exception 'patch anchor missing: text'; end if;
  -- bold HTML line
  v := v_new;
  v_new := replace(v_new, 'The quantity is the number of prints needed for each design.</p>''', 'The quantity is the number of prints needed for each design.</p>'' || case when p_delivery = ''next_day_pre12'' then ''<p><b>' || procedure_text || '</b></p>'' else '''' end');
  if v_new = v then raise exception 'patch anchor missing: html'; end if;
  execute v_new;
end $$;

drop function if exists flow.dtf_build_order(uuid[], jsonb, text, text);
drop function if exists public.flow_dtf_build_order(uuid[], jsonb, text, text);
create or replace function public.flow_dtf_build_order(p_order_ids uuid[], p_links jsonb, p_actor text, p_note text default null, p_delivery text default null) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.dtf_build_order(p_order_ids, p_links, p_actor, p_note, p_delivery) $$;
revoke all on function flow.dtf_build_order(uuid[], jsonb, text, text, text), public.flow_dtf_build_order(uuid[], jsonb, text, text, text) from public, anon, authenticated;
grant execute on function public.flow_dtf_build_order(uuid[], jsonb, text, text, text) to service_role;

create or replace view public.ui_dtf_batches with (security_invoker = true) as
  select b.id, b.batch_ref, b.status, s.name as supplier_name, (coalesce(btrim(s.email), '') <> '') as supplier_has_email, b.note, b.created_by, b.created_at, b.ordered_at, b.received_at,
         c.comm_ref, c.status as comm_status,
         (select count(*) from flow.dtf_items i where i.batch_id = b.id)::int as placements, (select coalesce(sum(i.qty), 0) from flow.dtf_items i where i.batch_id = b.id)::int as prints,
         (select count(*) from flow.dtf_items i where i.batch_id = b.id and i.status = 'done')::int as received,
         b.comm_id, b.delivery
  from flow.dtf_batches b join flow.suppliers s on s.id = b.supplier_id left join flow.communications c on c.id = b.comm_id;
grant select on public.ui_dtf_batches to authenticated;
