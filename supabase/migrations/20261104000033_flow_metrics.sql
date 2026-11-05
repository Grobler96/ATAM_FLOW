-- Metrics (R13): read-only views that turn the history ATAM_FLOW now keeps into the numbers the business asks for.
-- Nothing here changes data. "On time" = shipped on or before the promised dispatch date (DecoNetwork date_due).

create or replace view flow.v_metric_dispatch_daily with (security_invoker = true) as
select (o.shipped_at at time zone 'Europe/London')::date as day, count(*)::int as orders_shipped, coalesce(sum(o.total_units), 0)::int as units_shipped,
       count(*) filter (where o.due_date is not null and (o.shipped_at at time zone 'Europe/London')::date <= (o.due_date at time zone 'Europe/London')::date)::int as on_time,
       count(*) filter (where o.due_date is not null and (o.shipped_at at time zone 'Europe/London')::date > (o.due_date at time zone 'Europe/London')::date)::int as late
from flow.orders o where o.shipped_at is not null and o.shipped_at >= now() - interval '90 days'
group by 1;

-- Downtime in the last 30 days, per machine. Availability is on a calendar-hour basis (24h x 30 days) because per-machine shift calendars are not modelled.
create or replace view flow.v_metric_downtime with (security_invoker = true) as
select m.id as machine_id, m.code, m.name, m.method_code,
       coalesce(sum(extract(epoch from (least(coalesce(d.ended_at, now()), now()) - greatest(d.started_at, now() - interval '30 days'))) / 3600.0) filter (where d.capacity_factor = 0 and d.started_at < now()), 0)::numeric(8,1) as hours_down,
       coalesce(sum(extract(epoch from (least(coalesce(d.ended_at, now()), now()) - greatest(d.started_at, now() - interval '30 days'))) / 3600.0) filter (where d.capacity_factor > 0 and d.started_at < now()), 0)::numeric(8,1) as hours_reduced,
       coalesce(sum(extract(epoch from (least(coalesce(d.ended_at, now()), now()) - greatest(d.started_at, now() - interval '30 days'))) / 3600.0) filter (where d.capacity_factor = 0 and not d.planned and d.started_at < now()), 0)::numeric(8,1) as hours_unplanned,
       count(d.id) filter (where d.started_at < now())::int as incidents
from flow.machines m left join flow.machine_downtime d on d.machine_id = m.id and (d.ended_at is null or d.ended_at >= now() - interval '30 days') and d.started_at < now()
where m.is_active group by m.id;

create or replace view flow.v_metric_quality_weekly with (security_invoker = true) as
select date_trunc('week', c.checked_at)::date as week, count(*)::int as checks, coalesce(sum(c.units_checked), 0)::int as units_checked, coalesce(sum(c.units_failed), 0)::int as units_failed,
       case when coalesce(sum(c.units_checked), 0) > 0 then round(100.0 * (sum(c.units_checked) - coalesce(sum(c.units_failed), 0)) / sum(c.units_checked), 1) end as first_pass_pct
from flow.qc_checks c where c.status in ('passed', 'failed') and c.gate <> 'recheck' and c.checked_at >= now() - interval '12 weeks' group by 1;

create or replace view flow.v_metric_defects with (security_invoker = true) as
select r.defect_type, r.cause, count(*)::int as jobs, sum(r.units)::int as units, sum(r.units_scrapped)::int as units_scrapped
from flow.rework_jobs r where r.status <> 'cancelled' and r.created_at >= now() - interval '30 days' group by 1, 2;

create or replace view flow.v_metric_exceptions with (security_invoker = true) as
select t.category, count(*) filter (where e.detected_at >= now() - interval '30 days')::int as opened_30d,
       count(*) filter (where e.resolved_at >= now() - interval '30 days')::int as resolved_30d,
       count(*) filter (where e.status in ('open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer'))::int as open_now,
       round((avg(extract(epoch from (e.resolved_at - e.detected_at)) / 3600.0) filter (where e.resolved_at >= now() - interval '30 days'))::numeric, 1) as avg_hours_to_resolve,
       count(*) filter (where (e.resolved_at is not null and e.resolved_at >= now() - interval '30 days' and e.resolved_at > e.response_deadline)
                          or (e.status in ('open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer') and e.response_deadline < now()))::int as past_deadline
from flow.exceptions e join flow.exception_types t on t.code = e.type_code group by t.category;

create or replace view flow.v_metric_headline with (security_invoker = true) as
select
  (select count(*) from flow.orders where shipped_at >= now() - interval '30 days' and due_date is not null)::int as shipped_30d,
  (select round(100.0 * count(*) filter (where (shipped_at at time zone 'Europe/London')::date <= (due_date at time zone 'Europe/London')::date) / nullif(count(*), 0), 1) from flow.orders where shipped_at >= now() - interval '30 days' and due_date is not null) as on_time_pct_30d,
  (select round(avg((shipped_at at time zone 'Europe/London')::date - (due_date at time zone 'Europe/London')::date), 1) from flow.orders where shipped_at >= now() - interval '30 days' and due_date is not null and (shipped_at at time zone 'Europe/London')::date > (due_date at time zone 'Europe/London')::date) as avg_days_late_30d,
  (select count(*) from flow.orders where shipped_at >= now() - interval '7 days')::int as shipped_7d,
  (select count(*) from flow.orders where shipped_at >= now() - interval '14 days' and shipped_at < now() - interval '7 days')::int as shipped_prev_7d,
  (select coalesce(sum(total_units), 0) from flow.orders where shipped_at >= now() - interval '7 days')::int as units_7d,
  (select count(*) from flow.orders where is_active and shipped_at is null and due_date < now() and order_status not in ('dispatched'))::int as overdue_open,
  (select round(sum(hours_down), 1) from flow.v_metric_downtime) as downtime_hours_30d,
  (select first_pass_pct from (select round(100.0 * (sum(units_checked) - sum(units_failed)) / nullif(sum(units_checked), 0), 1) as first_pass_pct from flow.qc_checks where status in ('passed', 'failed') and gate <> 'recheck' and checked_at >= now() - interval '30 days') q) as first_pass_pct_30d,
  (select count(*) from flow.rework_jobs where status in ('open', 'in_progress'))::int as open_rework,
  (select coalesce(sum(units), 0) from flow.rework_jobs where status <> 'cancelled' and created_at >= now() - interval '30 days')::int as rework_units_30d,
  (select round(avg(on_time_rate), 1) from flow.supplier_stats where on_time_rate is not null) as supplier_on_time_pct,
  (select round(avg(on_time_rate), 1) from flow.producer_stats where on_time_rate is not null) as producer_on_time_pct,
  (select count(*) from flow.exceptions where status in ('open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer'))::int as exceptions_open,
  (select round((percentile_cont(0.5) within group (order by extract(epoch from (now() - detected_at)) / 3600.0))::numeric, 1) from flow.exceptions where status in ('open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer')) as exceptions_median_age_hours;

create or replace view public.ui_metric_dispatch_daily with (security_invoker = true) as select * from flow.v_metric_dispatch_daily;
create or replace view public.ui_metric_downtime with (security_invoker = true) as select * from flow.v_metric_downtime;
create or replace view public.ui_metric_quality_weekly with (security_invoker = true) as select * from flow.v_metric_quality_weekly;
create or replace view public.ui_metric_defects with (security_invoker = true) as select * from flow.v_metric_defects;
create or replace view public.ui_metric_exceptions with (security_invoker = true) as select * from flow.v_metric_exceptions;
create or replace view public.ui_metric_headline with (security_invoker = true) as select * from flow.v_metric_headline;

do $$
declare v text;
begin
  foreach v in array array['ui_metric_dispatch_daily', 'ui_metric_downtime', 'ui_metric_quality_weekly', 'ui_metric_defects', 'ui_metric_exceptions', 'ui_metric_headline'] loop
    execute format('revoke all on public.%I from public, anon', v); execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;
