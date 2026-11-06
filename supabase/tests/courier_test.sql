-- Courier events, claims and the open-problem exception.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

insert into flow.producers (code, name, turnaround_days, capable_methods) values ('CRP', 'Courier Test Producer', 3, '{embroidery}');
insert into flow.tp_movements (movement_code, producer_id, status, dispatch_date, expected_return_date, carrier, tracking_ref)
  select 'TP-CR-1', id, 'dispatched', current_date - 2, current_date + 3, 'DPD', 'DPD123' from flow.producers where code = 'CRP';

-- events
select pg_temp.assert(not (flow.cr_record_event('NOPE', 'lost', 'outbound', 'lost it entirely', 't')->>'ok')::bool, 'unknown consignment refused');
select pg_temp.assert((flow.cr_record_event('TP-CR-1', 'lost', 'outbound', '', 't')->>'needs_reason')::bool, 'a problem event needs a note');
select pg_temp.assert(not (flow.cr_record_event('TP-CR-1', 'exploded', 'outbound', 'x long enough', 't')->>'ok')::bool, 'unknown event refused');
insert into r select 'collected', flow.cr_record_event('TP-CR-1', 'collected', 'outbound', null, 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'collected'), 'collected needs no note');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.exc_detect_courier()) e where e->>'key' = 'courier:TP-CR-1'), 'no exception for a normal event');
insert into r select 'lost', flow.cr_record_event('TP-CR-1', 'lost', 'outbound', 'DPD says parcel not found at depot', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'claim_suggested')::bool from r where k = 'lost'), 'lost suggests a claim');
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.exc_detect_courier()) e where e->>'key' = 'courier:TP-CR-1' and e->'opts'->>'severity' = 'critical'), 'lost raises a critical exception');

-- claims
select pg_temp.assert((flow.cr_open_claim('TP-CR-1', 'lost', 120, '', 't')->>'needs_reason')::bool, 'claim needs a note');
select pg_temp.assert(not (flow.cr_open_claim('TP-CR-1', 'lost', null, 'Parcel lost in transit', 't')->>'ok')::bool, 'claim needs a value');
insert into r select 'claim', flow.cr_open_claim('TP-CR-1', 'lost', 120, 'Parcel lost in transit', 'tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'claim') and (select carrier = 'DPD' and tracking_ref = 'DPD123' from flow.courier_claims limit 1), 'claim opened with carrier and tracking');
select pg_temp.assert(not (flow.cr_open_claim('TP-CR-1', 'lost', 120, 'Parcel lost in transit', 't')->>'ok')::bool, 'no duplicate open claim');
select pg_temp.assert(not (flow.cr_claim_update((select j->>'claim_ref' from r where k = 'claim'), 'paid', null, null, 't')->>'ok')::bool, 'paid needs an amount');
select pg_temp.assert((flow.cr_claim_update((select j->>'claim_ref' from r where k = 'claim'), 'rejected', null, '', 't')->>'needs_reason')::bool, 'rejecting needs a reason');
select pg_temp.assert((flow.cr_claim_update((select j->>'claim_ref' from r where k = 'claim'), 'submitted', null, null, 't')->>'ok')::bool, 'claim submitted');
select pg_temp.assert((flow.cr_claim_update((select j->>'claim_ref' from r where k = 'claim'), 'paid', 100, 'Part paid', 't')->>'ok')::bool, 'claim paid');
select pg_temp.assert(not (flow.cr_claim_update((select j->>'claim_ref' from r where k = 'claim'), 'closed', null, 'again later', 't')->>'ok')::bool, 'finished claim cannot change');

-- stale claim
insert into flow.courier_claims (claim_ref, movement_id, kind, value_claimed, status, opened_at) select 'CLM-OLD', id, 'damaged', 40, 'open', now() - interval '20 days' from flow.tp_movements where movement_code = 'TP-CR-1';
select pg_temp.assert(exists (select 1 from jsonb_array_elements(flow.exc_detect_courier()) e where e->>'key' = 'claim:CLM-OLD'), 'stale claim raises an exception');

-- recovery: a later delivery clears the problem
insert into r select 'deliv', flow.cr_record_event('TP-CR-1', 'delivered', 'outbound', null, 'tester');
select pg_temp.assert(not exists (select 1 from jsonb_array_elements(flow.exc_detect_courier()) e where e->>'key' = 'courier:TP-CR-1'), 'delivery clears the courier problem');
select pg_temp.assert(exists (select 1 from flow.audit_log where action = 'courier_claim_paid'), 'claim payment audited');
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_cr_open_claim(text,text,numeric,text,text)', 'execute'), 'wrapper closed to browser roles');
\echo courier_test OK
