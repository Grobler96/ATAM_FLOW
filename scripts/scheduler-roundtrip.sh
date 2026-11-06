#!/usr/bin/env bash
# End-to-end scheduler test against the local test DB (called by scripts/test-db.sh):
# Postgres builds the input -> the REAL engine (packages/engine/scheduler.js) plans -> Postgres applies the plan.
# Env: PSQL (psql command incl. -d), ROOT, WORK, NODE, FIXED_NOW (pins the planning clock so results are repeatable)
set -euo pipefail
: "${PSQL:?}" "${ROOT:?}" "${WORK:?}" "${NODE:?}" "${FIXED_NOW:?}"

pass() {   # input -> plan -> apply ; prints the apply result
  $PSQL -At -c "select public.flow_scheduler_input()" > "$WORK/in.json"
  FIXED_NOW="$FIXED_NOW" "$NODE" -e "
    const {buildPlan}=require(process.argv[1]);
    const i=JSON.parse(require('fs').readFileSync(0,'utf8')); i.now=process.env.FIXED_NOW;
    process.stdout.write(JSON.stringify(buildPlan(i)))" "$ROOT/packages/engine/scheduler.js" < "$WORK/in.json" > "$WORK/plan.json"
  printf "select public.flow_apply_schedule(:'plan'::jsonb, 'test');\n" | $PSQL -At -v "plan=$(cat "$WORK/plan.json")"
}
check() { $PSQL -v ON_ERROR_STOP=1 -q -c "$1" >/dev/null; }   # raises inside DO blocks on failure

# ---- fixtures (absolute dates so the run is repeatable; FIXED_NOW is Monday 09 Nov 2026 08:00) ----
$PSQL -v ON_ERROR_STOP=1 -q <<'SQL'
-- the test uses a DTF job; the real business has no DTF machine, so the test brings one back for itself
update flow.machines set is_active = true where code = 'DTF-1';
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, total_units, order_status, deco_status, stock_secured) values
  ('S1','#S1','Alpha','2026-11-11 12:00+00',40,'ready_for_production',1,true),
  ('S2','#S2','Beta', '2026-11-20 12:00+00',20,'ready_for_production',1,true),
  ('S3','#S3','Gamma','2026-11-12 12:00+00',10,'on_hold',7,false),
  ('S4','#S4','Delta','2026-11-06 12:00+00',15,'ready_for_production',1,true),
  ('S5','#S5','Epsilon','2026-11-10 12:00+00',12,'awaiting_stock',9,false);
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, garment_type, qty_required, decoration_methods, stitches_per_piece)
select v.wi, o.id, 'SK-' || v.wi, 'Navy', 'Polos', v.q, v.m::text[], 6000
from (values ('SL1','S1',40,'{dtf,embroidery}'),('SL2','S2',20,'{embroidery}'),('SL3','S3',10,'{embroidery}'),('SL4','S4',15,'{embroidery}'),('SL5','S5',12,'{embroidery}')) v(wi, oid, q, m)
join flow.orders o on o.deco_order_id = v.oid;
SQL

echo "pass 1"; R1=$(pass); echo "$R1"
check "do \$\$ begin
  if (select count(*) from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id in ('S1','S2','S3','S4','S5')) <> 6 then raise exception 'expected 6 steps'; end if;
  if not exists (select 1 from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S3' and js.status='blocked' and js.blocked_reason='order is on hold in DecoNetwork') then raise exception 'on-hold order not reported blocked'; end if;
  if not exists (select 1 from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S5' and js.status='blocked' and js.blocked_reason like 'awaiting stock%') then raise exception 'awaiting-stock order should be blocked with its reason'; end if;
  if exists (select 1 from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id in ('S1','S2','S4') and (js.machine_id is null or js.reason is null or js.planned_start is null)) then raise exception 'scheduled step missing machine/reason/time'; end if;
  if (select risk_score from flow.orders where deco_order_id='S4') < 95 then raise exception 'overdue order should have risk >= 95'; end if;
  if (select js.status from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S1' and js.method_code='dtf') <> 'ready' then raise exception 'first step should be ready'; end if;
  if (select js.status from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S1' and js.method_code='embroidery') <> 'pending' then raise exception 'second step should wait'; end if;
  if (select e.planned_start < d.planned_end from flow.job_steps e join flow.job_steps d on d.order_id=e.order_id and d.method_code='dtf' join flow.orders o on o.id=e.order_id where o.deco_order_id='S1' and e.method_code='embroidery') then raise exception 'embroidery starts before DTF ends'; end if;
  if (select first_value(o.deco_order_id) over (order by js.planned_start) from flow.job_steps js join flow.orders o on o.id=js.order_id where js.method_code='embroidery' and js.machine_id is not null limit 1) <> 'S4' then raise exception 'overdue S4 should run first on embroidery'; end if;
  if not exists (select 1 from flow.batches) or not exists (select 1 from flow.batch_orders) then raise exception 'no batches written'; end if;
  if has_function_privilege('authenticated','public.flow_scheduler_input()','execute') or has_function_privilege('anon','public.flow_apply_schedule(jsonb,text)','execute') then raise exception 'browser roles must not call scheduler functions'; end if;
end \$\$;"

echo "pass 2 (identical inputs must change nothing)"; R2=$(pass); echo "$R2"
check "do \$\$ declare r jsonb := '$R2'::jsonb; begin
  if (r->>'steps_changed')::int + (r->>'batches_changed')::int + (r->>'orders_changed')::int + (r->>'stale_steps_removed')::int + (r->>'stale_batches_removed')::int <> 0 then raise exception 'second apply was not a no-op: %', r; end if;
end \$\$;"

echo "pass 3 (manual pin wins; recommendation is retained)"
$PSQL -At -q -c "select public.flow_set_schedule_override((select id from flow.orders where deco_order_id='S2'), null, 1, 'customer collecting', 'Daniel')" >/dev/null
pass >/dev/null
check "do \$\$ begin
  if (select order_ref from flow.v_production_queue where method_code='embroidery' and machine_id is not null order by planned_start limit 1) <> '#S2' then raise exception 'pinned S2 should be first on embroidery'; end if;
  if not (select is_overridden from flow.v_production_queue where order_ref='#S2') then raise exception 'override not flagged'; end if;
  if (select recommended_position from flow.v_production_queue where order_ref='#S2') = (select sequence_position from flow.v_production_queue where order_ref='#S2') then raise exception 'recommendation was lost'; end if;
  if (select reason from flow.v_production_queue where order_ref='#S2') not like '%PINNED by Daniel%' then raise exception 'pin reason missing'; end if;
end \$\$;"
$PSQL -At -q -c "select public.flow_clear_schedule_override((select id from flow.orders where deco_order_id='S2'), null, 'Daniel')" >/dev/null
pass >/dev/null
check "do \$\$ begin if exists (select 1 from flow.v_production_queue where is_overridden) then raise exception 'override should be cleared'; end if; end \$\$;"

echo "pass 4 (work already in progress is protected)"
$PSQL -At -q -c "update flow.job_steps set status='in_progress' where order_id=(select id from flow.orders where deco_order_id='S4') and method_code='embroidery'" >/dev/null
pass >/dev/null
check "do \$\$ declare s4_end timestamptz; s4_m uuid; begin
  select js.planned_end, js.machine_id into s4_end, s4_m from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S4';
  if (select count(*) from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S4') <> 1 then raise exception 'in-progress step duplicated or removed'; end if;
  if (select js.status from flow.job_steps js join flow.orders o on o.id=js.order_id where o.deco_order_id='S4') <> 'in_progress' then raise exception 'in-progress status overwritten'; end if;
  if exists (select 1 from flow.job_steps js where js.method_code='embroidery' and js.machine_id = s4_m and js.status in ('pending','ready') and js.planned_start < s4_end) then raise exception 'new work scheduled over the busy machine'; end if;
end \$\$;"
echo "SCHEDULER ROUNDTRIP PASSED"
