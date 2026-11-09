-- Purchasing controls: approval rules, invoice matching, scheduled chasing.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.suppliers (code, name, email, lead_time_days) values ('PCS', 'Controls Supplier', 'pcs@example.test', 3);
select id as sup from flow.suppliers where code = 'PCS' \gset
insert into flow.purchase_orders (deco_po_id, po_number, af_po_ref, origin, supplier, supplier_ref_id, po_status, created_by, total_cost, delivery_cost, expected_date) values
  (-970001, 'PCS-1', 'AF-PO-PC1', 'atam_flow', 'Controls Supplier', :'sup', 'draft', 'creator', 800, 10, current_date - 5),
  (-970002, 'PCS-2', 'AF-PO-PC2', 'atam_flow', 'Controls Supplier', :'sup', 'draft', 'creator', 100, 0, current_date + 5);
select id as po1 from flow.purchase_orders where af_po_ref = 'AF-PO-PC1' \gset
select id as po2 from flow.purchase_orders where af_po_ref = 'AF-PO-PC2' \gset
insert into flow.po_lines (po_id, line_no, sku, product_name, qty_expected, unit_cost, qty_received) values
  (:'po1', 1, 'PCS-A', 'A', 100, 8, 0), (:'po2', 1, 'PCS-B', 'B', 10, 10, 0);

-- 1. approval rules
select pg_temp.assert(not (flow.po_approve_checked(:'po1', 'someone', 'manager', null)->>'ok')::bool and (flow.po_approve_checked(:'po1', 'someone', 'manager', null)->>'error') like '%needs an admin%', 'a PO over the limit needs an admin');
select pg_temp.assert(not (flow.po_approve_checked(:'po2', 'creator', 'manager', null)->>'ok')::bool, 'cannot approve your own PO as a manager');
select pg_temp.assert(not (flow.po_approve_checked(:'po2', 'creator', 'admin', null)->>'ok')::bool, 'an admin approving their own PO needs a reason');
select pg_temp.assert((flow.po_approve_checked(:'po2', 'other', 'manager', null)->>'ok')::bool, 'another manager can approve a small PO');
select pg_temp.assert((select po_status from flow.purchase_orders where id = :'po2') = 'approved', 'PO approved');
select pg_temp.assert((flow.po_approve_checked(:'po1', 'creator', 'admin', 'Supplier deadline, no one else free')->>'ok')::bool, 'admin can approve own large PO with a reason');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'po_self_approval'), 'self approval is audited');

-- 2. invoice matching
select pg_temp.assert(not (flow.po_invoice_record(:'po1', '', null, 100, null, null, 'ap')->>'ok')::bool, 'invoice number required');
select pg_temp.assert((flow.po_invoice_record(:'po1', 'INV-1', current_date, 900, null, null, 'ap')->>'match_status') = 'awaiting_goods', 'nothing received yet: waiting for goods');
update flow.po_lines set qty_received = 100 where po_id = :'po1';
select pg_temp.assert((select match_status from flow.v_po_invoice_match where invoice_ref = 'INV-1') = 'over_billed', 'invoice higher than delivered value is over-billed');
select pg_temp.assert((select variance from flow.v_po_invoice_match where invoice_ref = 'INV-1') = 90, 'variance is invoice minus (received value plus delivery)');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.exc_detect_invoices()) x where x->>'type' = 'po_invoice_mismatch' and x->>'description' like '%INV-1%'), 'detector flags the mismatch');
select pg_temp.assert((flow.po_invoice_record(:'po1', 'INV-2', current_date, 811, null, null, 'ap')->>'match_status') = 'matched', 'within tolerance matches');
select pg_temp.assert(not (flow.po_invoice_record(:'po1', 'INV-2', current_date, 811, null, null, 'ap')->>'ok')::bool, 'duplicate invoice number refused');
select id as inv1 from flow.po_invoices where invoice_ref = 'INV-1' \gset
select pg_temp.assert(not (flow.po_invoice_resolve(:'inv1', 'accept', 'Agreed with supplier', false, 'ap')->>'ok')::bool, 'only a senior can accept a mismatch');
select pg_temp.assert(not (flow.po_invoice_resolve(:'inv1', 'accept', '', true, 'mgr')->>'ok')::bool, 'a reason is needed');
select pg_temp.assert((flow.po_invoice_resolve(:'inv1', 'accept', 'Extra carriage agreed by phone', true, 'mgr')->>'ok')::bool, 'senior accepts with a reason');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.exc_detect_invoices()) x where x->>'description' like '%INV-1%'), 'accepted invoice no longer flagged');

-- 3. scheduled chasing
select pg_temp.assert((flow.po_chase_scheduled('sys')->>'enabled')::bool = false, 'scheduled chasing is off by default');
update flow.flow_settings set value = value || '{"chase_enabled": true}'::jsonb where key = 'purchasing.rules';
update flow.purchase_orders set po_status = 'sent', sent_at = now() - interval '10 days', is_active = true where id = :'po1';
select flow.po_chase_scheduled('sys') as c1 \gset
select pg_temp.assert((:'c1'::jsonb->>'drafted')::int >= 1, 'a late PO gets a chase draft');
select pg_temp.assert(exists (select 1 from flow.communications where entity_id = :'po1' and subject like 'Chase:%' and status in ('draft', 'pending_review')), 'the chase waits for review and is not sent');
select pg_temp.assert((flow.po_chase_scheduled('sys')->>'drafted')::int = 0, 'the same PO is not chased again inside the repeat window');
update flow.flow_settings set value = value || '{"chase_enabled": false}'::jsonb where key = 'purchasing.rules';
\echo purchasing_controls_test OK
