-- Purchasing functions. Every function returns {ok:true,...} or {ok:false,error}; a failed call changes nothing.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function flow.setting(p_key text) returns jsonb language sql stable set search_path = flow, public as $$
  select value from flow.flow_settings where key = p_key
$$;
create or replace function flow.html_escape(p text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;
create or replace function flow.text_to_html(p text) returns text language sql immutable as $$
  select '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5;white-space:pre-wrap">' || flow.html_escape(p) || '</div>'
$$;
create or replace function flow.notify(p_kind text, p_severity text, p_title text, p_body text, p_entity_type text, p_entity_id uuid) returns void
language sql security definer set search_path = flow, public as $$
  insert into flow.notifications (kind, severity, title, body, entity_type, entity_id) values (p_kind, p_severity, p_title, p_body, p_entity_type, p_entity_id)
$$;

-- Queue an outbound message. Whether it waits for review or is ready to send comes from comms.settings.review_required.
create or replace function flow.queue_comm(p_kind text, p_to text[], p_subject text, p_text text, p_html text, p_entity_type text, p_entity_id uuid,
  p_supplier uuid, p_producer uuid, p_actor text, p_attachments jsonb default '[]'::jsonb) returns uuid
language plpgsql security definer set search_path = flow, public as $$
declare v_set jsonb := coalesce(flow.setting('comms.settings'), '{}'::jsonb); v_review boolean; v_status text; v_id uuid; v_to text[] := coalesce(p_to, '{}');
begin
  v_review := coalesce((v_set->'review_required'->>p_kind)::boolean, true);
  v_to := array(select x from unnest(v_to) x where coalesce(x, '') <> '');
  v_status := case when cardinality(v_to) = 0 then 'draft' when v_review then 'pending_review' else 'approved' end;
  insert into flow.communications (comm_ref, kind, to_addresses, reply_to, subject, body_text, body_html, attachments, status, entity_type, entity_id,
      supplier_id, producer_id, requires_review, created_by, approved_by, approved_at)
  values ('COM-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.comm_seq')::text, 5, '0'), p_kind, v_to, v_set->>'reply_to', p_subject, p_text,
      coalesce(p_html, flow.text_to_html(p_text)), coalesce(p_attachments, '[]'::jsonb), v_status, p_entity_type, p_entity_id, p_supplier, p_producer, v_review,
      p_actor, case when v_status = 'approved' then 'auto (review not required)' end, case when v_status = 'approved' then now() end)
  returning id into v_id;
  if v_status = 'draft' then
    perform flow.notify('comm_no_recipient', 'warning', 'Email has no recipient: ' || p_subject, 'Add an email address to the supplier, then edit and approve the message.', 'communication', v_id);
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Stock requirements: what each waiting order line still needs buying, net of reservations and stock already on order
-- ---------------------------------------------------------------------------
create or replace function flow.po_requirements(p_order_ids uuid[] default null)
returns table (order_id uuid, order_ref text, order_line_id uuid, sku text, product_name text, garment_type text, brand text, colour text, size text,
               qty_needed int, due_date timestamptz)
language sql stable security definer set search_path = flow, public as $$
  select o.id, o.order_ref, l.id, l.sku, l.product_name, l.garment_type, l.brand, l.colour, l.size,
    greatest(greatest(l.qty_required - l.qty_produced, 0)
      - coalesce((select sum(a.qty) from flow.allocations a where a.order_line_id = l.id and a.status = 'active' and a.source = 'on_hand'), 0)
      - greatest(coalesce((select sum(a.qty) from flow.allocations a where a.order_line_id = l.id and a.status = 'active' and a.source = 'incoming_po'), 0),
                 coalesce((select sum(s.qty) from flow.po_line_sources s join flow.po_lines pl on pl.id = s.po_line_id join flow.purchase_orders p on p.id = pl.po_id
                           where s.order_line_id = l.id and coalesce(p.po_status::text, 'open') not in ('cancelled','closed','received')), 0)), 0)::int,
    o.due_date
  from flow.orders o
  join flow.order_lines l on l.order_id = o.id and l.is_active and l.sku is not null
  where o.is_active and not o.stock_secured
    and (p_order_ids is null and exists (select 1 from flow.deco_status_map m where m.code = o.deco_status and m.maps_to = 'awaiting_stock')
         or o.id = any (p_order_ids))
    and l.qty_required - l.qty_produced > 0
$$;

-- ---------------------------------------------------------------------------
-- Create a PO. p_lines: [{sku, qty, unit_cost?, product_name?, colour?, size?, garment_type?, brand?, sources:[{order_line_id, qty}]}]
-- p_opts: {required_by, notes, deliver_to: warehouse|producer, producer_id, delivery_cost}
-- ---------------------------------------------------------------------------
create or replace function flow.create_purchase_order(p_supplier uuid, p_lines jsonb, p_actor text, p_opts jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  s flow.suppliers; v_n bigint; v_ref text; v_po uuid; v_it jsonb; v_pl uuid; v_i int := 0; v_cost numeric; v_src jsonb; v_srcsum int; v_qty int;
  v_opt jsonb := coalesce(flow.setting('purchasing.options'), '{}'::jsonb); v_vat numeric := coalesce((v_opt->>'vat_rate')::numeric, 0.2);
  v_prefix text := coalesce(v_opt->>'po_prefix', 'AF-PO'); v_sub numeric; v_del numeric; v_tax numeric; v_warn jsonb := '[]'::jsonb;
  v_deliver text := coalesce(nullif(p_opts->>'deliver_to', ''), 'warehouse'); v_prod uuid := nullif(p_opts->>'producer_id', '')::uuid; v_nocost int := 0;
begin
  begin
    select * into s from flow.suppliers where id = p_supplier and is_active;
    if not found then raise exception 'supplier not found or inactive'; end if;
    if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'a purchase order needs at least one line'; end if;
    if v_deliver not in ('warehouse','producer') then raise exception 'deliver_to must be warehouse or producer'; end if;
    if v_deliver = 'producer' and v_prod is null then raise exception 'a producer is required when delivering to a producer'; end if;
    if v_deliver = 'producer' and not s.can_deliver_to_producer then v_warn := v_warn || jsonb_build_array(s.name || ' is not marked as able to deliver direct to a producer'); end if;

    v_n := nextval('flow.af_po_seq'); v_ref := v_prefix || '-' || v_n;
    insert into flow.purchase_orders (deco_po_id, po_number, supplier, supplier_ref_id, delivery_status, date_raised, expected_date, is_active, origin, af_po_ref, po_status,
        po_date, required_by, currency, created_by, notes, deliver_to, deliver_to_producer_id)
    values (-v_n, v_ref, s.name, s.id, 'draft', now(), (current_date + ceil(s.lead_time_days)::int)::timestamptz, false, 'atam_flow', v_ref, 'draft',
        current_date, nullif(p_opts->>'required_by', '')::date, s.currency, p_actor, p_opts->>'notes', v_deliver, v_prod)
    returning id into v_po;

    for v_it in select * from jsonb_array_elements(p_lines) loop
      v_i := v_i + 1;
      v_qty := (v_it->>'qty')::int;
      if coalesce(v_it->>'sku', '') = '' or v_qty is null or v_qty <= 0 then raise exception 'line %: sku and a positive qty are required', v_i; end if;
      v_cost := nullif(v_it->>'unit_cost', '')::numeric;
      if v_cost is null then select o.unit_cost into v_cost from flow.supplier_offers o where o.supplier_id = p_supplier and o.sku = v_it->>'sku'; end if;
      if v_cost is null and to_regclass('public.sku_costs') is not null then
        execute 'select unit_cost from public.sku_costs where sku = $1' using v_it->>'sku' into v_cost;
      end if;
      if v_cost is null then v_nocost := v_nocost + 1; end if;
      insert into flow.po_lines (po_id, line_no, sku, product_name, qty_expected, unit_cost, garment_type, brand, colour, size, supplier_sku, expected_date)
      values (v_po, v_i, v_it->>'sku', v_it->>'product_name', v_qty, v_cost, v_it->>'garment_type', v_it->>'brand', v_it->>'colour', v_it->>'size',
        (select o.supplier_sku from flow.supplier_offers o where o.supplier_id = p_supplier and o.sku = v_it->>'sku'), (current_date + ceil(s.lead_time_days)::int))
      returning id into v_pl;
      v_srcsum := 0;
      for v_src in select * from jsonb_array_elements(coalesce(v_it->'sources', '[]'::jsonb)) loop
        insert into flow.po_line_sources (po_line_id, order_line_id, qty) values (v_pl, (v_src->>'order_line_id')::uuid, (v_src->>'qty')::int)
        on conflict (po_line_id, order_line_id) do update set qty = flow.po_line_sources.qty + excluded.qty;
        v_srcsum := v_srcsum + (v_src->>'qty')::int;
      end loop;
      if v_srcsum > v_qty then raise exception 'line %: sources total % but only % ordered', v_i, v_srcsum, v_qty; end if;
    end loop;

    select coalesce(sum(line_total), 0) into v_sub from flow.po_lines where po_id = v_po;
    v_del := coalesce(nullif(p_opts->>'delivery_cost', '')::numeric,
                      case when s.free_delivery_over is not null and v_sub >= s.free_delivery_over then 0 else s.delivery_cost end);
    v_tax := round((v_sub + v_del) * v_vat, 2);
    update flow.purchase_orders set subtotal = v_sub, delivery_cost = v_del, tax = v_tax, total_cost = v_sub + v_del + v_tax,
      qty_expected = (select sum(qty_expected) from flow.po_lines where po_id = v_po), qty_received = 0, receipt_status = 'none' where id = v_po;
    if s.min_order_value is not null and v_sub < s.min_order_value then
      v_warn := v_warn || jsonb_build_array(format('order value %s is below the supplier minimum of %s', v_sub, s.min_order_value));
    end if;
    if v_nocost > 0 then v_warn := v_warn || jsonb_build_array(format('%s line(s) have no unit cost: add costs before approving', v_nocost)); end if;
    insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'create_po', 'purchase_order', v_po::text, jsonb_build_object('ref', v_ref, 'lines', v_i, 'subtotal', v_sub));
    return jsonb_build_object('ok', true, 'po_id', v_po, 'af_po_ref', v_ref, 'lines', v_i, 'subtotal', v_sub, 'delivery_cost', v_del, 'tax', v_tax,
      'total_cost', v_sub + v_del + v_tax, 'status', 'draft', 'warnings', v_warn);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- Consolidate the outstanding requirement of one or more orders into a PO (identical SKUs merge into one line, each source order line is kept).
-- p_opts also accepts skus: ["SKU1", ...] to buy only part of the requirement here (split the rest across other suppliers).
create or replace function flow.create_po_for_orders(p_supplier uuid, p_order_ids uuid[], p_actor text, p_opts jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_lines jsonb;
begin
  select jsonb_agg(jsonb_build_object('sku', r.sku, 'qty', r.q, 'product_name', r.pn, 'garment_type', r.gt, 'brand', r.br, 'colour', r.col, 'size', r.sz, 'sources', r.src) order by r.sku)
    into v_lines
  from (select q.sku, sum(q.qty_needed)::int q, max(q.product_name) pn, max(q.garment_type) gt, max(q.brand) br, max(q.colour) col, max(q.size) sz,
               jsonb_agg(jsonb_build_object('order_line_id', q.order_line_id, 'qty', q.qty_needed)) src
        from flow.po_requirements(p_order_ids) q
        where q.qty_needed > 0 and (p_opts->'skus' is null or q.sku in (select jsonb_array_elements_text(p_opts->'skus')))
        group by q.sku) r;
  if v_lines is null then return jsonb_build_object('ok', false, 'error', 'nothing left to order for these orders (already allocated or already on a purchase order)'); end if;
  return flow.create_purchase_order(p_supplier, v_lines, p_actor, p_opts);
end $$;

create or replace function flow.approve_purchase_order(p_po uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders;
begin
  begin
    select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
    if not found then raise exception 'purchase order not found'; end if;
    if po.po_status <> 'draft' then raise exception 'only a draft PO can be approved (this one is %)', po.po_status; end if;
    if exists (select 1 from flow.po_lines where po_id = p_po and unit_cost is null) then raise exception 'every line needs a unit cost before the PO can be approved'; end if;
    update flow.purchase_orders set po_status = 'approved', approved_by = p_actor, approved_at = now() where id = p_po;
    insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'approve_po', 'purchase_order', p_po::text);
    return jsonb_build_object('ok', true, 'status', 'approved');
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- Prepare the PO email. The PO becomes 'sent' only when the message really goes out (comm_mark_sent).
create or replace function flow.send_purchase_order(p_po uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders; s flow.suppliers; v_set jsonb := coalesce(flow.setting('comms.settings'), '{}'::jsonb); v_txt text; v_html text; v_rows text; v_hrows text; v_id uuid;
  v_addr text; v_to_prod flow.producers;
begin
  begin
    select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
    if not found then raise exception 'purchase order not found'; end if;
    if po.po_status <> 'approved' then raise exception 'approve the PO before sending it (status: %)', po.po_status; end if;
    if exists (select 1 from flow.communications c where c.entity_id = p_po and c.kind = 'po_send' and c.status in ('pending_review','approved','sending','draft')) then
      raise exception 'a message for this PO is already waiting to be sent'; end if;
    select * into s from flow.suppliers where id = po.supplier_ref_id;
    if po.deliver_to = 'producer' then select * into v_to_prod from flow.producers where id = po.deliver_to_producer_id; end if;
    v_addr := case when po.deliver_to = 'producer' then concat_ws(', ', v_to_prod.name, v_to_prod.address) else coalesce(v_set->>'delivery_address', '(our warehouse - address to be confirmed)') end;
    select string_agg(format('%s | %s | %s | %s | %s | %s', l.sku, coalesce(l.product_name, ''), coalesce(l.colour, ''), coalesce(l.size, ''), l.qty_expected,
                             coalesce(to_char(l.unit_cost, 'FM999990.00'), '-')), E'\n' order by l.line_no),
           string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td style="text-align:right">%s</td><td style="text-align:right">%s</td></tr>',
             flow.html_escape(l.sku), flow.html_escape(l.product_name), flow.html_escape(l.colour), flow.html_escape(l.size), l.qty_expected,
             coalesce(to_char(l.unit_cost, 'FM999990.00'), '-')), '' order by l.line_no)
      into v_rows, v_hrows from flow.po_lines l where l.po_id = p_po;
    v_txt := format(E'Hi %s,\n\nPlease find our purchase order below. Please confirm receipt and your expected delivery date.\n\nPO reference: %s\nOrder date: %s\nRequired by: %s\nDeliver to: %s\n\nSKU | Product | Colour | Size | Qty | Unit cost\n%s\n\nSubtotal: %s %s\nDelivery: %s %s\nVAT: %s %s\nTotal: %s %s\n%s\nPlease reply to this email to acknowledge.\n\nRegards,\n%s',
      coalesce(s.contact_name, s.name), po.af_po_ref, po.po_date, coalesce(po.required_by::text, 'as soon as possible'), v_addr, v_rows,
      po.currency, to_char(coalesce(po.subtotal, 0), 'FM999990.00'), po.currency, to_char(coalesce(po.delivery_cost, 0), 'FM999990.00'),
      po.currency, to_char(coalesce(po.tax, 0), 'FM999990.00'), po.currency, to_char(coalesce(po.total_cost, 0), 'FM999990.00'),
      case when po.notes is not null then E'\nNotes: ' || po.notes || E'\n' else '' end, coalesce(v_set->>'signature', 'ATAM FLOW Production Control'));
    v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5"><p>Hi ' || flow.html_escape(coalesce(s.contact_name, s.name)) ||
      ',</p><p>Please find our purchase order below. Please confirm receipt and your expected delivery date.</p><p><b>PO reference:</b> ' || flow.html_escape(po.af_po_ref) ||
      '<br><b>Required by:</b> ' || flow.html_escape(coalesce(po.required_by::text, 'as soon as possible')) || '<br><b>Deliver to:</b> ' || flow.html_escape(v_addr) ||
      '</p><table style="border-collapse:collapse" border="1" cellpadding="6"><tr><th>SKU</th><th>Product</th><th>Colour</th><th>Size</th><th>Qty</th><th>Unit cost</th></tr>' || v_hrows ||
      '</table><p><b>Subtotal:</b> ' || po.currency || ' ' || to_char(coalesce(po.subtotal, 0), 'FM999990.00') || '<br><b>Delivery:</b> ' || to_char(coalesce(po.delivery_cost, 0), 'FM999990.00') ||
      '<br><b>VAT:</b> ' || to_char(coalesce(po.tax, 0), 'FM999990.00') || '<br><b>Total:</b> ' || po.currency || ' ' || to_char(coalesce(po.total_cost, 0), 'FM999990.00') ||
      '</p>' || case when po.notes is not null then '<p>Notes: ' || flow.html_escape(po.notes) || '</p>' else '' end || '<p>Please reply to this email to acknowledge.</p><p>Regards,<br>' ||
      flow.html_escape(coalesce(v_set->>'signature', 'ATAM FLOW Production Control')) || '</p></div>';
    v_id := flow.queue_comm('po_send', array[s.email], 'Purchase Order ' || po.af_po_ref || ' - ' || coalesce(v_set->>'company_name', 'ATAM'), v_txt, v_html, 'purchase_order', p_po, s.id, null, p_actor);
    insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'queue_po_email', 'purchase_order', p_po::text, jsonb_build_object('communication', v_id));
    return jsonb_build_object('ok', true, 'communication_id', v_id, 'status', (select status from flow.communications where id = v_id),
      'note', case when s.email is null then 'supplier has no email address: add one, then edit and approve the message' else 'message queued' end);
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function flow.acknowledge_purchase_order(p_po uuid, p_expected_delivery date, p_supplier_ref text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders;
begin
  begin
    select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
    if not found then raise exception 'purchase order not found'; end if;
    if po.po_status not in ('sent','acknowledged') then raise exception 'only a sent PO can be acknowledged (status: %)', po.po_status; end if;
    update flow.purchase_orders set po_status = 'acknowledged', acknowledged_at = coalesce(acknowledged_at, now()), supplier_ref = coalesce(p_supplier_ref, supplier_ref),
      expected_date = coalesce(p_expected_delivery::timestamptz, expected_date) where id = p_po;
    if p_expected_delivery is not null then update flow.po_lines set expected_date = p_expected_delivery where po_id = p_po and qty_outstanding_eff > 0; end if;
    insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'acknowledge_po', 'purchase_order', p_po::text, jsonb_build_object('expected', p_expected_delivery, 'supplier_ref', p_supplier_ref));
    return jsonb_build_object('ok', true, 'status', 'acknowledged', 'expected_delivery', p_expected_delivery);
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

create or replace function flow.cancel_purchase_order(p_po uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare po flow.purchase_orders;
begin
  begin
    if coalesce(p_reason, '') = '' then raise exception 'a reason is required'; end if;
    select * into po from flow.purchase_orders where id = p_po and origin = 'atam_flow';
    if not found then raise exception 'purchase order not found'; end if;
    if po.po_status not in ('draft','approved','sent','acknowledged') then raise exception 'a PO that is % cannot be cancelled', po.po_status; end if;
    if exists (select 1 from flow.po_lines where po_id = p_po and (qty_received_af > 0 or qty_damaged > 0 or qty_incorrect > 0)) then raise exception 'goods have already been booked in against this PO'; end if;
    update flow.purchase_orders set po_status = 'cancelled', is_active = false, delivery_status = 'cancelled', notes = concat_ws(E'\n', notes, 'Cancelled: ' || p_reason) where id = p_po;
    insert into flow.audit_log (actor, action, entity, entity_id, reason) values (p_actor, 'cancel_po', 'purchase_order', p_po::text, p_reason);
    return jsonb_build_object('ok', true, 'status', 'cancelled', 'note', 'the next allocation run will re-plan the orders that were relying on this PO');
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Communication log actions
-- ---------------------------------------------------------------------------
create or replace function flow.comm_edit(p_id uuid, p_subject text, p_body text, p_to text[], p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.communications;
begin
  begin
    select * into c from flow.communications where id = p_id;
    if not found then raise exception 'message not found'; end if;
    if c.status not in ('draft','pending_review') then raise exception 'a % message can no longer be edited (resend it instead)', c.status; end if;
    update flow.communications set subject = coalesce(nullif(p_subject, ''), subject), body_text = coalesce(nullif(p_body, ''), body_text),
      body_html = case when p_body is not null and p_body <> '' then flow.text_to_html(p_body) else body_html end,
      to_addresses = case when p_to is not null and cardinality(p_to) > 0 then p_to else to_addresses end,
      status = case when status = 'draft' and (p_to is not null and cardinality(p_to) > 0 or cardinality(to_addresses) > 0) then 'pending_review' else status end,
      edited_by = p_actor, edited_at = now() where id = p_id;
    insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'edit_comm', 'communication', p_id::text);
    return jsonb_build_object('ok', true);
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;
create or replace function flow.comm_approve(p_id uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.communications;
begin
  begin
    select * into c from flow.communications where id = p_id;
    if not found then raise exception 'message not found'; end if;
    if c.status not in ('pending_review','draft','failed') then raise exception 'a % message cannot be approved', c.status; end if;
    if cardinality(c.to_addresses) = 0 then raise exception 'add a recipient first'; end if;
    update flow.communications set status = 'approved', approved_by = p_actor, approved_at = now(), error = null where id = p_id;
    insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'approve_comm', 'communication', p_id::text);
    return jsonb_build_object('ok', true, 'status', 'approved');
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;
create or replace function flow.comm_cancel(p_id uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  update flow.communications set status = 'cancelled', edited_by = p_actor, edited_at = now() where id = p_id and status in ('draft','pending_review','approved','failed');
  if not found then return jsonb_build_object('ok', false, 'error', 'message not found or already sent'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'cancel_comm', 'communication', p_id::text);
  return jsonb_build_object('ok', true);
end $$;
create or replace function flow.comm_resend(p_id uuid, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.communications; v_id uuid;
begin
  begin
    select * into c from flow.communications where id = p_id;
    if not found then raise exception 'message not found'; end if;
    v_id := flow.queue_comm(c.kind, c.to_addresses, c.subject, c.body_text, c.body_html, c.entity_type, c.entity_id, c.supplier_id, c.producer_id, p_actor, c.attachments);
    update flow.communications set resend_of = p_id where id = v_id;
    insert into flow.audit_log (actor, action, entity, entity_id) values (p_actor, 'resend_comm', 'communication', p_id::text);
    return jsonb_build_object('ok', true, 'communication_id', v_id, 'status', (select status from flow.communications where id = v_id));
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- n8n sender: claim approved messages so two runs can never send the same one
create or replace function flow.comms_claim_to_send(p_limit int default 25) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_out jsonb;
begin
  with c as (
    select id from flow.communications where (status = 'approved' or (status = 'sending' and claimed_at < now() - interval '15 minutes'))
      and cardinality(to_addresses) > 0 order by created_at limit greatest(p_limit, 1) for update skip locked),
  u as (update flow.communications m set status = 'sending', claimed_at = now() from c where m.id = c.id
        returning m.id, m.comm_ref, m.to_addresses, m.cc_addresses, m.reply_to, m.subject, m.body_html, m.body_text, m.attachments, m.kind)
  select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) into v_out from u;
  return v_out;
end $$;
create or replace function flow.comm_mark_sent(p_id uuid, p_provider_id text default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare c flow.communications;
begin
  update flow.communications set status = 'sent', sent_at = now(), provider_message_id = p_provider_id, error = null where id = p_id and status in ('sending','approved') returning * into c;
  if not found then return jsonb_build_object('ok', false, 'error', 'message not found or not ready'); end if;
  if c.kind = 'po_send' and c.entity_id is not null then
    update flow.purchase_orders set po_status = 'sent', sent_at = coalesce(sent_at, now()), is_active = true, delivery_status = 'expected'
      where id = c.entity_id and origin = 'atam_flow' and po_status in ('approved','draft');
  end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function flow.comm_mark_failed(p_id uuid, p_error text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  update flow.communications set status = 'failed', error = left(p_error, 500) where id = p_id and status in ('sending','approved');
  perform flow.notify('email_failed', 'warning', 'An email failed to send', left(p_error, 300), 'communication', p_id);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Supplier discrepancy emails
-- ---------------------------------------------------------------------------
create or replace function flow.disc_required_by(p_orders jsonb) returns date language plpgsql stable set search_path = flow, public as $$
declare v_min date; v_buf int := coalesce((flow.setting('purchasing.options')->>'dispatch_buffer_days')::int, 2);
  v_def int := coalesce((flow.setting('comms.settings')->>'shortage_default_days')::int, 2);
begin
  select min((x->>'due_date')::date) into v_min from jsonb_array_elements(coalesce(p_orders, '[]'::jsonb)) x where x->>'due_date' is not null;
  if v_min is null then return current_date + v_def; end if;
  return least(current_date + 7, greatest(current_date + 1, v_min - v_buf));
end $$;

create or replace function flow.compose_supplier_discrepancy_comms(p_ids uuid[]) returns uuid[]
language plpgsql security definer set search_path = flow, public as $$
declare
  g record; d record; po flow.purchase_orders; s flow.suppliers; v_set jsonb := coalesce(flow.setting('comms.settings'), '{}'::jsonb);
  v_out uuid[] := '{}'; v_label text; v_intro text; v_ask text; v_blocks text := ''; v_hblocks text := ''; v_refs text; v_due date; v_req date; v_urgent boolean;
  v_qty_total int; v_txt text; v_html text; v_kind text; v_id uuid; v_ev jsonb; v_contact text; v_poref text; v_atts jsonb; v_hrefs text;
begin
  for g in select distinct sd.po_id, sd.disc_type from flow.supplier_discrepancies sd where sd.id = any (p_ids) loop
    select * into po from flow.purchase_orders where id = g.po_id;
    select * into s from flow.suppliers where id = po.supplier_ref_id;
    v_label := case g.disc_type when 'shortage' then 'Stock Shortage' when 'damaged' then 'Damaged Goods' when 'incorrect' then 'Incorrect Items Received' when 'overage' then 'Over-Delivery' else 'Stock Discrepancy' end;
    v_kind := case g.disc_type when 'shortage' then 'shortage' when 'damaged' then 'damage' when 'incorrect' then 'incorrect' when 'overage' then 'overage' else 'other' end;
    v_poref := coalesce(po.af_po_ref, po.po_number);
    v_blocks := ''; v_hblocks := ''; v_qty_total := 0; v_req := null; v_due := null; v_urgent := false; v_atts := '[]'::jsonb;
    select string_agg(distinct x->>'order_ref', ', ' order by x->>'order_ref'), min((x->>'due_date')::date)
      into v_refs, v_due from flow.supplier_discrepancies sd, jsonb_array_elements(sd.affected_orders) x where sd.id = any (p_ids) and sd.po_id = g.po_id and sd.disc_type = g.disc_type;
    for d in select sd.*, pl.product_name from flow.supplier_discrepancies sd join flow.po_lines pl on pl.id = sd.po_line_id
             where sd.id = any (p_ids) and sd.po_id = g.po_id and sd.disc_type = g.disc_type order by sd.sku loop
      v_blocks := v_blocks || format(E'SKU: %s\nProduct: %s\nColour: %s\nSize: %s\nOrdered: %s\nReceived: %s\n%s: %s\n\n', d.sku, coalesce(d.product_name, ''), coalesce(d.colour, ''),
        coalesce(d.size, ''), d.qty_ordered, d.qty_received, case g.disc_type when 'shortage' then 'Shortage' when 'damaged' then 'Damaged' when 'incorrect' then 'Incorrect' else 'Over-delivered' end, d.qty);
      v_hblocks := v_hblocks || format('<p><b>SKU:</b> %s<br><b>Product:</b> %s<br><b>Colour:</b> %s<br><b>Size:</b> %s<br><b>Ordered:</b> %s<br><b>Received:</b> %s<br><b>%s:</b> %s</p>',
        flow.html_escape(d.sku), flow.html_escape(d.product_name), flow.html_escape(d.colour), flow.html_escape(d.size), d.qty_ordered, d.qty_received,
        case g.disc_type when 'shortage' then 'Shortage' when 'damaged' then 'Damaged' when 'incorrect' then 'Incorrect' else 'Over-delivered' end, d.qty);
      v_qty_total := v_qty_total + d.qty;
      v_req := least(coalesce(v_req, d.required_by), coalesce(d.required_by, v_req));
      v_urgent := v_urgent or d.requested_action = 'urgent_replacement';
      v_atts := v_atts || coalesce(d.evidence, '[]'::jsonb);
    end loop;
    v_intro := case g.disc_type
      when 'shortage' then format('We have booked in delivery against PO %s and identified the following shortage:', v_poref)
      when 'damaged' then format('We have booked in delivery against PO %s and found damaged goods:', v_poref)
      when 'incorrect' then format('We have booked in delivery against PO %s and received incorrect items:', v_poref)
      when 'overage' then format('We have booked in delivery against PO %s and received more than ordered:', v_poref)
      else format('We have identified a discrepancy on PO %s:', v_poref) end;
    v_ask := case g.disc_type
      when 'shortage' then case when v_urgent then format(E'Please confirm urgently whether you can:\n1. Send the missing %s units by express delivery, or\n2. Issue a credit and confirm the earliest replacement date.', v_qty_total)
                                else format(E'Please confirm whether you can:\n1. Send the missing %s units, or\n2. Issue a credit and confirm the earliest replacement date.', v_qty_total) end
      when 'damaged' then E'Please confirm whether you can:\n1. Send replacements (urgently if possible), or\n2. Issue a credit.\nPhotos are linked below.'
      when 'incorrect' then E'Please confirm whether you can:\n1. Send the correct items and arrange collection of the incorrect ones, or\n2. Issue a credit.'
      when 'overage' then E'Please confirm whether you will invoice the extra units or arrange collection.'
      else 'Please investigate and confirm how you will resolve this.' end;
    v_contact := concat_ws(' / ', v_set->>'reply_to', v_set->>'phone');
    select string_agg(coalesce(a->>'name', 'evidence') || ': ' || (a->>'url'), E'\n') into v_hrefs from jsonb_array_elements(v_atts) a where a->>'url' is not null;
    v_txt := format(E'Hi %s,\n\n%s\n\n%s%s%sPlease respond by %s. Please reply to this email%s.\n\nRegards,\n%s',
      coalesce(s.contact_name, s.name), v_intro, v_blocks,
      case when v_refs is not null then format(E'This affects ATAM_FLOW orders %s%s.\n\n', v_refs, case when v_due is not null then ', which are due for customer dispatch on ' || to_char(v_due, 'FMDD FMMonth') else '' end) else '' end,
      v_ask || E'\n\n' || case when v_hrefs is not null then E'Evidence:\n' || v_hrefs || E'\n\n' else '' end,
      to_char(coalesce(v_req, current_date + 2), 'FMDay FMDD FMMonth'), case when v_contact <> '' then ' or contact ' || v_contact else '' end,
      coalesce(v_set->>'signature', 'ATAM FLOW Production Control'));
    v_html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.5"><p>Hi ' || flow.html_escape(coalesce(s.contact_name, s.name)) || ',</p><p>' || flow.html_escape(v_intro) || '</p>' || v_hblocks ||
      case when v_refs is not null then '<p>This affects ATAM_FLOW orders <b>' || flow.html_escape(v_refs) || '</b>' || case when v_due is not null then ', which are due for customer dispatch on <b>' || to_char(v_due, 'FMDD FMMonth') || '</b>' else '' end || '.</p>' else '' end ||
      '<p>' || replace(flow.html_escape(v_ask), E'\n', '<br>') || '</p>' || case when v_hrefs is not null then '<p>Evidence:<br>' || replace(flow.html_escape(v_hrefs), E'\n', '<br>') || '</p>' else '' end ||
      '<p>Please respond by <b>' || to_char(coalesce(v_req, current_date + 2), 'FMDay FMDD FMMonth') || '</b>. Please reply to this email' || case when v_contact <> '' then ' or contact ' || flow.html_escape(v_contact) else '' end ||
      '.</p><p>Regards,<br>' || flow.html_escape(coalesce(v_set->>'signature', 'ATAM FLOW Production Control')) || '</p></div>';
    v_id := flow.queue_comm(v_kind, array[s.email], v_label || ' - ATAM_FLOW PO ' || v_poref, v_txt, v_html, 'purchase_order', po.id, s.id, null, 'system', v_atts);
    update flow.supplier_discrepancies set communication_id = v_id, status = case when status = 'open' then 'awaiting_supplier' else status end
      where id = any (p_ids) and po_id = g.po_id and disc_type = g.disc_type;
    v_out := array_append(v_out, v_id);
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Goods-in. p_receipt: {delivery_ref, received_by, location, notes, evidence:[{url,name}],
--   lines:[{po_line_id, qty_received, qty_damaged, qty_incorrect, condition, batch_ref, notes, final (default true), evidence}]}
-- A final delivery that is short declares a shortage; final:false records a partial delivery with no complaint.
-- ---------------------------------------------------------------------------
create or replace function flow.book_in_goods(p_po uuid, p_receipt jsonb, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare
  po flow.purchase_orders; pl flow.po_lines; e jsonb; v_rc uuid; v_code text; v_out int; v_good int; v_dam int; v_inc int; v_short int; v_over int; v_final boolean; v_apply int;
  v_rl uuid; v_loc text := coalesce(nullif(p_receipt->>'location', ''), 'warehouse'); v_discs uuid[] := '{}'; v_id uuid; v_aff jsonb; v_due date; v_ev jsonb;
  v_t record; v_ref text; v_open int; v_any_issue boolean; v_any_recv boolean; v_new flow.af_po_status; v_comms uuid[]; v_affected_orders jsonb := '[]'::jsonb; v_res jsonb := '[]'::jsonb;
  v_urgent text; v_cond text;
begin
  begin
    select * into po from flow.purchase_orders where id = p_po;
    if not found then raise exception 'purchase order not found'; end if;
    if po.origin = 'atam_flow' and po.po_status not in ('sent','acknowledged','partially_received','short_shipped') then
      raise exception 'PO % is % and cannot receive goods', po.af_po_ref, po.po_status; end if;
    if p_receipt is null or jsonb_typeof(p_receipt->'lines') <> 'array' or jsonb_array_length(p_receipt->'lines') = 0 then raise exception 'no delivery lines supplied'; end if;
    if v_loc not in ('warehouse','producer') then raise exception 'location must be warehouse or producer'; end if;
    v_code := 'GR-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.goods_receipt_seq')::text, 5, '0');
    insert into flow.stock_receipts (receipt_code, po_id, supplier_id, delivery_ref, received_by, location, producer_id, notes, evidence)
    values (v_code, p_po, po.supplier_ref_id, p_receipt->>'delivery_ref', coalesce(p_receipt->>'received_by', p_actor), v_loc, po.deliver_to_producer_id, p_receipt->>'notes',
            coalesce(p_receipt->'evidence', '[]'::jsonb)) returning id into v_rc;

    for e in select * from jsonb_array_elements(p_receipt->'lines') loop
      select * into pl from flow.po_lines where id = (e->>'po_line_id')::uuid and po_id = p_po for update;
      if not found then raise exception 'line % is not on this purchase order', e->>'po_line_id'; end if;
      v_out := pl.qty_outstanding_eff;
      v_good := coalesce((e->>'qty_received')::int, 0); v_dam := coalesce((e->>'qty_damaged')::int, 0); v_inc := coalesce((e->>'qty_incorrect')::int, 0);
      if v_good < 0 or v_dam < 0 or v_inc < 0 then raise exception 'quantities cannot be negative'; end if;
      v_final := coalesce((e->>'final')::boolean, true);
      v_over := greatest(v_good + v_dam + v_inc - v_out, 0);
      v_short := case when v_final then greatest(v_out - v_good - v_dam - v_inc, 0) else 0 end;
      v_apply := least(v_good, pl.qty_replacement_due);
      v_cond := coalesce(nullif(e->>'condition', ''), case when v_dam > 0 and v_inc > 0 then 'mixed' when v_dam > 0 then 'damaged' when v_inc > 0 then 'incorrect' else 'good' end);
      v_ev := coalesce(e->'evidence', p_receipt->'evidence', '[]'::jsonb);
      insert into flow.stock_receipt_lines (receipt_id, po_line_id, sku, colour, size, qty_expected, qty_received, qty_damaged, qty_incorrect, qty_short, qty_over, condition, is_final, batch_ref, notes, evidence)
      values (v_rc, pl.id, pl.sku, pl.colour, pl.size, v_out, v_good, v_dam, v_inc, v_short, v_over, v_cond, v_final, e->>'batch_ref', e->>'notes', v_ev) returning id into v_rl;

      update flow.po_lines set qty_received_af = qty_received_af + v_good, qty_damaged = qty_damaged + v_dam, qty_incorrect = qty_incorrect + v_inc,
        qty_short = greatest(qty_short - v_apply, 0) + v_short, qty_replacement_due = qty_replacement_due - v_apply, received_date = current_date,
        discrepancy_status = case when v_short > 0 then 'short_shipped' when v_dam > 0 then 'damaged' when v_inc > 0 then 'incorrect' when v_over > 0 then 'overage' else discrepancy_status end
      where id = pl.id;

      if v_short > 0 or v_dam > 0 or v_inc > 0 or v_over > 0 then
        select coalesce(jsonb_agg(jsonb_build_object('order_id', o.id, 'order_ref', o.order_ref, 'due_date', o.due_date::date, 'qty', s.qty) order by o.due_date), '[]'::jsonb) into v_aff
          from flow.po_line_sources s join flow.order_lines l on l.id = s.order_line_id join flow.orders o on o.id = l.order_id where s.po_line_id = pl.id;
        if jsonb_array_length(v_aff) = 0 then
          select coalesce(jsonb_agg(jsonb_build_object('order_id', o.id, 'order_ref', o.order_ref, 'due_date', o.due_date::date, 'qty', a.qty) order by o.due_date), '[]'::jsonb) into v_aff
            from flow.allocations a join flow.orders o on o.id = a.order_id where a.po_line_id = pl.id and a.status = 'active';
        end if;
        select min((x->>'due_date')::date) into v_due from jsonb_array_elements(v_aff) x;
        v_urgent := case when v_due is not null and v_due - current_date <= 3 then 'urgent_replacement' else 'replacement' end;
        v_affected_orders := v_affected_orders || v_aff;
        for v_t in select * from (values ('shortage', v_short), ('damaged', v_dam), ('incorrect', v_inc), ('overage', v_over)) t(typ, q) where q > 0 loop
          insert into flow.supplier_discrepancies (disc_ref, po_id, po_line_id, receipt_line_id, supplier_id, disc_type, sku, colour, size, qty_ordered, qty_received, qty,
              requested_action, required_by, affected_orders, evidence, opened_by)
          values ('SD-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.supplier_disc_seq')::text, 5, '0'), p_po, pl.id, v_rl, po.supplier_ref_id, v_t.typ, pl.sku, pl.colour, pl.size,
              pl.qty_expected, pl.qty_received_af + v_good, v_t.q, case when v_t.typ = 'overage' then 'investigation' else v_urgent end, flow.disc_required_by(v_aff), v_aff, v_ev, p_actor)
          returning id into v_id;
          v_discs := array_append(v_discs, v_id);
        end loop;
      end if;
      v_res := v_res || jsonb_build_array(jsonb_build_object('po_line_id', pl.id, 'sku', pl.sku, 'expected', v_out, 'received', v_good, 'damaged', v_dam, 'incorrect', v_inc, 'short', v_short, 'over', v_over));
    end loop;

    -- PO header status
    select coalesce(sum(qty_outstanding_eff), 0), bool_or(qty_short > 0 or qty_damaged > 0 or qty_incorrect > 0), bool_or(qty_received_af > 0 or qty_received > 0)
      into v_open, v_any_issue, v_any_recv from flow.po_lines where po_id = p_po;
    v_new := case when po.origin <> 'atam_flow' then null
                  when v_open = 0 and v_any_issue then 'short_shipped'
                  when v_open = 0 then 'received'
                  when exists (select 1 from flow.po_lines where po_id = p_po and qty_short > 0) then 'short_shipped'
                  when v_any_recv then 'partially_received' else po.po_status end;
    update flow.purchase_orders set po_status = coalesce(v_new, po_status), is_active = (v_open > 0 and (po.origin = 'atam_flow' or is_active)),
      delivery_status = case when v_open = 0 then 'received'::flow.delivery_status else 'partially_received'::flow.delivery_status end,
      actual_delivery = case when v_open = 0 then current_date else actual_delivery end,
      receipt_status = case when v_open = 0 then 'complete' when v_any_recv then 'partial' else receipt_status end,
      qty_received = (select coalesce(sum(greatest(qty_received, qty_received_af)), 0) from flow.po_lines where po_id = p_po)
    where id = p_po;

    v_comms := case when array_length(v_discs, 1) > 0 then flow.compose_supplier_discrepancy_comms(v_discs) else '{}' end;
    if array_length(v_discs, 1) > 0 then
      perform flow.notify('supplier_discrepancy', 'critical', 'Goods-in discrepancy on ' || coalesce(po.af_po_ref, po.po_number),
        (select string_agg(sd.disc_type || ' ' || sd.qty || ' x ' || sd.sku, '; ') from flow.supplier_discrepancies sd where sd.id = any (v_discs)), 'purchase_order', p_po);
    end if;
    insert into flow.audit_log (actor, action, entity, entity_id, after) values (p_actor, 'book_in_goods', 'purchase_order', p_po::text, jsonb_build_object('receipt', v_code, 'discrepancies', coalesce(array_length(v_discs, 1), 0)));
    return jsonb_build_object('ok', true, 'receipt_code', v_code, 'po_status', (select po_status from flow.purchase_orders where id = p_po), 'lines', v_res,
      'discrepancies', (select coalesce(jsonb_agg(jsonb_build_object('id', sd.id, 'ref', sd.disc_ref, 'type', sd.disc_type, 'sku', sd.sku, 'qty', sd.qty, 'required_by', sd.required_by, 'requested_action', sd.requested_action)), '[]'::jsonb)
                        from flow.supplier_discrepancies sd where sd.id = any (v_discs)),
      'affected_orders', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(v_affected_orders) x),
      'communication_ids', to_jsonb(v_comms),
      'recalculate_allocation', true);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Resolve / escalate supplier discrepancies
-- ---------------------------------------------------------------------------
create or replace function flow.resolve_supplier_discrepancy(p_id uuid, p_resolution text, p_note text, p_actor text, p_replacement_date date default null) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare d flow.supplier_discrepancies; v_open int; v_issue boolean;
begin
  begin
    select * into d from flow.supplier_discrepancies where id = p_id;
    if not found then raise exception 'discrepancy not found'; end if;
    if d.status in ('resolved','cancelled','accepted') then raise exception 'discrepancy is already %', d.status; end if;
    if p_resolution not in ('replacement_promised','replacement_received','credit_issued','cancelled','accepted','manual') then raise exception 'unknown resolution %', p_resolution; end if;
    if coalesce(p_note, '') = '' then raise exception 'a resolution note is required'; end if;
    if p_resolution = 'replacement_promised' then
      update flow.po_lines set qty_replacement_due = qty_replacement_due + d.qty, replacement_expected_date = coalesce(p_replacement_date, replacement_expected_date),
        discrepancy_status = 'resolved' where id = d.po_line_id;
      update flow.purchase_orders set is_active = true, expected_date = coalesce(p_replacement_date::timestamptz, expected_date),
        po_status = case when origin = 'atam_flow' and po_status in ('short_shipped','received') then 'partially_received'::flow.af_po_status else po_status end where id = d.po_id;
      update flow.supplier_discrepancies set status = 'awaiting_supplier', resolution = p_resolution, resolution_note = p_note, updated_at = now() where id = p_id;
    else
      update flow.supplier_discrepancies set status = case p_resolution when 'cancelled' then 'cancelled' when 'accepted' then 'accepted' else 'resolved' end,
        resolution = p_resolution, resolution_note = p_note, resolved_by = p_actor, resolved_at = now() where id = p_id;
      update flow.po_lines set discrepancy_status = 'resolved' where id = d.po_line_id
        and not exists (select 1 from flow.supplier_discrepancies x where x.po_line_id = d.po_line_id and x.id <> p_id and x.status in ('open','awaiting_supplier'));
    end if;
    select coalesce(sum(qty_outstanding_eff), 0) into v_open from flow.po_lines where po_id = d.po_id;
    select exists (select 1 from flow.supplier_discrepancies where po_id = d.po_id and status in ('open','awaiting_supplier')) into v_issue;
    update flow.purchase_orders set po_status = 'closed', is_active = false where id = d.po_id and origin = 'atam_flow' and v_open = 0 and not v_issue and po_status in ('received','short_shipped');
    insert into flow.audit_log (actor, action, entity, entity_id, after, reason) values (p_actor, 'resolve_supplier_discrepancy', 'supplier_discrepancy', p_id::text, jsonb_build_object('resolution', p_resolution), p_note);
    return jsonb_build_object('ok', true, 'recalculate_allocation', true, 'po_status', (select po_status from flow.purchase_orders where id = d.po_id));
  exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end $$;

-- Chase unresolved discrepancies once their required-by date has passed (idempotent: one escalation each)
create or replace function flow.supplier_discrepancy_check() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare d record; v_id uuid; v_n int := 0; v_list jsonb := '[]'::jsonb; v_set jsonb := coalesce(flow.setting('comms.settings'), '{}'::jsonb); v_txt text; s flow.suppliers;
begin
  for d in select sd.*, coalesce(p.af_po_ref, p.po_number) as poref, pl.product_name from flow.supplier_discrepancies sd join flow.purchase_orders p on p.id = sd.po_id
           join flow.po_lines pl on pl.id = sd.po_line_id
           where sd.status in ('open','awaiting_supplier') and sd.required_by < current_date and sd.escalated_at is null order by sd.required_by loop
    select * into s from flow.suppliers where id = d.supplier_id;
    v_txt := format(E'Hi %s,\n\nWe have not yet had a resolution to the %s reported on PO %s, and our requested date of %s has now passed.\n\nSKU: %s\nProduct: %s\nQuantity affected: %s\nReference: %s\n\nThis is holding up customer orders. Please reply today with a firm resolution (replacement with a delivery date, or a credit).\n\nRegards,\n%s',
      coalesce(s.contact_name, s.name), d.disc_type, d.poref, to_char(d.required_by, 'FMDD FMMonth'), d.sku, coalesce(d.product_name, ''), d.qty, d.disc_ref, coalesce(v_set->>'signature', 'ATAM FLOW Production Control'));
    v_id := flow.queue_comm('escalation', array[s.email], 'URGENT - Unresolved discrepancy ' || d.disc_ref || ' on PO ' || d.poref, v_txt, null, 'purchase_order', d.po_id, s.id, null, 'system');
    update flow.supplier_discrepancies set escalated_at = now() where id = d.id;
    perform flow.notify('discrepancy_overdue', 'critical', 'Supplier has not resolved ' || d.disc_ref, d.sku || ' x ' || d.qty || ' on PO ' || d.poref || ', due ' || d.required_by, 'supplier_discrepancy', d.id);
    v_n := v_n + 1;
    v_list := v_list || jsonb_build_array(jsonb_build_object('disc_ref', d.disc_ref, 'po', d.poref, 'sku', d.sku, 'qty', d.qty, 'required_by', d.required_by, 'communication_id', v_id));
  end loop;
  return jsonb_build_object('ok', true, 'escalated', v_n, 'items', v_list);
end $$;

-- ---------------------------------------------------------------------------
-- Rewire the existing consumers to the effective figures
-- ---------------------------------------------------------------------------
create or replace function flow.guard_allocation() returns trigger language plpgsql set search_path = flow, public as $$
declare v_cap int; v_used int;
begin
  if new.status <> 'active' then return new; end if;
  if new.source = 'on_hand' then
    select greatest(qty_on_hand + qty_pending_receipt, 0) into v_cap from flow.stock_items where id = new.stock_item_id for update;
    select coalesce(sum(qty), 0) into v_used from flow.allocations
      where stock_item_id = new.stock_item_id and source = 'on_hand' and status = 'active' and id <> new.id;
    if v_used + new.qty > v_cap then
      raise exception 'over-allocation: stock % has % on hand, % already reserved, % requested', new.stock_item_id, v_cap, v_used, new.qty using errcode = 'check_violation';
    end if;
  else
    select qty_outstanding_eff into v_cap from flow.po_lines where id = new.po_line_id for update;
    select coalesce(sum(qty), 0) into v_used from flow.allocations where po_line_id = new.po_line_id and status = 'active' and id <> new.id;
    if v_used + new.qty > coalesce(v_cap, 0) then
      raise exception 'over-allocation: PO line % has % outstanding, % already reserved, % requested', new.po_line_id, v_cap, v_used, new.qty using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

create or replace view flow.v_stock_position with (security_invoker = true) as
select s.id as stock_item_id, s.sku, s.product_name, s.garment_type, s.colour, s.size, s.storage_location,
       s.min_threshold, s.reorder_qty, s.is_placeholder,
       s.qty_on_hand + s.qty_pending_receipt                  as qty_on_hand,
       coalesce(r.reserved, 0)                                 as qty_reserved,
       greatest(s.qty_on_hand + s.qty_pending_receipt - coalesce(r.reserved, 0), 0) as qty_available,
       coalesce(i.incoming, 0)                                 as qty_incoming,
       coalesce(i.incoming, 0) - coalesce(ri.reserved_incoming, 0) as qty_incoming_free,
       i.next_expected,
       (s.min_threshold is not null and s.qty_on_hand + s.qty_pending_receipt <= s.min_threshold)  as is_low_stock,
       (s.qty_on_hand + s.qty_pending_receipt <= 0)            as is_out_of_stock,
       s.last_synced_at,
       s.qty_pending_receipt, s.qty_on_hand                    as qty_on_hand_deconetwork
from flow.stock_items s
left join (select stock_item_id, sum(qty)::int as reserved from flow.allocations where status = 'active' and source = 'on_hand' group by 1) r on r.stock_item_id = s.id
left join (select l.sku, sum(l.qty_outstanding_eff)::int as incoming, min(coalesce(l.replacement_expected_date::timestamptz, l.expected_date::timestamptz, p.expected_date)) as next_expected
           from flow.po_lines l join flow.purchase_orders p on p.id = l.po_id and p.is_active where l.qty_outstanding_eff > 0 group by 1) i on i.sku = s.sku
left join (select stock_item_id, sum(qty)::int as reserved_incoming from flow.allocations where status = 'active' and source = 'incoming_po' group by 1) ri on ri.stock_item_id = s.id;

create or replace function flow.allocation_input() returns jsonb
language sql stable security definer set search_path = flow, public as $$
  with demand as (
    select o.* from flow.orders o
    join flow.deco_status_map m on m.code = o.deco_status and m.maps_to = 'awaiting_stock'
    where o.is_active and not o.stock_secured and o.order_status in ('awaiting_stock','stock_allocated')
  ), dl as (
    select l.*, greatest(l.qty_required - l.qty_produced, 0) as need from flow.order_lines l
    join demand d on d.id = l.order_id
    where l.is_active and l.sku is not null and l.qty_required - l.qty_produced > 0
  ), skus as (select distinct sku from dl)
  select jsonb_build_object(
    'now', now(), 'today', (now() at time zone 'Europe/London')::date,
    'settings', jsonb_build_object(
      'weights', coalesce((select value from flow.flow_settings where key = 'allocation.weights'), '{}'::jsonb),
      'thresholds', coalesce((select value from flow.flow_settings where key = 'allocation.thresholds'), '{}'::jsonb)),
    'active_methods', coalesce((select jsonb_agg(distinct method_code) from flow.machines where is_active), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'order_ref', d.order_ref, 'customer', d.customer_name,
        'due_date', (d.due_date at time zone 'Europe/London')::date, 'order_date', d.order_date, 'priority', d.priority, 'is_vip', d.is_vip,
        'order_value', d.order_value, 'methods', d.decoration_methods, 'deco_status', d.deco_status,
        'lines', (select jsonb_agg(jsonb_build_object('id', x.id, 'sku', x.sku, 'need', x.need, 'product_name', x.product_name, 'colour', x.colour,
                  'size', x.size, 'stitches_per_piece', x.stitches_per_piece) order by x.sku, x.size) from dl x where x.order_id = d.id))
        order by d.order_ref) from demand d where exists (select 1 from dl where dl.order_id = d.id)), '[]'::jsonb),
    'stock', coalesce((select jsonb_agg(jsonb_build_object('sku', s.sku, 'on_hand', greatest(s.qty_on_hand + s.qty_pending_receipt, 0))) from flow.stock_items s where s.sku in (select sku from skus)), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(jsonb_build_object('po_line_id', pl.id, 'po_number', coalesce(p.af_po_ref, p.po_number), 'supplier', p.supplier, 'sku', pl.sku,
        'outstanding', pl.qty_outstanding_eff, 'expected_date', coalesce(pl.replacement_expected_date, pl.expected_date, (p.expected_date at time zone 'Europe/London')::date)))
        from flow.po_lines pl join flow.purchase_orders p on p.id = pl.po_id and p.is_active where pl.qty_outstanding_eff > 0 and pl.sku in (select sku from skus)), '[]'::jsonb),
    'fixed_allocations', coalesce((select jsonb_agg(jsonb_build_object('order_line_id', a.order_line_id, 'sku', s.sku, 'source', a.source,
        'po_line_id', a.po_line_id, 'qty', a.qty)) from flow.allocations a join flow.stock_items s on s.id = a.stock_item_id
        where a.is_manual and a.status = 'active'), '[]'::jsonb)
  )
$$;

create or replace view flow.v_shortages with (security_invoker = true) as
select l.sku, max(l.product_name) as product_name, max(l.colour) as colour, max(l.size) as size,
       sum(greatest(l.qty_required - l.qty_produced, 0))::int as units_demanded,
       coalesce(sum(a.reserved), 0)::int as units_reserved,
       (sum(greatest(l.qty_required - l.qty_produced, 0)) - coalesce(sum(a.reserved), 0))::int as units_short,
       count(distinct o.id) as orders_affected, min(o.due_date)::date as earliest_due, array_agg(distinct o.order_ref order by o.order_ref) as order_refs,
       max(s.qty_on_hand + s.qty_pending_receipt) as on_hand,
       (select coalesce(sum(pl.qty_outstanding_eff), 0) from flow.po_lines pl join flow.purchase_orders p on p.id = pl.po_id and p.is_active where pl.sku = l.sku)::int as on_order
from flow.order_lines l
join flow.orders o on o.id = l.order_id and o.is_active and not o.stock_secured
join flow.deco_status_map m on m.code = o.deco_status and m.maps_to = 'awaiting_stock'
left join flow.stock_items s on s.sku = l.sku
left join lateral (select sum(a1.qty) as reserved from flow.allocations a1 where a1.order_line_id = l.id and a1.status = 'active') a on true
where l.is_active and l.sku is not null and l.qty_required - l.qty_produced > 0
group by l.sku
having sum(greatest(l.qty_required - l.qty_produced, 0)) - coalesce(sum(a.reserved), 0) > 0;

create or replace view flow.v_overdue_pos with (security_invoker = true) as
select p.id as po_id, coalesce(p.af_po_ref, p.po_number) as po_number, p.supplier, p.expected_date::date as expected_date,
       (current_date - p.expected_date::date) as days_overdue,
       case when current_date - p.expected_date::date > 30 then 'over a month late: probably received but not booked in, or lost'
            when current_date - p.expected_date::date > 14 then '2-4 weeks late: chase the supplier'
            else 'recently late' end as suggestion,
       (select count(*) from flow.po_lines x where x.po_id = p.id and x.qty_outstanding_eff > 0)::int as lines,
       (select coalesce(sum(x.qty_outstanding_eff), 0) from flow.po_lines x where x.po_id = p.id)::int as units_outstanding,
       (select coalesce(sum(al.qty), 0) from flow.allocations al join flow.po_lines x on x.id = al.po_line_id where x.po_id = p.id and al.status = 'active')::int as units_promised_to_orders,
       (select array_agg(distinct o.order_ref order by o.order_ref) from flow.allocations al join flow.po_lines x on x.id = al.po_line_id
         join flow.orders o on o.id = al.order_id where x.po_id = p.id and al.status = 'active') as orders_waiting
from flow.purchase_orders p
where p.is_active and p.expected_date::date < current_date
  and exists (select 1 from flow.po_lines x where x.po_id = p.id and x.qty_outstanding_eff > 0);

-- ---------------------------------------------------------------------------
-- Dashboard read models
-- ---------------------------------------------------------------------------
create or replace view flow.v_purchase_orders_live with (security_invoker = true) as
select p.id as po_id, coalesce(p.af_po_ref, p.po_number) as po_ref, p.origin, p.po_status, p.delivery_status, p.supplier, p.supplier_ref_id, p.po_date, p.required_by,
       p.expected_date::date as expected_date, p.actual_delivery, p.currency, p.subtotal, p.delivery_cost, p.tax, p.total_cost, p.payment_status, p.invoice_ref,
       p.created_by, p.approved_by, p.deliver_to, t.lines, t.units_ordered, t.units_received, t.units_outstanding, t.units_short, t.units_damaged,
       (select count(*) from flow.supplier_discrepancies d where d.po_id = p.id and d.status in ('open','awaiting_supplier')) as open_discrepancies,
       (p.is_active and p.expected_date::date < current_date and t.units_outstanding > 0) as is_late,
       greatest(current_date - p.expected_date::date, 0) as days_late,
       (select array_agg(distinct o.order_ref order by o.order_ref) from flow.po_line_sources s join flow.po_lines x on x.id = s.po_line_id join flow.order_lines l on l.id = s.order_line_id
         join flow.orders o on o.id = l.order_id where x.po_id = p.id) as source_orders
from flow.purchase_orders p
left join lateral (select count(*)::int lines, sum(qty_expected)::int units_ordered, sum(greatest(qty_received, qty_received_af))::int units_received,
                          sum(qty_outstanding_eff)::int units_outstanding, sum(qty_short)::int units_short, sum(qty_damaged + qty_incorrect)::int units_damaged
                   from flow.po_lines where po_id = p.id) t on true
where p.is_active or p.origin = 'atam_flow' or p.date_raised > now() - interval '60 days';

create or replace view flow.v_supplier_discrepancies_open with (security_invoker = true) as
select d.id, d.disc_ref, d.disc_type, d.status, d.sku, d.colour, d.size, d.qty_ordered, d.qty_received, d.qty, d.requested_action, d.required_by,
       (d.required_by < current_date) as is_overdue, (current_date - d.opened_at::date) as days_open,
       coalesce(p.af_po_ref, p.po_number) as po_ref, p.supplier, d.affected_orders, d.communication_id, c.status as email_status, d.escalated_at
from flow.supplier_discrepancies d join flow.purchase_orders p on p.id = d.po_id left join flow.communications c on c.id = d.communication_id
where d.status in ('open','awaiting_supplier');

create or replace view flow.v_communications_queue with (security_invoker = true) as
select c.id, c.comm_ref, c.kind, c.status, c.to_addresses, c.subject, c.requires_review, c.created_at, c.approved_by, c.sent_at, c.error, c.entity_type, c.entity_id,
       s.name as supplier_name, c.resend_of
from flow.communications c left join flow.suppliers s on s.id = c.supplier_id
where c.status in ('draft','pending_review','approved','sending','failed') or c.created_at > now() - interval '30 days';

-- Trace every received unit: receipt -> PO -> supplier -> customer order -> producer movement
create or replace view flow.v_unit_trace with (security_invoker = true) as
select r.receipt_code, r.received_at, rl.sku, rl.colour, rl.size, rl.qty_received, coalesce(p.af_po_ref, p.po_number) as po_ref, p.supplier,
       o.order_ref, o.customer_name, s.qty as qty_for_order, mv.movement_code, mv.status as movement_status, pr.name as producer_name
from flow.stock_receipt_lines rl
join flow.stock_receipts r on r.id = rl.receipt_id
join flow.purchase_orders p on p.id = r.po_id
left join flow.po_line_sources s on s.po_line_id = rl.po_line_id
left join flow.order_lines l on l.id = s.order_line_id
left join flow.orders o on o.id = l.order_id
left join lateral (select m.movement_code, m.status, m.producer_id from flow.tp_movement_items i join flow.tp_movements m on m.id = i.movement_id
                   where i.order_line_id = l.id and m.status <> 'cancelled' order by m.created_at desc limit 1) mv on true
left join flow.producers pr on pr.id = mv.producer_id;

-- ---------------------------------------------------------------------------
-- n8n wrappers + permissions
-- ---------------------------------------------------------------------------
create or replace function public.flow_po_requirements(p_order_ids uuid[] default null) returns jsonb
language sql security definer set search_path = flow, public as $$
  select jsonb_build_object('ok', true, 'lines', coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb)) from flow.po_requirements(p_order_ids) r where r.qty_needed > 0 $$;
create or replace function public.flow_create_purchase_order(p_supplier uuid, p_lines jsonb, p_actor text, p_opts jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.create_purchase_order(p_supplier, p_lines, p_actor, p_opts) $$;
create or replace function public.flow_create_po_for_orders(p_supplier uuid, p_order_ids uuid[], p_actor text, p_opts jsonb default '{}'::jsonb) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.create_po_for_orders(p_supplier, p_order_ids, p_actor, p_opts) $$;
create or replace function public.flow_approve_purchase_order(p_po uuid, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.approve_purchase_order(p_po, p_actor) $$;
create or replace function public.flow_send_purchase_order(p_po uuid, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.send_purchase_order(p_po, p_actor) $$;
create or replace function public.flow_acknowledge_purchase_order(p_po uuid, p_expected_delivery date, p_supplier_ref text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.acknowledge_purchase_order(p_po, p_expected_delivery, p_supplier_ref, p_actor) $$;
create or replace function public.flow_cancel_purchase_order(p_po uuid, p_reason text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.cancel_purchase_order(p_po, p_reason, p_actor) $$;
create or replace function public.flow_book_in_goods(p_po uuid, p_receipt jsonb, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.book_in_goods(p_po, p_receipt, p_actor) $$;
create or replace function public.flow_resolve_supplier_discrepancy(p_id uuid, p_resolution text, p_note text, p_actor text, p_replacement_date date default null) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.resolve_supplier_discrepancy(p_id, p_resolution, p_note, p_actor, p_replacement_date) $$;
create or replace function public.flow_supplier_discrepancy_check() returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.supplier_discrepancy_check() $$;
create or replace function public.flow_comm_edit(p_id uuid, p_subject text, p_body text, p_to text[], p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comm_edit(p_id, p_subject, p_body, p_to, p_actor) $$;
create or replace function public.flow_comm_approve(p_id uuid, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comm_approve(p_id, p_actor) $$;
create or replace function public.flow_comm_cancel(p_id uuid, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comm_cancel(p_id, p_actor) $$;
create or replace function public.flow_comm_resend(p_id uuid, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comm_resend(p_id, p_actor) $$;
create or replace function public.flow_comms_claim_to_send(p_limit int default 25) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comms_claim_to_send(p_limit) $$;
create or replace function public.flow_comm_mark_sent(p_id uuid, p_provider_id text default null) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comm_mark_sent(p_id, p_provider_id) $$;
create or replace function public.flow_comm_mark_failed(p_id uuid, p_error text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.comm_mark_failed(p_id, p_error) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'flow.setting(text)', 'flow.notify(text,text,text,text,text,uuid)', 'flow.queue_comm(text,text[],text,text,text,text,uuid,uuid,uuid,text,jsonb)',
    'flow.po_requirements(uuid[])', 'flow.create_purchase_order(uuid,jsonb,text,jsonb)', 'flow.create_po_for_orders(uuid,uuid[],text,jsonb)',
    'flow.approve_purchase_order(uuid,text)', 'flow.send_purchase_order(uuid,text)', 'flow.acknowledge_purchase_order(uuid,date,text,text)',
    'flow.cancel_purchase_order(uuid,text,text)', 'flow.comm_edit(uuid,text,text,text[],text)', 'flow.comm_approve(uuid,text)', 'flow.comm_cancel(uuid,text)',
    'flow.comm_resend(uuid,text)', 'flow.comms_claim_to_send(int)', 'flow.comm_mark_sent(uuid,text)', 'flow.comm_mark_failed(uuid,text)',
    'flow.disc_required_by(jsonb)', 'flow.compose_supplier_discrepancy_comms(uuid[])', 'flow.book_in_goods(uuid,jsonb,text)',
    'flow.resolve_supplier_discrepancy(uuid,text,text,text,date)', 'flow.supplier_discrepancy_check()',
    'public.flow_po_requirements(uuid[])', 'public.flow_create_purchase_order(uuid,jsonb,text,jsonb)', 'public.flow_create_po_for_orders(uuid,uuid[],text,jsonb)',
    'public.flow_approve_purchase_order(uuid,text)', 'public.flow_send_purchase_order(uuid,text)', 'public.flow_acknowledge_purchase_order(uuid,date,text,text)',
    'public.flow_cancel_purchase_order(uuid,text,text)', 'public.flow_book_in_goods(uuid,jsonb,text)', 'public.flow_resolve_supplier_discrepancy(uuid,text,text,text,date)',
    'public.flow_supplier_discrepancy_check()', 'public.flow_comm_edit(uuid,text,text,text[],text)', 'public.flow_comm_approve(uuid,text)', 'public.flow_comm_cancel(uuid,text)',
    'public.flow_comm_resend(uuid,text)', 'public.flow_comms_claim_to_send(int)', 'public.flow_comm_mark_sent(uuid,text)', 'public.flow_comm_mark_failed(uuid,text)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
grant select on flow.v_purchase_orders_live, flow.v_supplier_discrepancies_open, flow.v_communications_queue, flow.v_unit_trace to authenticated;
