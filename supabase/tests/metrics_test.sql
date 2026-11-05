-- Metrics views: dispatch on-time, downtime hours, first-pass yield, exception resolution, headline.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

-- Earlier suites leave history behind; start from an empty slate inside a transaction that is rolled back at the end.
begin;
update flow.orders set shipped_at = null;
truncate flow.exceptions, flow.rework_jobs, flow.qc_checks, flow.machine_downtime cascade;
delete from flow.supplier_stats; delete from flow.producer_stats;

-- shipped orders: 3 on time, 1 two days late, 1 old (outside 30 days)
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, shipped_at, order_status, total_units, deco_status) values
  ('MT1', '#MT1', 'A', now() - interval '3 days', now() - interval '4 days', 'dispatched', 10, 3), ('MT2', '#MT2', 'B', now() - interval '3 days', now() - interval '3 days', 'dispatched', 20, 3),
  ('MT3', '#MT3', 'C', now() - interval '6 days', now() - interval '6 days', 'dispatched', 30, 3), ('MT4', '#MT4', 'D', now() - interval '8 days', now() - interval '6 days', 'dispatched', 40, 3),
  ('MT5', '#MT5', 'E', now() - interval '60 days', now() - interval '58 days', 'dispatched', 50, 3);
select pg_temp.assert((select shipped_30d = 4 and on_time_pct_30d = 75.0 and avg_days_late_30d = 2.0 from flow.v_metric_headline), 'on-time 3 of 4, average 2 days late: ' || (select row_to_json(h)::text from flow.v_metric_headline h));
select pg_temp.assert((select sum(orders_shipped) = 5 and sum(late) = 2 from flow.v_metric_dispatch_daily), 'daily dispatch covers 90 days: ' || (select string_agg(day::text || ':' || orders_shipped || '/' || late, ', ') from flow.v_metric_dispatch_daily));
select pg_temp.assert((select shipped_7d = 4 and units_7d = 100 from flow.v_metric_headline), 'last 7 days: 4 orders, 100 units');

-- downtime
insert into flow.machines (code, name, method_code) values ('MT-M', 'Metric machine', 'embroidery');
select id as mm from flow.machines where code = 'MT-M' \gset
insert into flow.machine_downtime (machine_id, kind, planned, started_at, ended_at, capacity_factor, reason) values
  (:'mm', 'breakdown', false, now() - interval '10 hours', now() - interval '4 hours', 0, 'test'), (:'mm', 'maintenance', true, now() - interval '3 hours', now() - interval '1 hour', 0, 'service'), (:'mm', 'limited', false, now() - interval '30 hours', now() - interval '26 hours', 0.5, 'slow');
select pg_temp.assert((select hours_down = 8.0 and hours_unplanned = 6.0 and hours_reduced = 4.0 and incidents = 3 from flow.v_metric_downtime where code = 'MT-M'), 'downtime hours split into down, unplanned and reduced: ' || (select row_to_json(d)::text from flow.v_metric_downtime d where code = 'MT-M'));

-- quality
insert into flow.qc_checks (check_ref, order_id, gate, status, units_checked, units_failed, checked_at, defect_type, cause) select 'QC-MT-1', id, 'final', 'failed', 50, 5, now() - interval '1 day', 'stitching', 'operator' from flow.orders where deco_order_id = 'MT1';
insert into flow.qc_checks (check_ref, order_id, gate, status, units_checked, units_failed, checked_at) select 'QC-MT-2', id, 'final', 'passed', 50, 0, now() - interval '1 day' from flow.orders where deco_order_id = 'MT2';
insert into flow.qc_checks (check_ref, order_id, gate, status, units_checked, units_failed, checked_at) select 'QC-MT-3', id, 'recheck', 'passed', 5, 0, now() - interval '1 day' from flow.orders where deco_order_id = 'MT2';
insert into flow.rework_jobs (rework_ref, order_id, units, defect_type, cause, status, units_scrapped) select 'RW-MT-1', id, 5, 'stitching', 'operator', 'open', 0 from flow.orders where deco_order_id = 'MT1';
select pg_temp.assert((select first_pass_pct_30d = 95.0 and open_rework = 1 and rework_units_30d = 5 from flow.v_metric_headline), 're-checks do not inflate first-pass yield: ' || (select row_to_json(h)::text from flow.v_metric_headline h));
select pg_temp.assert((select sum(units_checked) = 100 and sum(units_failed) = 5 from flow.v_metric_quality_weekly) and (select units = 5 and cause = 'operator' from flow.v_metric_defects where defect_type = 'stitching'), 'weekly quality and defect breakdown');

-- exceptions
insert into flow.exceptions (exc_ref, type_code, dedupe_key, severity, status, description, detected_at, resolved_at, response_deadline) values
  ('EX-MT-1', 'po_late', 'mt:1', 'high', 'resolved', 'x', now() - interval '10 hours', now() - interval '2 hours', now() + interval '1 hour'),
  ('EX-MT-2', 'po_late', 'mt:2', 'high', 'resolved', 'x', now() - interval '30 hours', now() - interval '2 hours', now() - interval '20 hours'),
  ('EX-MT-3', 'stock_shortage', 'mt:3', 'medium', 'open', 'x', now() - interval '5 hours', null, now() - interval '1 hour');
select pg_temp.assert((select resolved_30d = 2 and avg_hours_to_resolve = 18.0 and past_deadline = 1 from flow.v_metric_exceptions where category = 'purchasing'), 'resolution time and breaches: ' || (select row_to_json(x)::text from flow.v_metric_exceptions x where category = 'purchasing'));
select pg_temp.assert((select open_now = 1 and past_deadline = 1 from flow.v_metric_exceptions where category = 'stock') and (select exceptions_open >= 1 from flow.v_metric_headline), 'open and past-deadline exceptions counted');

-- locked down
select pg_temp.assert(not has_table_privilege('anon', 'public.ui_metric_headline', 'select') and has_table_privilege('authenticated', 'public.ui_metric_headline', 'select'), 'metrics readable only when signed in');
rollback;
\echo metrics_test OK
