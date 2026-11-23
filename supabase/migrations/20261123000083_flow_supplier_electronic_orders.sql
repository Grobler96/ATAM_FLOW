-- 23 Nov 2026: ordering stock electronically (APPLIED to the live project 23 Nov 2026 as "flow_supplier_electronic_orders").
-- Ralawise takes orders by API and ORN by SFTP (a CSV file). This adds the Flow side; the sending itself is done by n8n workflows
-- (drafts, not published) that need the supplier logins set up as n8n credentials.
--  1. For a supplier whose card says the order method is API or EDI, "send the PO" no longer queues an email. It prepares an
--     electronic order (flow.po_transmissions) that WAITS FOR A PERSON TO APPROVE IT, like every email does, then n8n sends it.
--  2. The order is held in a neutral shape (PO reference, lines, delivery address, delivery option); n8n turns it into the Ralawise
--     JSON or the ORN CSV. Delivery is to our warehouse; the address is a setting (check it).
--  3. When n8n reports it sent, the PO moves to "sent" with the supplier's own order number. A failure is kept with its reason and
--     can be tried again by a person; nothing is ever sent twice by itself (a claimed order is never claimed again until a person
--     re-queues it).

-- 1. Settings -------------------------------------------------------------------------------------------------------------------------
insert into flow.flow_settings (key, value, description)
values ('buying.delivery_address', jsonb_build_object('name', 'ATAM', 'line1', '1 First Avenue', 'line2', 'Sherburn Industrial Park, Sherburn', 'town', 'Leeds', 'county', '', 'postcode', 'LS25 6PD', 'country_code', 'GB', 'country_name', 'England', 'contact_name', 'Daniel Spooner', 'phone', '01977687321'),
        'Where electronic supplier orders are delivered (our warehouse) and who the supplier contacts. From the company email signature: please check it.')
on conflict (key) do nothing;

-- 2. The table ------------------------------------------------------------------------------------------------------------------------
create table if not exists flow.po_transmissions (
  id                 uuid primary key default gen_random_uuid(),
  po_id              uuid not null references flow.purchase_orders(id),
  supplier_id        uuid not null references flow.suppliers(id),
  method             text not null check (method in ('api', 'edi')),
  status             text not null default 'pending_review' check (status in ('pending_review', 'queued', 'sending', 'sent', 'failed', 'cancelled')),
  payload            jsonb not null,
  attempts           int not null default 0,
  last_error         text,
  supplier_order_ref text,
  response           jsonb,
  queued_by          text not null,
  queued_at          timestamptz not null default now(),
  approved_by        text,
  approved_at        timestamptz,
  sent_at            timestamptz,
  cancelled_by       text,
  cancel_reason      text,
  updated_at         timestamptz not null default now()
);
create unique index if not exists po_transmissions_one_open on flow.po_transmissions (po_id) where status in ('pending_review', 'queued', 'sending');
create index if not exists po_transmissions_status on flow.po_transmissions (status, queued_at);
alter table flow.po_transmissions enable row level security;
drop policy if exists po_transmissions_read on flow.po_transmissions;
create policy po_transmissions_read on flow.po_transmissions for select to authenticated using (flow.is_member());

-- 3. Building the order from a PO -------------------------------------------------------------------------------------------------
create or replace function flow.po_tx_payload(p_po uuid) returns jsonb
language plpgsql stable security definer set search_path = flow, public as $$
declare po flow.purchase_orders; s flow.suppliers; v_addr jsonb := coalesce(flow.setting('buying.delivery_address'), '{}'::jsonb); v_opt flow.supplier_shipping_options;
begin
  select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
  if not found then raise exception 'purchase order not found'; end if;
  select * into s from flow.suppliers where id = po.supplier_ref_id;
  if po.deliver_to = 'producer' then raise exception 'electronic orders are delivered to our warehouse for now; this PO is set to deliver straight to a decorator'; end if;
  if coalesce(v_addr->>'line1', '') = '' or coalesce(v_addr->>'postcode', '') = '' or coalesce(v_addr->>'town', '') = '' then raise exception 'the delivery address setting (buying.delivery_address) is incomplete'; end if;
  if length(po.af_po_ref) > 20 then raise exception 'the PO reference % is longer than the 20 characters suppliers accept', po.af_po_ref; end if;
  if not exists (select 1 from flow.po_lines where po_id = p_po) then raise exception 'the PO has no lines'; end if;
  if exists (select 1 from flow.po_lines where po_id = p_po and (qty_expected is null or qty_expected <= 0)) then raise exception 'every line needs a quantity above zero'; end if;
  select * into v_opt from flow.supplier_shipping_options where supplier_id = s.id and is_active and is_default limit 1;
  return jsonb_build_object(
    'po_id', po.id, 'po_ref', po.af_po_ref, 'currency', po.currency, 'notes', po.notes, 'required_by', po.required_by,
    'supplier', jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'method', s.order_method, 'account_number', s.account_number),
    'delivery', v_addr,
    'shipping_option', case when v_opt.id is null then null else jsonb_build_object('name', v_opt.name, 'cost', v_opt.cost, 'notes', v_opt.notes) end,
    'lines', (select jsonb_agg(jsonb_build_object('line_ref', l.line_no::text, 'sku', coalesce(nullif(btrim(l.supplier_sku), ''), l.sku), 'qty', l.qty_expected, 'unit_cost', l.unit_cost) order by l.line_no) from flow.po_lines l where l.po_id = p_po));
end $$;

-- 4. Preparing the order (replaces the email for API / EDI suppliers) ---------------------------------------------------------------
create or replace function flow.po_send_electronic(p_po uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders; s flow.suppliers; v_payload jsonb; v_id uuid;
begin
  begin
    select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
    if not found then raise exception 'purchase order not found'; end if;
    if po.po_status <> 'approved' then raise exception 'approve the PO before sending it (status: %)', po.po_status; end if;
    select * into s from flow.suppliers where id = po.supplier_ref_id;
    if s.order_method not in ('api', 'edi') then raise exception 'this supplier is not ordered from electronically'; end if;
    if exists (select 1 from flow.po_transmissions t where t.po_id = p_po and t.status in ('pending_review', 'queued', 'sending', 'sent')) then raise exception 'an electronic order for this PO already exists'; end if;
    v_payload := flow.po_tx_payload(p_po);
    insert into flow.po_transmissions (po_id, supplier_id, method, payload, queued_by) values (p_po, s.id, s.order_method, v_payload, coalesce(nullif(btrim(p_actor), ''), 'unknown')) returning id into v_id;
    insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'queue_po_electronic', 'purchase_order', p_po::text, jsonb_build_object('transmission', v_id, 'method', s.order_method));
    return jsonb_build_object('ok', true, 'transmission_id', v_id, 'status', 'pending_review', 'note', 'electronic order prepared: a person has to approve it before it is sent to ' || s.name);
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- send_purchase_order: for an API / EDI supplier prepare the electronic order instead of an email.
do $patch$
declare v_def text := pg_get_functiondef('flow.send_purchase_order(uuid,text)'::regprocedure); v_new text;
begin
  v_new := replace(v_def, $a$select * into s from flow.suppliers where id = po.supplier_ref_id;$a$,
    $b$select * into s from flow.suppliers where id = po.supplier_ref_id;
    if s.order_method in ('api', 'edi') then return flow.po_send_electronic(p_po, p_actor); end if;$b$);
  if v_new = v_def then raise exception 'send_purchase_order: the supplier lookup was not found, nothing changed'; end if;
  execute v_new;
end $patch$;

-- 5. Person approves, cancels, or retries ------------------------------------------------------------------------------------------------
create or replace function flow.po_tx_approve(p_id uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.po_transmissions;
begin
  update flow.po_transmissions set status = 'queued', approved_by = p_actor, approved_at = now(), last_error = case when status = 'failed' then last_error else null end, updated_at = now()
    where id = p_id and status in ('pending_review', 'failed') returning * into t;
  if not found then return jsonb_build_object('ok', false, 'error', 'that order is not waiting for approval (it may already be sent or cancelled)'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'approve_po_electronic', 'purchase_order', t.po_id::text, jsonb_build_object('transmission', p_id));
  return jsonb_build_object('ok', true, 'status', 'queued');
end $$;

create or replace function flow.po_tx_cancel(p_id uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.po_transmissions;
begin
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'error', 'give a reason (at least 5 characters)'); end if;
  update flow.po_transmissions set status = 'cancelled', cancelled_by = p_actor, cancel_reason = btrim(p_reason), updated_at = now()
    where id = p_id and status in ('pending_review', 'queued', 'failed') returning * into t;
  if not found then return jsonb_build_object('ok', false, 'error', 'that order can no longer be cancelled here (it may already be sending or sent)'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'cancel_po_electronic', 'purchase_order', t.po_id::text, jsonb_build_object('transmission', p_id, 'reason', btrim(p_reason)));
  return jsonb_build_object('ok', true);
end $$;

-- 6. What n8n does ---------------------------------------------------------------------------------------------------------------------------
-- Claim the approved orders for one method (api or edi), optionally only for the supplier whose name contains p_supplier (each sender claims only its own).
-- A claimed order is 'sending' and is never handed out again by itself.
create or replace function flow.po_tx_claim(p_method text, p_limit int, p_supplier text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v jsonb;
begin
  if p_method not in ('api', 'edi') then return jsonb_build_object('ok', false, 'error', 'method must be api or edi'); end if;
  with c as (select id from flow.po_transmissions where status = 'queued' and method = p_method and (nullif(btrim(coalesce(p_supplier, '')), '') is null or exists (select 1 from flow.suppliers s where s.id = supplier_id and s.name ilike '%' || btrim(p_supplier) || '%')) order by approved_at, queued_at limit greatest(1, least(coalesce(p_limit, 5), 10)) for update skip locked),
       u as (update flow.po_transmissions t set status = 'sending', attempts = attempts + 1, updated_at = now() from c where t.id = c.id returning t.id, t.po_id, t.supplier_id, t.method, t.payload, t.attempts)
  select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) into v from u;
  return jsonb_build_object('ok', true, 'orders', v);
end $$;

create or replace function flow.po_tx_done(p_id uuid, p_supplier_ref text, p_response jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.po_transmissions;
begin
  update flow.po_transmissions set status = 'sent', sent_at = now(), supplier_order_ref = nullif(btrim(coalesce(p_supplier_ref, '')), ''), response = p_response, last_error = nullif(left(coalesce(p_response->>'warnings', ''), 1000), ''), updated_at = now()
    where id = p_id and status = 'sending' returning * into t;
  if not found then return jsonb_build_object('ok', false, 'error', 'that order is not being sent'); end if;
  update flow.purchase_orders set po_status = 'sent', sent_at = coalesce(sent_at, now()), is_active = true, delivery_status = 'expected', supplier_ref = coalesce(nullif(btrim(coalesce(p_supplier_ref, '')), ''), supplier_ref)
    where id = t.po_id and origin = 'atam_flow' and po_status in ('approved', 'draft');
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (coalesce(p_actor, 'n8n'), 'po_sent_electronic', 'purchase_order', t.po_id::text, jsonb_build_object('transmission', p_id, 'supplier_ref', p_supplier_ref));
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.po_tx_failed(p_id uuid, p_error text, p_response jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare t flow.po_transmissions;
begin
  update flow.po_transmissions set status = 'failed', last_error = left(coalesce(p_error, 'unknown error'), 1000), response = p_response, updated_at = now()
    where id = p_id and status = 'sending' returning * into t;
  if not found then return jsonb_build_object('ok', false, 'error', 'that order is not being sent'); end if;
  perform flow.notify('po_electronic_failed', 'warning', 'An electronic supplier order failed', left(coalesce(p_error, 'unknown error'), 300), 'purchase_order', t.po_id);
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (coalesce(p_actor, 'n8n'), 'po_failed_electronic', 'purchase_order', t.po_id::text, jsonb_build_object('transmission', p_id, 'error', left(coalesce(p_error, ''), 300)));
  return jsonb_build_object('ok', true);
end $$;

-- 7. Callable pieces ------------------------------------------------------------------------------------------------------------------------
-- Staff screen: role-checked here, like the catalogue and supplier cards.
create or replace function public.po_tx_approve(p_id uuid) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can approve an order to a supplier.'); end if;
  return flow.po_tx_approve(p_id, flow.catalogue_actor());
end $$;
create or replace function public.po_tx_cancel(p_id uuid, p_reason text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only a manager or admin can cancel an order to a supplier.'); end if;
  return flow.po_tx_cancel(p_id, p_reason, flow.catalogue_actor());
end $$;
-- n8n (service role only).
create or replace function public.flow_po_tx_claim(p_method text, p_limit int, p_supplier text default null) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_tx_claim(p_method, p_limit, p_supplier) $$;
create or replace function public.flow_po_tx_done(p_id uuid, p_supplier_ref text, p_response jsonb, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_tx_done(p_id, p_supplier_ref, p_response, p_actor) $$;
create or replace function public.flow_po_tx_failed(p_id uuid, p_error text, p_response jsonb, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.po_tx_failed(p_id, p_error, p_response, p_actor) $$;

create or replace view public.ui_po_transmissions with (security_invoker = true) as
select t.id, t.po_id, po.af_po_ref as po_ref, s.name as supplier, t.method, t.status, t.attempts, t.last_error, t.supplier_order_ref, t.queued_by, t.queued_at, t.approved_by, t.approved_at, t.sent_at,
       t.cancel_reason, t.updated_at, jsonb_array_length(coalesce(t.payload->'lines', '[]'::jsonb)) as line_count,
       (select coalesce(sum((x->>'qty')::numeric * coalesce((x->>'unit_cost')::numeric, 0)), 0) from jsonb_array_elements(coalesce(t.payload->'lines', '[]'::jsonb)) x) as goods_value
from flow.po_transmissions t join flow.purchase_orders po on po.id = t.po_id join flow.suppliers s on s.id = t.supplier_id
where flow.is_member();

do $g$
declare f text;
begin
  revoke all on flow.po_transmissions from public, anon, authenticated;
  grant select on flow.po_transmissions to authenticated;
  revoke all on public.ui_po_transmissions from public, anon;
  grant select on public.ui_po_transmissions to authenticated;
  foreach f in array array['flow.po_tx_payload(uuid)', 'flow.po_send_electronic(uuid,text)', 'flow.po_tx_approve(uuid,text)', 'flow.po_tx_cancel(uuid,text,text)', 'flow.po_tx_claim(text,integer,text)', 'flow.po_tx_done(uuid,text,jsonb,text)', 'flow.po_tx_failed(uuid,text,jsonb,text)',
                           'public.po_tx_approve(uuid)', 'public.po_tx_cancel(uuid,text)',
                           'public.flow_po_tx_claim(text,integer,text)', 'public.flow_po_tx_done(uuid,text,jsonb,text)', 'public.flow_po_tx_failed(uuid,text,jsonb,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.po_tx_approve(uuid), public.po_tx_cancel(uuid, text) to authenticated;
  grant execute on function public.flow_po_tx_claim(text, int, text), public.flow_po_tx_done(uuid, text, jsonb, text), public.flow_po_tx_failed(uuid, text, jsonb, text) to service_role;
end $g$;
