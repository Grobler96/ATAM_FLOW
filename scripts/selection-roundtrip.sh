#!/usr/bin/env bash
# End-to-end selection test against the local test DB (called by scripts/test-db.sh):
# Postgres builds the input -> the REAL engine (packages/engine/selector.js) -> Postgres saves / confirms the result.
# Env: PSQL (psql command incl. -d), ROOT, WORK, NODE, FIXED_TODAY
set -euo pipefail
: "${PSQL:?}" "${ROOT:?}" "${WORK:?}" "${NODE:?}" "${FIXED_TODAY:?}"

run_engine() {   # $1 = order uuid
  $PSQL -At -c "select public.flow_selection_input('$1')" > "$WORK/sin.json"
  "$NODE" -e "
    const {buildSelection}=require(process.argv[1]);
    const i=JSON.parse(require('fs').readFileSync(0,'utf8')); i.today=process.env.FIXED_TODAY;
    process.stdout.write(JSON.stringify(buildSelection(i)))" "$ROOT/packages/engine/selector.js" < "$WORK/sin.json" > "$WORK/sres.json"
}
save() { printf "select public.flow_save_selection('%s'::uuid, :'res'::jsonb, 'test');\n" "$1" | $PSQL -At -v "res=$(cat "$WORK/sres.json")"; }
check() { $PSQL -v ON_ERROR_STOP=1 -q -c "$1" >/dev/null; }

$PSQL -v ON_ERROR_STOP=1 -q <<'SQL'
insert into flow.suppliers (code, name, email, lead_time_days, delivery_cost, on_time_rate) values
  ('SELA', 'Sel Supplier A', 'a@sel.test', 3, 5, 96), ('SELB', 'Sel Supplier B', 'b@sel.test', 5, 9, 80), ('SELC', 'Sel Supplier C', 'c@sel.test', 2, 4, null);
insert into flow.supplier_offers (supplier_id, sku, unit_cost, min_qty, stock_available)
  select id, 'SEL-P1', case code when 'SELA' then 5 else 4.5 end, 1, 500 from flow.suppliers where code in ('SELA','SELB');
insert into public.sku_costs (sku, product_name, unit_cost) values ('SEL-P1', 'Sel Polo', 6);
insert into flow.purchase_orders (deco_po_id, po_number, supplier, supplier_ref_id, delivery_status, expected_date, is_active)
  select 980001, 'SEL-HIST', 'Sel Supplier C', id, 'received', '2026-10-01 12:00+00', false from flow.suppliers where code = 'SELC';
insert into flow.po_lines (po_id, line_no, sku, qty_expected, qty_received) select id, 1, 'SEL-P1', 10, 10 from flow.purchase_orders where deco_po_id = 980001;
insert into flow.producers (code, name, address, turnaround_days, capable_methods, cost_out, cost_back, weekly_capacity_units) values ('SELX', 'Sel Embroiderers', '1 Test St', 3, '{embroidery}', 8, 8, 2000);
insert into flow.producer_rates (producer_id, method, basis, unit_price, setup_fee, min_job_charge) select id, 'embroidery', 'per_1000_stitches', 0.8, 10, 30 from flow.producers where code = 'SELX';
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_date, order_status, deco_status, stock_secured, order_value, total_units) values
  ('SO1', '#SO1', 'Select Ltd', '2026-12-15 12:00+00', '2026-11-01', 'awaiting_stock', 9, false, 500, 20);
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, colour, size, product_name, qty_required, decoration_methods, emb_areas, stitches_per_piece)
  select 'SOL1', 'SDL1', id, 'SEL-P1', 'Navy', 'M', 'Sel Polo', 20, '{embroidery}', 1, 5000 from flow.orders where deco_order_id = 'SO1';
SQL
ORD=$($PSQL -At -c "select id from flow.orders where deco_order_id = 'SO1'")

echo "pass 1: input -> engine -> save"
run_engine "$ORD"
check "do \$\$ declare i jsonb := public.flow_selection_input('$ORD'); begin
  if (i->'order'->'lines'->0->>'need_buy')::int <> 20 then raise exception 'the order needs to buy 20 units'; end if;
  if jsonb_array_length(i->'suppliers') < 3 then raise exception 'suppliers missing from input'; end if;
  if (select s->'offers'->'SEL-P1'->>'source' from jsonb_array_elements(i->'suppliers') s where s->>'name' = 'Sel Supplier C') <> 'last_paid_cost' then raise exception 'supplier C should be offered at last paid cost from PO history'; end if;
  if (select s->'offers'->'SEL-P1'->>'source' from jsonb_array_elements(i->'suppliers') s where s->>'name' = 'Sel Supplier A') <> 'supplier_offer' then raise exception 'explicit offer wins'; end if;
end \$\$"
R1=$(save "$ORD"); echo "$R1" | cut -c1-200
"$NODE" -e "
  const r=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const rec=r.options.find(o=>o.key===r.recommended_key);
  if(!rec) throw new Error('no recommendation: '+r.explanation);
  if(rec.route.id==='internal') throw new Error('internal has no rates, it must not be recommended');
  const internal=r.options.filter(o=>o.route.id==='internal');
  if(!internal.length||!internal.every(o=>o.incomplete)) throw new Error('internal options should be incomplete without rates');
  if(!r.options.some(o=>o.suppliers.some(s=>s.name==='Sel Supplier B'))) throw new Error('supplier B missing');
  console.log('recommended:', rec.supplier_plan, '+', rec.route.name, rec.costs.total, rec.margin_pct+'%');
" "$WORK/sres.json"
echo "pass 2 (nothing changed -> same run kept)"
run_engine "$ORD"; R2=$(save "$ORD"); echo "$R2" | grep -q '"unchanged": true' || { echo "second save should be unchanged: $R2"; exit 1; }
check "do \$\$ begin if (select count(*) from flow.selection_runs where order_id = '$ORD') <> 1 then raise exception 'one run expected'; end if; end \$\$"

echo "pass 3 (supplier cost changes -> new run, old one superseded)"
$PSQL -v ON_ERROR_STOP=1 -q -c "update flow.supplier_offers set unit_cost = 3 where sku = 'SEL-P1' and supplier_id = (select id from flow.suppliers where code = 'SELB')"
run_engine "$ORD"; R3=$(save "$ORD"); echo "$R3" | grep -q '"unchanged"' && { echo "a cost change must create a new run: $R3"; exit 1; }
check "do \$\$ begin
  if (select count(*) from flow.selection_runs where order_id = '$ORD') <> 2 or (select count(*) from flow.selection_runs where order_id = '$ORD' and status = 'superseded') <> 1 then raise exception 'history: 2 runs, 1 superseded'; end if;
end \$\$"

echo "pass 4 (confirmation rules)"
REC=$($PSQL -At -c "select recommended_key from flow.selection_runs where order_id = '$ORD' and status = 'proposed'")
OTHER=$($PSQL -At -c "select x->>'key' from flow.selection_runs r, jsonb_array_elements(r.result->'options') x where r.order_id = '$ORD' and r.status = 'proposed' and not (x->>'incomplete')::boolean and x->>'key' <> r.recommended_key limit 1")
INCOMP=$($PSQL -At -c "select x->>'key' from flow.selection_runs r, jsonb_array_elements(r.result->'options') x where r.order_id = '$ORD' and r.status = 'proposed' and (x->>'incomplete')::boolean limit 1")
check "do \$\$ declare r jsonb; begin
  r := public.flow_confirm_selection('$ORD', \$k\$$OTHER\$k\$, 'tester', null);
  if (r->>'ok')::boolean then raise exception 'a different choice needs a reason'; end if;
  r := public.flow_confirm_selection('$ORD', \$k\$$INCOMP\$k\$, 'tester', 'because');
  if (r->>'ok')::boolean or r->>'error' not like '%missing costs%' then raise exception 'incomplete option must be refused: %', r; end if;
  r := public.flow_confirm_selection('$ORD', \$k\$$OTHER\$k\$, 'tester', 'customer prefers this supplier');
  if not (r->>'ok')::boolean then raise exception 'override with reason should work: %', r; end if;
  if (select status from flow.selection_runs where order_id = '$ORD' and status = 'confirmed') is null then raise exception 'confirmed'; end if;
  if (select count(*) from flow.v_selection_latest where order_ref = '#SO1' and status = 'confirmed' and explanation is not null) <> 1 then raise exception 'latest view'; end if;
  if (select count(*) from flow.audit_log where action = 'confirm_selection') <> 1 then raise exception 'confirmation audited once'; end if;
  if has_function_privilege('authenticated', 'public.flow_confirm_selection(uuid,text,text,text)', 'execute') then raise exception 'browser roles must not confirm directly'; end if;
end \$\$"
echo "pass 5 (cost changes after confirmation raise a warning, decision kept)"
$PSQL -v ON_ERROR_STOP=1 -q -c "update flow.supplier_offers set unit_cost = 7 where sku = 'SEL-P1' and supplier_id = (select id from flow.suppliers where code = 'SELA')"
run_engine "$ORD"; save "$ORD" >/dev/null
check "do \$\$ begin if (select count(*) from flow.notifications where kind = 'selection_stale') <> 1 then raise exception 'stale warning expected'; end if; end \$\$"
$PSQL -v ON_ERROR_STOP=1 -q -c "update flow.orders set is_active = false where deco_order_id = 'SO1'"
echo "selection round-trip ok"
