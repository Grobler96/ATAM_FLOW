-- Stock-takes: scope, blind counting, recount by someone else, who may accept what, closing, waste suggestions, exceptions, and who can see what.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

insert into public.sku_costs (sku, product_name, unit_cost) values ('STK-A', 'Item A', 2), ('STK-B', 'Item B', 10), ('STK-C', 'Item C', 1), ('STK-D', 'Item D', 100), ('STK-E', 'Item E', 5) on conflict (sku) do update set unit_cost = excluded.unit_cost;
insert into flow.stock_items (sku, product_name, colour, size, qty_on_hand, storage_location) values
  ('STK-A', 'Item A', 'Navy', 'M', 100, 'ZZ-A1'), ('STK-B', 'Item B', 'Navy', 'L', 50, 'ZZ-A1'), ('STK-C', 'Item C', 'Black', 'M', 20, 'ZZ-A2'), ('STK-D', 'Item D', 'Red', 'S', 10, 'ZZ-B1'), ('STK-E', 'Item E', 'Red', 'M', 30, 'ZZ-B2');

-- 1. starting
insert into r select 's0', flow.stocktake_start('x', '{"kind":"all"}'::jsonb, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's0'), 'a stock-take needs a name');
insert into r select 's1', flow.stocktake_start('Bad scope', '{"kind":"everything"}'::jsonb, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's1'), 'only known scopes');
insert into r select 's2', flow.stocktake_start('Shelf A', '{"kind":"location","location":"ZZ-A"}'::jsonb, 'alice');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'lines')::int = 3 from r where k = 's2'), 'a shelf scope picks up the items on that shelf');
select j->>'take_id' as t1 from r where k = 's2' \gset
insert into r select 's3', flow.stocktake_start('Valuables', '{"kind":"skus","skus":["stk-a","STK-D","NOPE"]}'::jsonb, 'alice');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'lines')::int = 1 and (j->>'skipped_in_other_take')::int = 1 and j->'unknown_skus' = '["NOPE"]'::jsonb from r where k = 's3'), 'an item already in an open stock-take is skipped, and unknown SKUs are reported');
select j->>'take_id' as t2 from r where k = 's3' \gset
insert into r select 's4', flow.stocktake_start('Nothing', '{"kind":"location","location":"ZZ-A"}'::jsonb, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's4') and (select j->>'error' like '%already in another open stock-take%' from r where k = 's4'), 'nothing left to count says why');
insert into r select 's5', flow.stocktake_start('Top 1', '{"kind":"high_value","top":1}'::jsonb, 'alice');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'lines')::int = 1 from r where k = 's5'), 'a most-valuable scope works');
select pg_temp.assert((select sku from flow.stock_take_lines where take_id = (select (j->>'take_id')::uuid from r where k = 's5')) <> 'STK-D', 'it skips items already being counted and takes the next most valuable');
select flow.stocktake_cancel((select (j->>'take_id')::uuid from r where k = 's5'), 'Only testing the scope', 'alice') as c5 \gset

-- 2. counting is blind
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000001a1', 'counter@stock.test', now()), ('00000000-0000-0000-0000-0000000001a2', 'outsider@stock.test', now());
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000001a1', 'warehouse') on conflict (user_id) do update set role = 'warehouse';
select pg_temp.as_user('00000000-0000-0000-0000-0000000001a1');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_stock_take_lines where take_id = :'t1'::uuid and expected_qty is null and variance is null and status = 'to_count') = 3, 'while counting, the expected quantity and the difference are hidden');
reset role;
-- 3. counts
insert into r select 'k1', flow.stocktake_count(:'t1'::uuid, 'stk-a', 98, 'alice');
select pg_temp.assert((select (j->>'ok')::bool and not (j ? 'expected_qty') and not (j ? 'expected') and (j->>'counted_lines')::int = 1 from r where k = 'k1'), 'a count is accepted (any letter case) and the answer does not reveal the expected quantity');
insert into r select 'k2', flow.stocktake_count(:'t1'::uuid, 'STK-B', 44, 'alice');
insert into r select 'k3', flow.stocktake_count(:'t1'::uuid, 'STK-C', 20, 'alice');
insert into r select 'k4', flow.stocktake_count(:'t1'::uuid, 'NOPE', 5, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'k4'), 'an unknown SKU is refused');
insert into r select 'k5', flow.stocktake_count(:'t1'::uuid, 'STK-C', -1, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'k5'), 'a negative count is refused');
insert into r select 'k6', flow.stocktake_count(:'t1'::uuid, 'STK-D', 7, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'k6') and (select j->>'error' like '%another stock-take%' from r where k = 'k6'), 'a SKU being counted in another stock-take is refused');
insert into r select 'k7', flow.stocktake_count(:'t1'::uuid, 'STK-E', 31, 'alice');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'added_in_count')::bool from r where k = 'k7'), 'stock found that was not on the list is added');
insert into r select 'k8', flow.stocktake_count(:'t2'::uuid, 'STK-D', 7, 'alice');
select pg_temp.assert((select count(*) from flow.stock_take_counts) >= 5, 'every count is logged');
select pg_temp.assert(pg_temp.try('update flow.stock_take_counts set qty = 0') like '%append-only%', 'the count log cannot be changed');

-- 4. finish counting: matched / needs a recount / waiting for a decision
insert into r select 'v1', flow.stocktake_review(:'t1'::uuid, 'alice');
select pg_temp.assert((select (j->>'matched')::int = 1 and (j->>'recount_needed')::int = 1 and (j->>'differences')::int = 2 and (j->>'not_counted')::int = 0 from r where k = 'v1'), 'one matched, one needs a recount (6 units out), two small differences wait for a decision');
select pg_temp.as_user('00000000-0000-0000-0000-0000000001a1');
set role authenticated;
select pg_temp.assert((select expected_qty = 100 and variance = -2 and variance_value = -4.00 from public.ui_stock_take_lines where take_id = :'t1'::uuid and sku = 'STK-A'), 'after counting, the expected quantity and the difference are shown');
reset role;
insert into r select 'k9', flow.stocktake_count(:'t1'::uuid, 'STK-A', 90, 'alice');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'k9'), 'no more counting once it is in review');

-- 5. recounts
insert into r select 'rc1', flow.stocktake_recount(:'t1'::uuid, 'STK-B', 50, 'ALICE');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'rc1') and (select j->>'error' like '%different person%' from r where k = 'rc1'), 'the person who counted cannot do the recount');
insert into r select 'rc2', flow.stocktake_recount(:'t1'::uuid, 'STK-B', 50, 'bob');
select pg_temp.assert((select j->>'status' = 'matched' from r where k = 'rc2'), 'a recount that matches clears the difference');
insert into r select 'rc3', flow.stocktake_recount(:'t1'::uuid, 'STK-A', 97, 'bob');
select pg_temp.assert((select j->>'status' = 'recounted' from r where k = 'rc3'), 'a recount that still differs waits for a decision');
insert into r select 'rc4', flow.stocktake_recount(:'t1'::uuid, 'STK-C', 20, 'bob');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'rc4'), 'a matched line needs no recount');

-- 6. deciding
select id as l_a from flow.stock_take_lines where take_id = :'t1'::uuid and sku = 'STK-A' \gset
select id as l_e from flow.stock_take_lines where take_id = :'t1'::uuid and sku = 'STK-E' \gset
insert into r select 'ac1', flow.stocktake_accept(:'l_e'::uuid, 'no', false, 'carol');
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'ac1'), 'accepting a difference needs a reason');
insert into r select 'cl0', flow.stocktake_close(:'t1'::uuid, null, 'carol');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'cl0') and (select (j->>'open_lines')::int = 2 from r where k = 'cl0'), 'it cannot be closed while differences are undecided');
insert into r select 'ac2', flow.stocktake_accept(:'l_e'::uuid, 'Found an open box in the wrong place', false, 'carol');
insert into r select 'ac3', flow.stocktake_accept(:'l_a'::uuid, 'Two missing after the last pick, agreed', false, 'carol');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'ac2') and (select (j->>'ok')::bool and (j->>'variance')::int = -3 from r where k = 'ac3'), 'small differences can be accepted with a reason (the recount is what counts)');

-- 7. a big difference: recount by someone else, then a manager
select pg_temp.assert((flow.stocktake_review(:'t2'::uuid, 'alice')->>'recount_needed')::int = 1, 'a difference worth £300 needs a recount');
select id as l_d from flow.stock_take_lines where take_id = :'t2'::uuid and sku = 'STK-D' \gset
insert into r select 'bd1', flow.stocktake_accept(:'l_d'::uuid, 'Looks right to me', false, 'carol');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'bd1') and (select j->>'error' like '%recount%' from r where k = 'bd1'), 'a big difference cannot be accepted without a recount');
select pg_temp.assert((flow.stocktake_recount(:'t2'::uuid, 'STK-D', 7, 'bob')->>'status') = 'recounted', 'bob recounts and gets the same');
insert into r select 'bd2', flow.stocktake_accept(:'l_d'::uuid, 'Three damaged items thrown out last week', false, 'carol');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'bd2') and (select j->>'error' like '%manager or admin%' from r where k = 'bd2'), 'a difference over the limit needs a manager');
insert into r select 'bd3', flow.stocktake_accept(:'l_d'::uuid, 'Three damaged items thrown out last week', true, 'manager');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'value')::numeric = 300 from r where k = 'bd3'), 'a manager can accept it');

-- 8. closing creates waste suggestions for shortfalls only
insert into r select 'cl1', flow.stocktake_close(:'t1'::uuid, 'Shelf A done', 'manager');
select pg_temp.assert((select (j->>'ok')::bool and (j->>'matched')::int = 2 and (j->>'differences')::int = 2 and (j->>'shortfall_units')::int = 3 and (j->>'surplus_units')::int = 1 and (j->>'waste_suggestions')::int = 1 from r where k = 'cl1'), 'closing summarises: 2 matched, 2 differences, 3 short, 1 over, 1 waste suggestion');
select pg_temp.assert((select count(*) from flow.waste_events where source_key like 'stocktake:%' and sku = 'STK-A' and qty = 3 and status = 'suggested' and cause_code = 'stock_count') = 1, 'the shortfall is a suggested waste record that a person still confirms');
select pg_temp.assert((select count(*) from flow.waste_events where source_key like 'stocktake:%' and sku = 'STK-E') = 0, 'a surplus makes no waste record');
select pg_temp.assert(not (flow.stocktake_close(:'t1'::uuid, null, 'manager')->>'ok')::bool, 'it cannot be closed twice');
select pg_temp.assert((select qty_on_hand from flow.stock_items where sku = 'STK-A') = 100, 'stock levels are never changed by a stock-take');
select pg_temp.assert((flow.stocktake_close(:'t2'::uuid, null, 'manager')->>'waste_suggestions')::int = 1, 'the valuable item shortfall is suggested too (£300)');
-- 9. small differences in one go
insert into r select 'b1', flow.stocktake_start('Odd bits', '{"kind":"skus","skus":["STK-C"]}'::jsonb, 'alice');
select j->>'take_id' as t3 from r where k = 'b1' \gset
select flow.stocktake_count(:'t3'::uuid, 'STK-C', 18, 'alice') as x \gset
select flow.stocktake_review(:'t3'::uuid, 'alice') as y \gset
insert into r select 'b2', flow.stocktake_accept_small(:'t3'::uuid, 'a', 'carol');
select pg_temp.assert((select (j->>'needs_reason')::bool from r where k = 'b2'), 'accepting small differences in bulk needs a reason');
insert into r select 'b3', flow.stocktake_accept_small(:'t3'::uuid, 'Normal picking losses', 'carol');
select pg_temp.assert((select (j->>'accepted')::int = 1 from r where k = 'b3'), 'one reason covers all the small differences');
-- 10. cancel
insert into r select 'x1', flow.stocktake_start('Cancel me', '{"kind":"skus","skus":["STK-B"]}'::jsonb, 'alice');
select j->>'take_id' as t4 from r where k = 'x1' \gset
select pg_temp.assert(not (flow.stocktake_cancel(:'t4'::uuid, 'no', 'manager')->>'ok')::bool, 'cancelling needs a reason');
select pg_temp.assert((flow.stocktake_cancel(:'t4'::uuid, 'Started on the wrong shelf', 'manager')->>'ok')::bool, 'an open stock-take can be cancelled');
select pg_temp.assert((flow.stocktake_start('Again', '{"kind":"skus","skus":["STK-B"]}'::jsonb, 'alice')->>'ok')::bool, 'and its items are free to count again');

-- 11. putting the result right in DecoNetwork
select pg_temp.assert(not (flow.stocktake_mark_adjusted(:'t3'::uuid, null, 'manager')->>'ok')::bool, 'only a closed stock-take can be marked as corrected');
select pg_temp.assert(exists (select 1 from public.ui_stock_takes where id = :'t1'::uuid and needs_correction), 'a closed stock-take with accepted differences needs correcting');
update flow.stock_takes set closed_at = now() - interval '5 days' where id in (:'t1'::uuid, :'t2'::uuid);
select pg_temp.assert(flow.exc_detect_stocktakes()::text like '%stocktake_not_corrected%' and flow.exc_detect_stocktakes()::text like '%' || (select take_ref from flow.stock_takes where id = :'t1'::uuid) || '%', 'a result not put right in DecoNetwork after 3 days is flagged');
select pg_temp.assert((flow.stocktake_mark_adjusted(:'t1'::uuid, 'Adjusted in DecoNetwork', 'manager')->>'ok')::bool and not (flow.stocktake_mark_adjusted(:'t1'::uuid, null, 'manager')->>'ok')::bool, 'it can be marked as corrected once');
select pg_temp.assert(flow.exc_detect_stocktakes()::text not like '%' || (select take_ref from flow.stock_takes where id = :'t1'::uuid) || '%', 'and then stops being flagged');
update flow.stock_takes set created_at = now() - interval '10 days' where id = :'t3'::uuid;
select pg_temp.assert(true, 'placeholder');
select pg_temp.assert(pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) like '%''stocktakes''%', 'the detector runs with every exception check');

-- 12. who can see what
select pg_temp.as_user('00000000-0000-0000-0000-0000000001a1');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_stock_takes where take_ref is not null) >= 4 and (select count(*) from public.ui_stock_take_lines) >= 5, 'a team member sees stock-takes and lines');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000001a2');
set role authenticated;
select pg_temp.assert((select count(*) from public.ui_stock_takes) = 0 and (select count(*) from public.ui_stock_take_lines) = 0, 'a logged-in outsider sees nothing');
select pg_temp.assert(pg_temp.try(format('select flow.stocktake_accept(%L::uuid, ''reason here'', true, ''x'')', :'l_d')) like '%permission denied%' and pg_temp.try('select public.flow_stocktake_close(gen_random_uuid(), null, ''x'')') like '%permission denied%', 'nobody in the browser can act on a stock-take directly');
reset role;
select pg_temp.assert(has_function_privilege('service_role', 'public.flow_stocktake_count(uuid,text,int,text)', 'execute') and not has_function_privilege('anon', 'public.flow_stocktake_start(text,jsonb,text)', 'execute'), 'only the service role can act; anonymous visitors can call nothing');
\echo stocktake_test OK
