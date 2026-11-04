-- n8n entry points. Thin wrappers in `public` so n8n can call the sync functions through the normal REST
-- /rpc endpoint WITHOUT exposing the `flow` schema. Callable by the service role only (never browser/anon).

create or replace function public.flow_sync_orders(p_triggered_by text default 'n8n') returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.sync_orders(p_triggered_by) $$;
create or replace function public.flow_sync_stock(p_triggered_by text default 'n8n') returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.sync_stock(p_triggered_by) $$;
create or replace function public.flow_sync_purchase_orders(p_triggered_by text default 'n8n') returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.sync_purchase_orders(p_triggered_by) $$;

-- Latest run per workflow, for the dashboard "last sync" tile and health checks.
create or replace function public.flow_last_runs() returns jsonb
language sql security definer set search_path = flow, public as $$
  select coalesce(jsonb_object_agg(workflow, to_jsonb(r)), '{}'::jsonb) from (
    select distinct on (workflow) workflow, id as run_id, status, started_at, finished_at, summary, error
    from flow.flow_runs order by workflow, started_at desc) r
$$;

do $$
declare f text;
begin
  foreach f in array array['flow_sync_orders(text)','flow_sync_stock(text)','flow_sync_purchase_orders(text)','flow_last_runs()']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- Evidence for confirming DecoNetwork status codes (flow.deco_status_map). One row per code.
create or replace view flow.v_status_code_report with (security_invoker = true) as
select u.order_status as code, m.label, m.is_open, m.is_assumed, count(*) as orders,
       count(u.date_shipped) as with_ship_date, count(u.date_produced) as with_produced_date,
       count(*) filter (where u.dismissed_at is not null) as dismissed_in_atam_go,
       min(u.date_due)::date as earliest_due, max(u.date_due)::date as latest_due,
       (array_agg(u.customer_name order by u.date_due desc nulls last))[1:3] as example_customers
from public.upcoming_orders u
left join flow.deco_status_map m on m.code = u.order_status
group by u.order_status, m.label, m.is_open, m.is_assumed;
