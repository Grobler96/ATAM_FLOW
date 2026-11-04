#!/usr/bin/env bash
# End-to-end allocation test against the local test DB (called by scripts/test-db.sh):
# Postgres builds the input -> the REAL engine (packages/engine/allocator.js) plans -> Postgres applies the plan.
# Env: PSQL (psql command incl. -d), ROOT, WORK, NODE, FIXED_NOW, FIXED_TODAY
set -euo pipefail
: "${PSQL:?}" "${ROOT:?}" "${WORK:?}" "${NODE:?}" "${FIXED_NOW:?}" "${FIXED_TODAY:?}"

pass() {
  $PSQL -At -c "select public.flow_allocation_input()" > "$WORK/ain.json"
  "$NODE" -e "
    const {buildAllocationPlan}=require(process.argv[1]);
    const i=JSON.parse(require('fs').readFileSync(0,'utf8')); i.now=process.env.FIXED_NOW; i.today=process.env.FIXED_TODAY;
    process.stdout.write(JSON.stringify(buildAllocationPlan(i)))" "$ROOT/packages/engine/allocator.js" < "$WORK/ain.json" > "$WORK/aplan.json"
  printf "select public.flow_apply_allocation(:'plan'::jsonb, 'test');\n" | $PSQL -At -v "plan=$(cat "$WORK/aplan.json")"
}
check() { $PSQL -v ON_ERROR_STOP=1 -q -c "$1" >/dev/null; }

# ---- fixtures: statuses 9/8 are 'awaiting_stock' in flow.deco_status_map; today is Mon 9 Nov 2026 ----
$PSQL -v ON_ERROR_STOP=1 -q <<'SQL'
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand) values
  ('AL-A', 'Polo', 'Navy', 'L', 10), ('AL-B', 'Hoodie', 'Black', 'M', 3), ('AL-C', 'Fleece', 'Grey', 'S', 0);
insert into flow.purchase_orders (deco_po_id, po_number, supplier, delivery_status, expected_date, is_active)
  values (990001, 'PO-1001', 'Ralawise', 'expected', '2026-11-12 12:00+00', true);
insert into flow.po_lines (po_id, line_no, sku, qty_expected, qty_received)
  select id, 1, 'AL-C', 8, 0 from flow.purchase_orders where deco_po_id = 990001;
SQL
$PSQL -v ON_ERROR_STOP=1 -q <<'SQL'
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_date, order_status, deco_status, stock_secured, order_value, total_units) values
  ('Q1','#Q1','Overdue Ltd',  '2026-11-06 12:00+00', '2026-10-20', 'awaiting_stock', 9, false, 600, 6),
  ('Q2','#Q2','Partial Ltd',  '2026-11-15 12:00+00', '2026-11-01', 'awaiting_stock', 9, false, 300, 6),
  ('Q3','#Q3','Mixed Ltd',    '2026-11-16 12:00+00', '2026-11-02', 'awaiting_stock', 8, false, 200, 8),
  ('Q4','#Q4','Later Ltd',    '2026-11-30 12:00+00', '2026-11-03', 'awaiting_stock', 9, false, 100, 3),
  ('Q5','#Q5','NoSource Ltd', '2026-11-18 12:00+00', '2026-11-03', 'awaiting_stock', 8, false, 100, 4),
  ('QS','#QS','Secured Ltd',  '2026-11-10 12:00+00', '2026-11-01', 'ready_for_production', 1, true, 900, 100);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods)
select v.wi, o.id, v.sku, 'x', 'x', 'Item ' || v.sku, v.q, '{embroidery}'
from (values ('QW1','Q1','AL-A',6), ('QW2','Q2','AL-A',6), ('QW3','Q3','AL-B',3), ('QW4','Q3','AL-C',5), ('QW5','Q4','AL-B',3),
             ('QW6','Q5','AL-Z',4), ('QW7','QS','AL-A',100)) v(wi, oid, sku, q)
join flow.orders o on o.deco_order_id = v.oid;
SQL

echo "pass 1"; R1=$(pass); echo "$R1" | cut -c1-400
check "do \$\$ begin
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.stock_items s on s.id=a.stock_item_id where s.sku='AL-A' and a.status='active' and a.source='on_hand') <> 10 then raise exception 'AL-A: all 10 units should be reserved'; end if;
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q1' and a.status='active') <> 6 then raise exception 'overdue A1 should hold 6'; end if;
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q2' and a.status='active') <> 4 then raise exception 'A2 should get the remaining 4'; end if;
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.orders o on o.id=a.order_id join flow.stock_items s on s.id=a.stock_item_id where o.deco_order_id='Q4' and s.sku='AL-B' and a.status='active') <> 3 then raise exception 'A4 should take the 3 hoodies that held-order A3 left free'; end if;
  if exists (select 1 from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q3' and a.source='on_hand' and a.status='active') then raise exception 'A3 is held: nothing reserved on hand'; end if;
  if (select a.qty from flow.allocations a join flow.orders o on o.id=a.order_id join flow.stock_items s on s.id=a.stock_item_id where o.deco_order_id='Q3' and s.sku='AL-C' and a.source='incoming_po' and a.status='active') <> 5 then raise exception 'A3 should reserve 5 units of the incoming PO'; end if;
  if exists (select 1 from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id in ('QS','Q5') and a.status='active') then raise exception 'secured / unsourced orders must have no reservations'; end if;
  if not exists (select 1 from flow.stock_items where sku='AL-Z' and is_placeholder) then raise exception 'unknown SKU should get a placeholder stock record'; end if;
  if (select alloc_state::text || '/' || order_status::text from flow.orders where deco_order_id='Q1') <> 'full/stock_allocated' then raise exception 'A1 should show Stock allocated'; end if;
  if (select alloc_state::text || '/' || order_status::text from flow.orders where deco_order_id='Q2') <> 'partial/awaiting_stock' then raise exception 'A2 should be partial'; end if;
  if (select decision from flow.allocation_decisions d join flow.orders o on o.id=d.order_id where o.deco_order_id='Q5') <> 'blocked' then raise exception 'A5 should be blocked'; end if;
  if (select count(*) from flow.allocation_decisions d join flow.orders o on o.id=d.order_id where o.deco_order_id like 'Q%') <> 5 then raise exception 'one decision per order expected'; end if;
  if (select count(*) from flow.stock_movements where movement_type='allocated' and ref_type='allocation') <> 3 then raise exception 'ledger should show 3 on-hand reservations'; end if;
  if (select reason from flow.allocation_decisions d join flow.orders o on o.id=d.order_id where o.deco_order_id='Q1') not like 'Allocated first: overdue by 3 day(s)%' then raise exception 'plain-English reason missing'; end if;
  if not exists (select 1 from flow.v_shortages where sku='AL-Z' and units_short=4) or not exists (select 1 from flow.v_shortages where sku='AL-A' and units_short=2) then raise exception 'shortage list wrong'; end if;
  if exists (select 1 from flow.v_shortages where sku='AL-C') then raise exception 'AL-C is fully covered by the PO'; end if;
  if has_function_privilege('authenticated','public.flow_apply_allocation(jsonb,text)','execute') or has_function_privilege('anon','public.flow_allocation_input()','execute') then raise exception 'browser roles must not run allocation'; end if;
end \$\$;"

echo "pass 2 (nothing changed -> nothing written)"; R2=$(pass); echo "$R2" | cut -c1-300
check "do \$\$ declare r jsonb := '$R2'::jsonb; begin
  if (r->>'allocations_created')::int + (r->>'allocations_released')::int + (r->>'decisions_recorded')::int + (r->>'orders_state_changed')::int <> 0 then raise exception 'second run was not a no-op: %', r; end if;
end \$\$;"

echo "pass 3 (DecoNetwork takes over A1: its reservation is released and A2 gets its full quantity)"
$PSQL -At -q -c "update flow.orders set deco_status=1, stock_secured=true, order_status='ready_for_production' where deco_order_id='Q1'" >/dev/null
pass >/dev/null
check "do \$\$ begin
  if exists (select 1 from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q1' and a.status='active') then raise exception 'A1 reservation should be released'; end if;
  if (select decision from flow.allocation_decisions d join flow.orders o on o.id=d.order_id where o.deco_order_id='Q1' order by d.created_at desc limit 1) <> 'release' then raise exception 'release should be recorded'; end if;
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q2' and a.status='active') <> 6 then raise exception 'A2 should now be fully allocated'; end if;
  if (select order_status from flow.orders where deco_order_id='Q2') <> 'stock_allocated' then raise exception 'A2 should show Stock allocated'; end if;
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.stock_items s on s.id=a.stock_item_id where s.sku='AL-A' and a.status='active') > 10 then raise exception 'over-allocated AL-A'; end if;
  if (select order_status from flow.orders where deco_order_id='Q1') <> 'ready_for_production' then raise exception 'engine must not touch DecoNetwork-owned status'; end if;
end \$\$;"

echo "pass 4 (manual allocation is audited, protected from the engine, and the engine plans around it)"
A4L=$($PSQL -At -c "select a.id from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q4' and a.status='active'")
A3B=$($PSQL -At -c "select l.id from flow.order_lines l where l.deco_workflow_item_id='QW3'")
R4=$($PSQL -At -c "select public.flow_manual_allocate('$A3B'::uuid, 3, 'on_hand', null, 'Daniel', 'customer collecting')")
check "do \$\$ begin if (('$R4'::jsonb)->>'ok')::boolean then raise exception 'manual allocation should fail while the engine holds those units'; end if; end \$\$;"
R5=$($PSQL -At -c "select public.flow_release_allocation('$A4L'::uuid, 'Daniel', 'give to A3 by hand')")
R6=$($PSQL -At -c "select public.flow_manual_allocate('$A3B'::uuid, 3, 'on_hand', null, 'Daniel', 'customer collecting')")
check "do \$\$ begin if not (('$R6'::jsonb)->>'ok')::boolean then raise exception 'manual allocation failed: %', '$R6'; end if; end \$\$;"
NR=$($PSQL -At -c "select public.flow_manual_allocate('$A3B'::uuid, 1, 'on_hand', null, 'Daniel', '')")
check "do \$\$ begin if (('$NR'::jsonb)->>'ok')::boolean then raise exception 'a manual allocation needs a reason'; end if; end \$\$;"
pass >/dev/null
check "do \$\$ begin
  if not exists (select 1 from flow.allocations a join flow.orders o on o.id=a.order_id where o.deco_order_id='Q3' and a.is_manual and a.status='active' and a.qty=3) then raise exception 'manual allocation must survive the engine run'; end if;
  if exists (select 1 from flow.allocations a join flow.orders o on o.id=a.order_id join flow.stock_items s on s.id=a.stock_item_id where o.deco_order_id='Q4' and s.sku='AL-B' and a.status='active') then raise exception 'A4 must not get hoodies the manual allocation holds'; end if;
  if (select decision from flow.allocation_decisions d join flow.orders o on o.id=d.order_id where o.deco_order_id='Q4' order by d.created_at desc limit 1) <> 'blocked' then raise exception 'A4 should now be blocked'; end if;
  if (select count(*) from flow.audit_log where action in ('manual_allocate','release_allocation')) <> 2 then raise exception 'successful manual actions must be audited (and failed attempts must not be)'; end if;
  if (select coalesce(sum(a.qty),0) from flow.allocations a join flow.stock_items s on s.id=a.stock_item_id where s.sku='AL-B' and a.status='active') > 3 then raise exception 'over-allocated AL-B'; end if;
end \$\$;"
echo "ALLOCATION ROUNDTRIP PASSED"
