-- Behavioural tests for the sync functions + allocation guard. Run after bootstrap + migrations.
-- Any failed assertion raises and aborts (psql -v ON_ERROR_STOP=1).
\set ON_ERROR_STOP on
set role service_role;

create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

reset role;
-- ---- source fixtures ----
insert into public.job_settings values (1, 0.5, 600, 20);
insert into public.sku_inventory values
  ('HB475NAVM','Polo','Navy','M',20,now()), ('PR616BLKL','Hoodie','Black','L',5,now());
insert into public.upcoming_orders (order_id, customer_name, order_status, date_due, date_ordered, total_quantity,
    processes, is_production_complete, synced_at, billable_amount, payment_status, date_shipped, dismissed_at) values
  ('1001','Northside FC', 9, now() + interval '2 days', now() - interval '3 days', 45, '{WEMB,DTF}', false, now(), 500, 5, null, null),
  ('1002','Shipped Ltd',  3, now() - interval '9 days', now() - interval '20 days', 10, '{WEMB}', true, now(), 90, 5, now() - interval '8 days', null),
  ('1003','Dismissed Co', 7, now() + interval '5 days', now(), 5, '{DTF}', false, now(), 40, 5, null, now()),
  ('1004','Odd Process',  7, now() + interval '3 days', now(), 8, '{WEMB,FOIL}', false, now(), 80, 5, null, null);
insert into public.sales_order_lines (order_id, line_id, workflow_item_id, product_name, product_code, sku, option_name,
    size, qty_required, qty_produced, qty_shipped, production_status) values
  ('1001','L1','W1','Coolplus polo shirt','HB475','HB475NAVM','Navy','M', 30, 0, 0, 40),
  ('1001','L1','W2','Coolplus polo shirt','HB475','HB475NAVL','Navy','L', 15, 0, 0, 40),
  ('1002','L2','W3','Hoodie','PR616','PR616BLKL','Black','L', 10, 10, 10, 80),
  ('1004','L4','W4','Hoodie','PR616','PR616BLKL','Black','L', 8, 0, 0, 40);
insert into public.job_lines (order_id, line_id, supplier, processes, emb_areas, stitches_per_piece, qty) values
  ('1001','L1','Ralawise','{WEMB}', 2, 6000, 45);
insert into public.purchase_orders (id, po_number, vendor, status, date_raised, date_delivery, qty_ordered, qty_received, lines) values
  (1,'P1','Ralawise',3, now() - interval '2 days', now() + interval '3 days', 100, 0,
     '[{"sku":"HB475NAVL","qty_ordered":100,"qty_received":0,"product_name":"Polo"},{"sku":"","qty_ordered":5,"qty_received":0,"product_name":"EMB charge"}]'),
  (2,'P2','Portwest',5, now() - interval '5 days', now() - interval '1 day', 10, 10,
     '[{"sku":"PR616BLKL","qty_ordered":10,"qty_received":10,"product_name":"Hoodie"}]');

-- ---- sync_orders ----
set role service_role;
create temp table r1 as select flow.sync_orders('test') j;
select pg_temp.assert((select (j->>'ok')::bool from r1), 'sync_orders ok');
select pg_temp.assert((select (j->>'orders_inserted')::int from r1) = 2, 'inserts 1001 + 1004 only (1002 shipped, 1003 dismissed)');
select pg_temp.assert((select (j->>'lines_inserted')::int from r1) = 3, '3 lines for active orders');
select pg_temp.assert((select j->'unmapped_process_codes' @> '["FOIL"]' from r1), 'unknown process FOIL reported, not dropped');
select pg_temp.assert((select count(*) from flow.flow_runs where workflow='sync_orders' and status='partial') = 1, 'run logged as partial');
select pg_temp.assert((select decoration_methods = '{dtf,embroidery}' from flow.orders where deco_order_id='1001'), 'methods mapped');
select pg_temp.assert((select garment_type is not null from flow.order_lines where deco_workflow_item_id='W1'), 'garment type derived');
-- est minutes: 30 * (6000/600 + 0.5) = 315
select pg_temp.assert((select est_minutes = 315 from flow.order_lines where deco_workflow_item_id='W1'), 'embroidery estimate uses stitches');

-- idempotent: second run changes nothing
create temp table r2 as select flow.sync_orders('test') j;
select pg_temp.assert((select (j->>'orders_inserted')::int + (j->>'orders_updated')::int + (j->>'lines_inserted')::int + (j->>'lines_updated')::int from r2) = 0, 'second sync is a no-op');
select pg_temp.assert((select count(*) from flow.orders) = 2, 'no duplicate orders');

-- flow-owned fields survive a source change
update flow.orders set priority = 2, is_vip = true, order_status = 'in_production', production_notes = 'keep me' where deco_order_id='1001';
reset role;
update public.upcoming_orders set total_quantity = 50, synced_at = now() where order_id='1001';
set role service_role;
create temp table r3 as select flow.sync_orders('test') j;
select pg_temp.assert((select (j->>'orders_updated')::int from r3) = 1, 'source change detected');
select pg_temp.assert((select total_units = 50 and priority = 2 and is_vip and order_status='in_production' and production_notes='keep me'
                       from flow.orders where deco_order_id='1001'), 'sync updates source fields, never flow-owned ones');

-- order later ships in DecoNetwork -> closed + dispatched
reset role;
update public.upcoming_orders set date_shipped = now(), order_status = 3 where order_id='1001';
set role service_role;
select flow.sync_orders('test');
select pg_temp.assert((select not is_active and order_status = 'dispatched' from flow.orders where deco_order_id='1001'), 'shipped order closed');

-- ---- sync_stock ----
create temp table s1 as select flow.sync_stock('test') j;
select pg_temp.assert((select (j->>'ok')::bool from s1), 'sync_stock ok');
select pg_temp.assert((select count(*) from flow.stock_items where sku in ('HB475NAVM','PR616BLKL') and not is_placeholder) = 2, 'inventory loaded');
select pg_temp.assert((select count(*) from flow.stock_items where sku='PR616BLKL' ) = 1, 'no duplicate stock rows');
create temp table s2 as select flow.sync_stock('test') j;
select pg_temp.assert((select (j->>'stock_inserted')::int + (j->>'stock_updated')::int from s2) = 0, 'second stock sync is a no-op');
reset role;
update public.sku_inventory set qty_on_hand = 18 where sku='HB475NAVM';
set role service_role;
select flow.sync_stock('test');
select pg_temp.assert((select qty = -2 from flow.stock_movements where movement_type='sync_adjust' limit 1), 'on-hand change written to ledger');

-- ---- sync_purchase_orders ----
create temp table p1 as select flow.sync_purchase_orders('test') j;
select pg_temp.assert((select (j->>'ok')::bool from p1), 'sync_pos ok');
select pg_temp.assert((select count(*) from flow.po_lines) = 2, 'service line with empty SKU skipped');
select pg_temp.assert((select qty_outstanding = 100 from flow.po_lines where sku='HB475NAVL'), 'outstanding computed');
select pg_temp.assert((select is_active from flow.purchase_orders where deco_po_id=1) and not (select is_active from flow.purchase_orders where deco_po_id=2), 'only inbound PO active');
create temp table p2 as select flow.sync_purchase_orders('test') j;
select pg_temp.assert((select (j->>'pos_inserted')::int + (j->>'pos_updated')::int + (j->>'lines_inserted')::int + (j->>'lines_updated')::int from p2) = 0, 'second PO sync is a no-op');

-- ---- position view: incoming never counts as available ----
select flow.sync_orders('test');  -- picks up 1004 line and placeholder demand
select flow.sync_stock('test');
select pg_temp.assert((select qty_available = 0 and qty_incoming = 100 from flow.v_stock_position where sku='HB475NAVL'), 'incoming stock separate from available');
select pg_temp.assert((select is_placeholder from flow.stock_items where sku='HB475NAVL'), 'unknown SKU on open order becomes placeholder');

-- ---- allocation guard (double-allocation) ----
insert into flow.orders (deco_order_id, order_ref) values ('A1','#A1'), ('A2','#A2');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, qty_required)
  select 'AW1', id, 'PR616BLKL', 4 from flow.orders where deco_order_id='A1'
  union all select 'AW2', id, 'PR616BLKL', 4 from flow.orders where deco_order_id='A2';
insert into flow.allocations (order_id, order_line_id, stock_item_id, qty, reason)
  select l.order_id, l.id, (select id from flow.stock_items where sku='PR616BLKL'), 4, 't'
  from flow.order_lines l where deco_workflow_item_id='AW1';           -- 4 of 5 reserved
do $$ begin
  begin
    insert into flow.allocations (order_id, order_line_id, stock_item_id, qty, reason)
      select l.order_id, l.id, (select id from flow.stock_items where sku='PR616BLKL'), 4, 't'
      from flow.order_lines l where deco_workflow_item_id='AW2';       -- would be 8 of 5
    raise exception 'ASSERT FAILED: over-allocation was allowed';
  exception when check_violation then null; end;
end $$;
-- duplicate active allocation for same line/stock is rejected (idempotent upserts only)
do $$ begin
  begin
    insert into flow.allocations (order_id, order_line_id, stock_item_id, qty)
      select l.order_id, l.id, (select id from flow.stock_items where sku='PR616BLKL'), 1
      from flow.order_lines l where deco_workflow_item_id='AW1';
    raise exception 'ASSERT FAILED: duplicate active allocation allowed';
  exception when unique_violation then null; end;
end $$;
select pg_temp.assert((select qty_reserved = 4 and qty_available = 1 from flow.v_stock_position where sku='PR616BLKL'), 'reserved/available correct');

-- ledger is append-only
do $$ begin
  begin delete from flow.stock_movements; raise exception 'ASSERT FAILED: ledger delete allowed';
  exception when raise_exception then
    if sqlerrm like 'ASSERT%' then raise; end if; end;
end $$;

-- bins: generator is idempotent
select pg_temp.assert(flow.generate_bins('STG','B12',4) = 4, 'bins generated');
select pg_temp.assert(flow.generate_bins('STG','B12',4) = 0, 'bin generation idempotent');
select pg_temp.assert((select bin_code from flow.bins order by bin_code limit 1) = 'B12-01', 'bin code format');

-- ---- RLS: non-member sees nothing, member sees data ----
reset role;
insert into auth.users values ('00000000-0000-0000-0000-0000000000aa');
insert into flow.user_roles values ('00000000-0000-0000-0000-0000000000aa','viewer');
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000bb', false);
select pg_temp.assert((select count(*) from flow.orders) = 0, 'non-member sees no orders');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000aa', false);
select pg_temp.assert((select count(*) from flow.orders) > 0, 'member sees orders');
do $$ begin
  begin update flow.flow_settings set value='1'::jsonb where key='scheduling.horizon_days';
        if found then raise exception 'ASSERT FAILED: viewer edited settings'; end if;
  exception when insufficient_privilege then null; end;
end $$;
do $$ begin
  begin perform flow.sync_orders('browser'); raise exception 'ASSERT FAILED: browser can call sync';
  exception when insufficient_privilege then null; end;
end $$;

\echo ALL TESTS PASSED
