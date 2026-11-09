-- Waste ledger: record, approval threshold, confirm/dismiss suggestions, recovery, replacement, rates and the detector.
\set ON_ERROR_STOP on
create temp table r (k text, v jsonb);
do $$
declare v_o uuid; v_p uuid; res jsonb; ref text; t_ok int := 0;
begin
  insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, priority, created_at)
    select 'WST1', 'WST-ORD-1', 'Waste Test Ltd', now() + interval '20 days', 'ready_for_production', true, 1, 24, 0, now() where not exists (select 1 from flow.orders where order_ref = 'WST-ORD-1');
  select id into v_o from flow.orders where order_ref = 'WST-ORD-1';
  select id into v_p from flow.producers limit 1;
  if v_p is null then insert into flow.producers (code, name, is_active) values ('WSTP', 'Waste Test Decorators', true) returning id into v_p; end if;

  -- small waste is approved straight away
  res := flow.waste_record(jsonb_build_object('stage','warehouse','cause','stain_or_mark','qty',2,'sku','POLO-BLK-M','order_ref','WST-ORD-1','reason','Marked on the shelf'), 'tester');
  assert (res->>'ok')::boolean and res->>'status' = 'approved', 'small waste approved: ' || res::text;
  assert (select value from flow.waste_events where waste_ref = res->>'waste_ref') = 9.00, 'value from stock cost';

  -- missing reason / cause / quantity are refused
  assert not (flow.waste_record(jsonb_build_object('stage','warehouse','cause','stain_or_mark','qty',2,'reason','x'), 't')->>'ok')::boolean, 'reason needed';
  assert not (flow.waste_record(jsonb_build_object('stage','warehouse','cause','nope','qty',2,'reason','Some real reason'), 't')->>'ok')::boolean, 'cause needed';
  assert not (flow.waste_record(jsonb_build_object('stage','warehouse','cause','stain_or_mark','qty',0,'reason','Some real reason'), 't')->>'ok')::boolean, 'qty needed';
  assert not (flow.waste_record(jsonb_build_object('stage','warehouse','cause','stain_or_mark','qty',1,'order_ref','NO-SUCH','reason','Some real reason'), 't')->>'ok')::boolean, 'order must exist';

  -- big waste waits for a manager
  res := flow.waste_record(jsonb_build_object('stage','decorator','cause','decorator_spoilage','qty',60,'sku','POLO-BLK-M','order_ref','WST-ORD-1','reason','Scorched in the press'), 'tester');
  assert res->>'status' = 'pending_approval', 'big waste pending';
  ref := res->>'waste_ref';
  assert not (flow.waste_decide(ref, false, 'no', 'boss')->>'ok')::boolean, 'rejecting needs a reason';
  assert (flow.waste_decide(ref, true, null, 'boss')->>'ok')::boolean, 'approve';
  assert not (flow.waste_decide(ref, true, null, 'boss')->>'ok')::boolean, 'cannot decide twice';

  -- recovery cannot exceed value and needs a reason
  assert not (flow.waste_recover(ref, 9999, null, 'Decorator paid us back', 'boss')->>'ok')::boolean, 'recovery capped';
  assert not (flow.waste_recover(ref, 50, null, 'x', 'boss')->>'ok')::boolean, 'recovery needs a note';
  assert (flow.waste_recover(ref, 100, null, 'Decorator credited the invoice', 'boss')->>'ok')::boolean, 'recovery ok';
  assert (select recovered_value from flow.waste_events where waste_ref = ref) = 100, 'recovery stored';

  -- replacement request is once only
  assert (flow.waste_replacement(ref, 'boss')->>'ok')::boolean, 'replacement ok';
  assert not (flow.waste_replacement(ref, 'boss')->>'ok')::boolean, 'replacement twice refused';

  -- the audit trail has it
  assert exists (select 1 from flow.audit_log where entity = 'waste' and entity_id = ref and action = 'waste_approved'), 'audited';

  -- suggestions are idempotent and stay suggestions until confirmed
  insert into flow.rework_jobs (rework_ref, order_id, units, defect_type, cause, units_scrapped, status) values ('RW-WST-1', v_o, 5, 'scorch', 'operator', 3, 'complete') on conflict (rework_ref) do nothing;
  insert into r select 'sug1', flow.waste_suggest();
  insert into r select 'sug2', flow.waste_suggest();
  assert (select (v->>'qc')::int from r where k = 'sug2') = 0, 'second run adds nothing';
  select waste_ref into ref from flow.waste_events where source_key like 'qc:%' and reason like '%RW-WST-1%';
  assert ref is not null, 'qc suggestion exists';
  assert (select status from flow.waste_events where waste_ref = ref) = 'suggested', 'stays a suggestion';
  assert not (flow.waste_confirm(ref, false, 'no', 'a')->>'ok')::boolean, 'dismiss needs a reason';
  assert (flow.waste_confirm(ref, true, null, 'a')->>'ok')::boolean, 'confirm';
  assert (select status from flow.waste_events where waste_ref = ref) in ('approved', 'pending_approval'), 'confirmed follows the rule';
  assert not (flow.waste_confirm(ref, true, null, 'a')->>'ok')::boolean, 'cannot confirm twice';

  -- rates view only counts approved waste, and detector output is valid json
  assert exists (select 1 from flow.v_waste_rates where waste_units >= 0), 'rates view runs';
  assert jsonb_typeof(flow.exc_detect_waste()) = 'array', 'detector runs';
  assert (select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure)) like '%''waste''%', 'detector registered';
end $$;
select 'waste ok';
