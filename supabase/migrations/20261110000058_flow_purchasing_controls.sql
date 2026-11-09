-- Purchasing controls: PO approval rules, supplier invoice matching, scheduled (draft-only) chasing.
-- Values are PLACEHOLDERS in flow_settings 'purchasing.rules' until the business sets real ones. Nothing here sends email:
-- chases are drafts that wait in the review queue, and scheduled chasing is OFF until switched on.
insert into flow.flow_settings (key, value, description) values
 ('purchasing.rules', '{"approve_over_value": 500, "no_self_approval": true, "invoice_tolerance_pct": 2, "invoice_tolerance_value": 5, "chase_enabled": false, "chase_min_days_late": 2, "chase_repeat_days": 3}'::jsonb,
  'PLACEHOLDERS. PO value above which only an admin may approve; whether the person who created a PO may approve it; how far an invoice may differ from what was received (percent or pounds, whichever is larger); and whether scheduled chasing drafts are on, how late a PO must be, and days between chases.')
on conflict (key) do nothing;

create or replace function flow.purchasing_rules() returns jsonb language sql stable set search_path = flow, public as $$
  select '{"approve_over_value": 500, "no_self_approval": true, "invoice_tolerance_pct": 2, "invoice_tolerance_value": 5, "chase_enabled": false, "chase_min_days_late": 2, "chase_repeat_days": 3}'::jsonb || coalesce(flow.setting('purchasing.rules'), '{}'::jsonb)
$$;

-- 1. Approval rules -----------------------------------------------------------------------------------------------
create or replace function flow.po_approve_checked(p_po uuid, p_actor text, p_role text, p_reason text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders; r jsonb := flow.purchasing_rules(); v_total numeric; v_self boolean; v_over boolean; v_res jsonb;
begin
  select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
  if po.id is null then return jsonb_build_object('ok', false, 'error', 'Purchase order not found.'); end if;
  select coalesce(po.total_cost, sum(line_total), 0) into v_total from flow.po_lines where po_id = p_po;
  v_total := coalesce(po.total_cost, v_total, 0);
  v_over := v_total > (r->>'approve_over_value')::numeric;
  v_self := coalesce((r->>'no_self_approval')::boolean, true) and po.created_by is not null and po.created_by = p_actor;
  if v_over and p_role <> 'admin' then return jsonb_build_object('ok', false, 'error', format('This PO is worth £%s. Anything over £%s needs an admin to approve it.', round(v_total, 2), (r->>'approve_over_value'))); end if;
  if v_self and (p_role <> 'admin' or length(btrim(coalesce(p_reason, ''))) < 3) then
    return jsonb_build_object('ok', false, 'needs_reason', p_role = 'admin', 'error', 'You created this PO, so someone else should approve it. An admin can approve their own PO by giving a reason.');
  end if;
  v_res := flow.approve_purchase_order(p_po, p_actor);
  if (v_res->>'ok')::boolean and v_self then perform flow.wh_audit(p_actor, 'po_self_approval', 'purchase_order', coalesce(po.af_po_ref, po.po_number), null, jsonb_build_object('total', v_total), p_reason); end if;
  return v_res;
end $$;

-- 2. Invoice matching ---------------------------------------------------------------------------------------------
create table flow.po_invoices (
  id            uuid primary key default gen_random_uuid(),
  po_id         uuid not null references flow.purchase_orders(id),
  invoice_ref   text not null,
  invoice_date  date,
  net_total     numeric(12,2) not null check (net_total >= 0),
  vat_total     numeric(12,2),
  note          text,
  resolution    text check (resolution in ('accepted', 'disputed')),
  resolution_reason text,
  resolved_by   text,
  resolved_at   timestamptz,
  created_by    text,
  created_at    timestamptz not null default now(),
  unique (po_id, invoice_ref)
);
alter table flow.po_invoices enable row level security;
create policy po_invoices_read on flow.po_invoices for select to authenticated using (flow.is_member());

-- What we expected to pay: units actually delivered at the PO unit cost, plus the PO's delivery charge.
create or replace view flow.v_po_invoice_match with (security_invoker = true) as
with exp as (
  select p.id as po_id, coalesce(sum(greatest(l.qty_received, l.qty_received_af) * l.unit_cost), 0) as received_value, coalesce(sum(l.qty_expected * l.unit_cost), 0) as ordered_value,
         coalesce(sum(greatest(l.qty_received, l.qty_received_af)), 0) as units_received, coalesce(sum(l.qty_expected), 0) as units_ordered
  from flow.purchase_orders p left join flow.po_lines l on l.po_id = p.id group by p.id)
select i.id, i.po_id, coalesce(p.af_po_ref, p.po_number) as po_ref, p.supplier, i.invoice_ref, i.invoice_date, i.net_total, i.vat_total, i.note, i.resolution, i.resolution_reason, i.resolved_by, i.resolved_at, i.created_by, i.created_at,
       e.ordered_value, e.received_value, coalesce(p.delivery_cost, 0) as delivery_cost, (e.received_value + coalesce(p.delivery_cost, 0)) as expected_net, e.units_ordered, e.units_received,
       round(i.net_total - (e.received_value + coalesce(p.delivery_cost, 0)), 2) as variance,
       case when e.units_received = 0 then 'awaiting_goods'
            when abs(i.net_total - (e.received_value + coalesce(p.delivery_cost, 0))) <= greatest((flow.purchasing_rules()->>'invoice_tolerance_value')::numeric, (e.received_value + coalesce(p.delivery_cost, 0)) * (flow.purchasing_rules()->>'invoice_tolerance_pct')::numeric / 100) then 'matched'
            when i.net_total > e.received_value + coalesce(p.delivery_cost, 0) then 'over_billed' else 'under_billed' end as match_status
from flow.po_invoices i join flow.purchase_orders p on p.id = i.po_id join exp e on e.po_id = i.po_id;

create or replace function flow.po_invoice_record(p_po uuid, p_ref text, p_date date, p_net numeric, p_vat numeric, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders; v_id uuid; v_m record;
begin
  select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
  if po.id is null then return jsonb_build_object('ok', false, 'error', 'Purchase order not found.'); end if;
  if po.po_status in ('draft', 'cancelled') then return jsonb_build_object('ok', false, 'error', 'An invoice can only be matched to a PO that has been approved and not cancelled.'); end if;
  if length(btrim(coalesce(p_ref, ''))) < 1 then return jsonb_build_object('ok', false, 'error', 'Enter the invoice number.'); end if;
  if p_net is null or p_net < 0 then return jsonb_build_object('ok', false, 'error', 'Enter the invoice total before VAT.'); end if;
  insert into flow.po_invoices (po_id, invoice_ref, invoice_date, net_total, vat_total, note, created_by) values (p_po, btrim(p_ref), p_date, p_net, p_vat, nullif(btrim(coalesce(p_note, '')), ''), p_actor)
  on conflict (po_id, invoice_ref) do nothing returning id into v_id;
  if v_id is null then return jsonb_build_object('ok', false, 'error', 'That invoice number is already recorded on this PO.'); end if;
  update flow.purchase_orders set invoice_ref = coalesce(invoice_ref, btrim(p_ref)) where id = p_po;
  perform flow.wh_audit(p_actor, 'po_invoice_recorded', 'purchase_order', coalesce(po.af_po_ref, po.po_number), null, jsonb_build_object('invoice', btrim(p_ref), 'net', p_net), p_note);
  select match_status, variance into v_m from flow.v_po_invoice_match where id = v_id;
  return jsonb_build_object('ok', true, 'invoice_id', v_id, 'match_status', v_m.match_status, 'variance', v_m.variance);
end $$;

create or replace function flow.po_invoice_resolve(p_id uuid, p_action text, p_reason text, p_senior boolean, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare i flow.po_invoices;
begin
  select * into i from flow.po_invoices where id = p_id;
  if i.id is null then return jsonb_build_object('ok', false, 'error', 'Invoice not found.'); end if;
  if p_action not in ('accept', 'dispute', 'reopen') then return jsonb_build_object('ok', false, 'error', 'Choose accept, dispute or reopen.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Give a reason.'); end if;
  if p_action = 'accept' and not coalesce(p_senior, false) then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can accept an invoice that does not match.'); end if;
  update flow.po_invoices set resolution = case p_action when 'accept' then 'accepted' when 'dispute' then 'disputed' else null end, resolution_reason = btrim(p_reason), resolved_by = p_actor, resolved_at = now() where id = p_id;
  perform flow.wh_audit(p_actor, 'po_invoice_' || p_action, 'purchase_order', i.invoice_ref, null, jsonb_build_object('invoice_id', p_id), p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace view public.ui_po_invoices with (security_invoker = true) as select * from flow.v_po_invoice_match;

insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('po_invoice_mismatch', 'Supplier invoice does not match what was received', 'purchasing', 'medium', '{}', 'manager', 'Check the invoice against the delivery. Ask the supplier for a credit note or a corrected invoice, or accept the difference with a reason.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_invoices() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', 'po_invoice_mismatch', 'key', 'po_invoice:' || m.id,
    'description', format('Invoice %s from %s for PO %s is £%s %s what was received (invoice £%s, expected £%s)', m.invoice_ref, coalesce(m.supplier, 'the supplier'), m.po_ref, abs(m.variance), case when m.variance > 0 then 'more than' else 'less than' end, m.net_total, m.expected_net),
    'links', '[]'::jsonb, 'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'supplier', 'detected_by', 'automation', 'source_type', 'po_invoice', 'source_id', m.id::text)) ), '[]'::jsonb)
  from flow.v_po_invoice_match m where m.match_status in ('over_billed', 'under_billed') and m.resolution is null
$$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%''invoices''%' then
    v_def := replace(v_def, '''qc_checklist''] loop', '''qc_checklist'',''invoices''] loop');
    if v_def not like '%''invoices''%' then raise exception 'detector list anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- 3. Scheduled chasing: drafts only, off until switched on, never twice inside the repeat window --------------------
create or replace function flow.po_chase_scheduled(p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare r jsonb := flow.purchasing_rules(); x record; v_res jsonb; v_made int := 0; v_wait int := 0; v_skip int := 0; v_days int := (r->>'chase_min_days_late')::int; v_rep int := (r->>'chase_repeat_days')::int;
begin
  if not coalesce((r->>'chase_enabled')::boolean, false) then return jsonb_build_object('ok', true, 'enabled', false, 'drafted', 0, 'message', 'Scheduled chasing is switched off.'); end if;
  for x in select p.id from flow.purchase_orders p where p.is_active and ((p.expected_date::date <= current_date - greatest(v_days, 1)) or (p.po_status = 'sent' and p.acknowledged_at is null and p.sent_at < now() - interval '24 hours')) order by p.expected_date loop
    if exists (select 1 from flow.communications c where c.entity_type = 'po' and c.entity_id = x.id and c.kind = 'other' and c.subject like 'Chase:%' and c.created_at > now() - make_interval(days => greatest(v_rep, 1))) then v_wait := v_wait + 1; continue; end if;
    v_res := flow.po_chase_draft(x.id, p_actor);
    if (v_res->>'ok')::boolean and not coalesce((v_res->>'already_queued')::boolean, false) then v_made := v_made + 1; else v_skip := v_skip + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'enabled', true, 'drafted', v_made, 'waiting_for_repeat_window', v_wait, 'skipped', v_skip);
end $$;

-- Wrappers (service role only) and grants ---------------------------------------------------------------------------
create or replace function public.flow_po_approve_checked(p_po uuid, p_actor text, p_role text, p_reason text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_approve_checked(p_po, p_actor, p_role, p_reason) $$;
create or replace function public.flow_po_invoice_record(p_po uuid, p_ref text, p_date date, p_net numeric, p_vat numeric, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_invoice_record(p_po, p_ref, p_date, p_net, p_vat, p_note, p_actor) $$;
create or replace function public.flow_po_invoice_resolve(p_id uuid, p_action text, p_reason text, p_senior boolean, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_invoice_resolve(p_id, p_action, p_reason, p_senior, p_actor) $$;
create or replace function public.flow_po_chase_scheduled(p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_chase_scheduled(p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_po_approve_checked(uuid,text,text,text)', 'public.flow_po_invoice_record(uuid,text,date,numeric,numeric,text,text)', 'public.flow_po_invoice_resolve(uuid,text,text,boolean,text)', 'public.flow_po_chase_scheduled(text)',
    'flow.po_approve_checked(uuid,text,text,text)', 'flow.po_invoice_record(uuid,text,date,numeric,numeric,text,text)', 'flow.po_invoice_resolve(uuid,text,text,boolean,text)', 'flow.po_chase_scheduled(text)', 'flow.exc_detect_invoices()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    if f like 'public.%' then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
  revoke all on flow.po_invoices, flow.v_po_invoice_match, public.ui_po_invoices from public, anon;
  grant select on flow.po_invoices, flow.v_po_invoice_match, public.ui_po_invoices to authenticated;
end $$;
