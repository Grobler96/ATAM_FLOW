-- Purchasing lifecycle: requirements -> PO -> send -> goods-in (partial, short, damaged) -> email -> resolution. Runs after all migrations.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

insert into flow.suppliers (code, name, contact_name, email, lead_time_days, delivery_cost, free_delivery_over, min_order_value)
  values ('RALA', 'Ralawise Test', 'Pat', 'orders@ralawise.test', 3, 7.50, 500, 50),
         ('NOMAIL', 'No Email Ltd', null, null, 2, 0, null, null);
select id as sup from flow.suppliers where code = 'RALA' \gset
select id as sup2 from flow.suppliers where code = 'NOMAIL' \gset
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand) values ('PU-A', 'Polo', 'Navy', 'M', 0), ('PU-B', 'Hoodie', 'Black', 'L', 0);
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_date, order_status, deco_status, stock_secured, total_units) values
  ('P1','#P1','Alpha FC','2026-11-20 12:00+00','2026-11-01','awaiting_stock',9,false,30),
  ('P2','#P2','Beta Ltd','2026-11-24 12:00+00','2026-11-02','awaiting_stock',9,false,20);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select v.wi, o.id, v.sku, v.c, v.s, v.pn, v.q, '{embroidery}'
from (values ('PW1','P1','PU-A','Navy','M','Polo',20), ('PW2','P2','PU-A','Navy','M','Polo',10), ('PW3','P2','PU-B','Black','L','Hoodie',10)) v(wi, oid, sku, c, s, pn, q)
join flow.orders o on o.deco_order_id = v.oid;
select array_agg(id) as oids from flow.orders where deco_order_id in ('P1','P2') \gset

-- requirements consolidate nothing yet, just report need per line
select pg_temp.assert((select count(*) from flow.po_requirements(:'oids'::uuid[]) where qty_needed > 0) = 3, 'three order lines need stock');

-- ---- create a PO: identical SKUs merge, sources kept ----
create temp table r (k text primary key, j jsonb);
insert into r select 'po', flow.create_po_for_orders(:'sup', :'oids'::uuid[], 'tester', jsonb_build_object('required_by', '2026-11-15', 'notes', 'test'));
select pg_temp.assert((select (j->>'ok')::bool and j->>'af_po_ref' ~ '^AF-PO-[0-9]+$' and (j->>'lines')::int = 2 from r where k='po'), 'PO created with 2 consolidated lines: ' || (select j::text from r where k='po'));
select (j->>'po_id')::uuid as po, j->>'af_po_ref' as poref from r where k = 'po' \gset
select pg_temp.assert((select qty_expected from flow.po_lines where po_id = :'po' and sku = 'PU-A') = 30, 'PU-A merged 20+10');
select pg_temp.assert((select count(*) from flow.po_line_sources) = 3, 'each source order line kept');
select pg_temp.assert((select count(*) from flow.po_requirements(:'oids'::uuid[]) where qty_needed > 0) = 0, 'requirement now covered by the draft PO');
insert into r select 'again', flow.create_po_for_orders(:'sup', :'oids'::uuid[], 'tester');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='again'), 'cannot order the same need twice');

-- no cost -> cannot approve; add costs
insert into r select 'appr0', flow.approve_purchase_order(:'po', 'tester');
select pg_temp.assert((select not (j->>'ok')::bool and j->>'error' like '%unit cost%' from r where k='appr0'), 'approval needs costs');
update flow.po_lines set unit_cost = case sku when 'PU-A' then 5 else 20 end where po_id = :'po';
update flow.purchase_orders set subtotal = 350, tax = 71.5, total_cost = 429 where id = :'po';
insert into r select 'send0', flow.send_purchase_order(:'po', 'tester');
select pg_temp.assert((select not (j->>'ok')::bool from r where k='send0'), 'cannot send before approval');
insert into r select 'appr', flow.approve_purchase_order(:'po', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k='appr'), 'approved');
insert into r select 'send', flow.send_purchase_order(:'po', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'pending_review' from r where k='send'), 'PO email waits for review by default');
select (j->>'communication_id')::uuid as c1 from r where k = 'send' \gset
select pg_temp.assert((select subject like 'Purchase Order AF-PO-%' and body_text like '%PU-A%' and to_addresses = '{orders@ralawise.test}' from flow.communications where id = :'c1'), 'PO email content and recipient');
select pg_temp.assert((select po_status::text from flow.purchase_orders where id = :'po') = 'approved', 'PO not marked sent until the email really goes');
select pg_temp.assert((flow.comm_edit(:'c1', null, 'Edited body', null, 'tester')->>'ok')::bool, 'edit accepted');
select pg_temp.assert((select body_text = 'Edited body' from flow.communications where id = :'c1'), 'message can be edited before sending');
select pg_temp.assert((select (flow.comm_approve(:'c1', 'tester')->>'ok')::bool), 'message approved');
select pg_temp.assert((select jsonb_array_length(flow.comms_claim_to_send(10))) = 1, 'sender claims the approved message');
select pg_temp.assert((select jsonb_array_length(flow.comms_claim_to_send(10))) = 0, 'a claimed message cannot be claimed twice');
select pg_temp.assert((select (flow.comm_mark_sent(:'c1', 'graph-1')->>'ok')::bool), 'marked sent');
select pg_temp.assert((select po_status::text from flow.purchase_orders where id = :'po') = 'sent', 'PO is now sent');
select pg_temp.assert(not (select (flow.comm_cancel(:'c1','tester')->>'ok')::bool), 'sent mail cannot be cancelled');
select pg_temp.assert((flow.acknowledge_purchase_order(:'po', '2026-11-12', 'RW-77', 'tester')->>'ok')::bool, 'acknowledge accepted');
select pg_temp.assert((select po_status::text from flow.purchase_orders where id = :'po') = 'acknowledged', 'acknowledged');

-- ---- goods-in 1: partial delivery (not final) -> no complaint ----
select id as la from flow.po_lines where po_id = :'po' and sku = 'PU-A' \gset
select id as lb from flow.po_lines where po_id = :'po' and sku = 'PU-B' \gset
insert into r select 'g1', flow.book_in_goods(:'po', jsonb_build_object('delivery_ref', 'DEL-1', 'received_by', 'op1',
  'lines', jsonb_build_array(jsonb_build_object('po_line_id', :'la', 'qty_received', 20, 'final', false))), 'op1');
select pg_temp.assert((select (j->>'ok')::bool and j->>'po_status' = 'partially_received' and jsonb_array_length(j->'discrepancies') = 0 from r where k='g1'), 'partial delivery: no discrepancy: ' || (select j::text from r where k='g1'));
select pg_temp.assert((select qty_pending_receipt from flow.stock_items where sku = 'PU-A') = 20, 'stock increased by the units actually booked in');
select pg_temp.assert((select qty_available from flow.v_stock_position where sku = 'PU-A') = 20, 'available stock reflects receipt');
select pg_temp.assert((select count(*) from flow.communications where kind = 'shortage') = 0, 'no shortage email for a partial delivery');

-- ---- goods-in 2: final delivery is short (10 of 10 PU-A outstanding -> 8; PU-B 10 -> 6 + 2 damaged) ----
insert into r select 'g2', flow.book_in_goods(:'po', jsonb_build_object('delivery_ref', 'DEL-2', 'received_by', 'op1',
  'lines', jsonb_build_array(jsonb_build_object('po_line_id', :'la', 'qty_received', 8),
                             jsonb_build_object('po_line_id', :'lb', 'qty_received', 6, 'qty_damaged', 2, 'evidence', jsonb_build_array(jsonb_build_object('name','photo1','url','https://x.test/p1.jpg'))))), 'op1');
select pg_temp.assert((select (j->>'ok')::bool and j->>'po_status' = 'short_shipped' and jsonb_array_length(j->'discrepancies') = 3 and (j->>'recalculate_allocation')::bool from r where k='g2'), 'short + damaged detected: ' || (select j::text from r where k='g2'));
select pg_temp.assert((select qty_short from flow.po_lines where id = :'la') = 2 and (select qty_short from flow.po_lines where id = :'lb') = 2, 'lines show the shortage');
select pg_temp.assert((select qty_pending_receipt from flow.stock_items where sku = 'PU-A') = 28 and (select qty_pending_receipt from flow.stock_items where sku = 'PU-B') = 6, 'stock uses actual quantities, damaged excluded');
select pg_temp.assert((select count(*) from flow.communications where kind in ('shortage','damage') and status = 'pending_review') = 2, 'one email per discrepancy type');
select pg_temp.assert((select subject from flow.communications where kind = 'shortage') = 'Stock Shortage - ATAM_FLOW PO ' || :'poref', 'subject follows the agreed format');
select pg_temp.assert((select body_text like '%Ordered: 30%' and body_text like '%Received: 28%' and body_text like '%Shortage: 2%' and body_text like '%#P1%' and body_text like '%credit%' and body_text like '%ATAM FLOW Production Control%' from flow.communications where kind = 'shortage'), 'shortage email body: ' || (select body_text from flow.communications where kind = 'shortage'));
select pg_temp.assert((select count(*) from flow.notifications where kind = 'supplier_discrepancy') = 1, 'internal team notified');
select pg_temp.assert((select count(*) from flow.v_supplier_discrepancies_open) = 3, 'discrepancies stay open');
select pg_temp.assert((select count(*) from flow.v_unit_trace where po_ref = :'poref') > 0, 'every received unit traces to PO and order');
select pg_temp.assert((select qty_outstanding_eff from flow.po_lines where id = :'la') = 0, 'nothing outstanding on shortage line until replacement is promised');

-- ---- resolution: replacement promised raises outstanding again; arrival clears it; others closed ----
select id as dsh from flow.supplier_discrepancies where disc_type = 'shortage' and sku = 'PU-A' \gset
select id as ddm from flow.supplier_discrepancies where disc_type = 'damaged' \gset
select id as dsh2 from flow.supplier_discrepancies where disc_type = 'shortage' and sku = 'PU-B' \gset
select pg_temp.assert(not (flow.resolve_supplier_discrepancy(:'dsh', 'credit_issued', '', 'tester')->>'ok')::bool, 'a resolution note is required');
select pg_temp.assert((flow.resolve_supplier_discrepancy(:'dsh', 'replacement_promised', 'Supplier will resend Friday', 'tester', '2026-11-13')->>'ok')::bool, 'replacement promised');
select pg_temp.assert((select qty_outstanding_eff from flow.po_lines where id = :'la') = 2 and (select po_status::text from flow.purchase_orders where id = :'po') = 'partially_received', 'PO reopened for the replacement');
insert into r select 'g3', flow.book_in_goods(:'po', jsonb_build_object('delivery_ref', 'DEL-3', 'lines', jsonb_build_array(jsonb_build_object('po_line_id', :'la', 'qty_received', 2))), 'op1');
select pg_temp.assert((select (j->>'ok')::bool and jsonb_array_length(j->'discrepancies') = 0 from r where k='g3'), 'replacement arrives with no new complaint: ' || (select j::text from r where k='g3'));
select pg_temp.assert((select qty_pending_receipt from flow.stock_items where sku = 'PU-A') = 30, 'stock now 30');
select pg_temp.assert((select (flow.resolve_supplier_discrepancy(:'dsh', 'replacement_received', 'Arrived DEL-3', 'tester')->>'ok')::bool), 'shortage resolved');
select pg_temp.assert((flow.resolve_supplier_discrepancy(:'ddm', 'credit_issued', 'Credit note CN1', 'tester')->>'ok')::bool and (flow.resolve_supplier_discrepancy(:'dsh2', 'credit_issued', 'Credit note CN2', 'tester')->>'ok')::bool, 'others credited');
select pg_temp.assert((select po_status::text from flow.purchase_orders where id = :'po') = 'closed', 'PO closes when everything is resolved');
select pg_temp.assert((select count(*) from flow.v_supplier_discrepancies_open) = 0, 'no open discrepancies left');

-- ---- escalation fires once ----
insert into r select 'po2', flow.create_purchase_order(:'sup2', jsonb_build_array(jsonb_build_object('sku','PU-B','qty',5,'unit_cost',20)), 'tester');
select (j->>'po_id')::uuid as po2 from r where k = 'po2' \gset
update flow.purchase_orders set po_status = 'sent', is_active = true where id = :'po2';
select id as lb2 from flow.po_lines where po_id = :'po2' \gset
insert into r select 'g4', flow.book_in_goods(:'po2', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('po_line_id', :'lb2', 'qty_received', 3))), 'op1');
select pg_temp.assert((select (j->>'ok')::bool and jsonb_array_length(j->'discrepancies') = 1 from r where k='g4'), 'short on second PO');
select pg_temp.assert((select status from flow.communications where kind = 'shortage' and supplier_id = :'sup2') = 'draft', 'no supplier email -> draft + warning');
update flow.supplier_discrepancies set required_by = current_date - 1 where po_id = :'po2';
select pg_temp.assert((flow.supplier_discrepancy_check()->>'escalated')::int = 1, 'overdue discrepancy escalated');
select pg_temp.assert((flow.supplier_discrepancy_check()->>'escalated')::int = 0, 'escalation is idempotent');

-- ---- cancellation and permissions ----
insert into r select 'po3', flow.create_purchase_order(:'sup', jsonb_build_array(jsonb_build_object('sku','PU-A','qty',1,'unit_cost',5)), 'tester');
select pg_temp.assert((flow.cancel_purchase_order((select (j->>'po_id')::uuid from r where k='po3'), 'ordered in error', 'tester')->>'ok')::bool, 'draft PO cancelled');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_book_in_goods(uuid,jsonb,text)', 'execute') and not has_function_privilege('anon', 'public.flow_comm_approve(uuid,text)', 'execute'), 'browser roles cannot run purchasing actions directly');
select pg_temp.assert((select count(*) from flow.audit_log where action in ('create_po','approve_po','book_in_goods','resolve_supplier_discrepancy')) >= 8, 'actions audited');
-- keep later suites isolated from these fixtures
update flow.orders set is_active = false where deco_order_id in ('P1','P2');
\echo purchasing tests passed
