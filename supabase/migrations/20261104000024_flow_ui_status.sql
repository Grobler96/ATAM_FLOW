-- Freshness of every integration (status bar, sync pill) and recent notifications (bell).
create or replace view public.ui_sync_runs with (security_invoker = true) as
  select workflow, max(started_at) as last_run_at, max(started_at) filter (where status in ('success','partial')) as last_ok_at,
         (array_agg(status::text order by started_at desc))[1] as last_status, (array_agg(error order by started_at desc))[1] as last_error
  from flow.flow_runs group by workflow;
create or replace view public.ui_notifications with (security_invoker = true) as
  select id, created_at, kind, severity, title, body, entity_type, entity_id, read_at from flow.notifications order by created_at desc limit 60;
revoke all on public.ui_sync_runs, public.ui_notifications from public, anon;
grant select on public.ui_sync_runs, public.ui_notifications to authenticated;
