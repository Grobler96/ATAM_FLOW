-- Decorators report spoiled units from the portal.
-- A report is a SUGGESTED waste record (it counts for nothing until a person confirms it on the Waste page), it is logged on the job,
-- and it is posted into the job's message thread so the team sees it (an unanswered message raises an exception after 24 hours).
-- The decorator can only report on their own job, only on a line of that job, only once the goods are with them, and never more units in total
-- than were sent on that line. A photo must sit in their own folder for that job.

create or replace function public.portal_report_spoilage(p_code text, p_item uuid, p_qty int, p_what text, p_note text, p_evidence text default null)
returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements; it flow.tp_movement_items; o flow.orders; who text; v_prior int; v_ref text; v_label text; v_reason text; v_cost numeric;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id); who := 'producer:' || coalesce(pu.name, pu.email);
  if m.portal_declined_at is not null then return jsonb_build_object('ok', false, 'error', 'You declined this job. Message us if that has changed.'); end if;
  if m.status not in ('received_by_producer', 'in_production', 'production_complete') then
    return jsonb_build_object('ok', false, 'error', 'You can report spoiled units once you have checked the goods in and until you send them back. Damage found on arrival goes in the check-in.');
  end if;
  select * into it from flow.tp_movement_items where id = p_item and movement_id = m.id;
  if it.id is null then return jsonb_build_object('ok', false, 'error', 'Choose a line from this job.'); end if;
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('ok', false, 'error', 'Enter how many units were spoiled.'); end if;
  v_label := case p_what when 'stained' then 'stained or marked' when 'misprint' then 'misprint' when 'machine_fault' then 'machine fault' when 'damaged' then 'damaged during work'
                         when 'wrong_item' then 'wrong item used' when 'other' then 'other' end;
  if v_label is null then return jsonb_build_object('ok', false, 'error', 'Choose what happened.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 or length(p_note) > 1000 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Tell us what happened (at least a few words).'); end if;
  select coalesce(sum(qty), 0) into v_prior from flow.waste_events where source_key like 'portal:' || it.id::text || ':%' and status <> 'rejected';
  if v_prior + p_qty > it.qty_sent then
    return jsonb_build_object('ok', false, 'error', format('That is more than was sent on this line. %s sent, %s already reported as spoiled.', it.qty_sent, v_prior));
  end if;
  if p_evidence is not null and p_evidence not like (pu.producer_id::text || '/' || m.movement_code || '/%') then
    return jsonb_build_object('ok', false, 'error', 'That file is not stored in your folder for this job.');
  end if;
  select * into o from flow.orders where id = it.order_id;
  v_cost := flow.waste_cost(it.sku);
  v_ref := 'WST-' || to_char(now(), 'YYMMDD') || '-' || lpad(nextval('flow.waste_seq')::text, 4, '0');
  v_reason := 'Reported by the decorator on ' || m.movement_code || ' (' || v_label || '): ' || btrim(p_note);
  insert into flow.waste_events (waste_ref, stage, cause_code, party, qty, sku, unit_cost, order_id, order_ref, producer_id, movement_id, source, source_key, status, reason, evidence_path, recorded_by)
  values (v_ref, 'decorator', 'decorator_spoilage', 'decorator', p_qty, it.sku, v_cost, it.order_id, o.order_ref, m.producer_id, m.id, 'manual', 'portal:' || it.id::text || ':' || gen_random_uuid()::text,
          'suggested', v_reason, p_evidence, who);
  if p_evidence is not null then
    insert into flow.tp_evidence (movement_id, item_id, storage_path, kind, caption, uploaded_by) values (m.id, it.id, p_evidence, 'issue', 'Spoilage: ' || v_label, coalesce(pu.name, pu.email));
  end if;
  insert into flow.tp_messages (movement_id, side, author, body)
  values (m.id, 'producer', coalesce(pu.name, pu.email), format('Reported %s spoiled unit(s) of %s (%s). %s', p_qty, coalesce(it.sku, 'a line'), v_label, btrim(p_note)));
  perform flow.tp_log(m.id, 'producer_spoilage', who, jsonb_build_object('waste_ref', v_ref, 'qty', p_qty, 'sku', it.sku, 'what', p_what), btrim(p_note));
  perform flow.wh_audit(who, 'portal_report_spoilage', 'movement', m.movement_code, null, jsonb_build_object('waste_ref', v_ref, 'qty', p_qty, 'sku', it.sku), btrim(p_note));
  return jsonb_build_object('ok', true, 'waste_ref', v_ref);
end $$;

-- What this decorator has reported on one job. Own jobs only; no costs and no internal notes are returned.
create or replace function public.portal_spoilage(p_code text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id);
  return jsonb_build_object('ok', true, 'reports', coalesce((
    select jsonb_agg(jsonb_build_object('waste_ref', w.waste_ref, 'sku', w.sku, 'qty', w.qty, 'reported_at', w.created_at,
             'state', case w.status when 'suggested' then 'With ATAM to review' when 'pending_approval' then 'With ATAM to review' when 'approved' then 'Recorded by ATAM' else 'Reviewed by ATAM' end,
             'note', w.reason) order by w.created_at desc)
    from flow.waste_events w where w.movement_id = m.id and w.source_key like 'portal:%'), '[]'::jsonb));
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.portal_report_spoilage(text,uuid,int,text,text,text)', 'public.portal_spoilage(text)']
  loop execute format('revoke all on function %s from public, anon', f); execute format('grant execute on function %s to authenticated', f); end loop;
end $$;
