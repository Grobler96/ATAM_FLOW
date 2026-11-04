-- Read-only views for the browser dashboard, published in the public schema so the whole flow schema does not have to be exposed to the API.
-- They are security_invoker: the signed-in person's own access (flow.is_member / RLS) still decides what they can see. Anonymous users get nothing.

-- Record every detection run so the dashboard can show "last checked" and so a stalled detector can be spotted.
create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity'] loop
    begin
      execute format('select flow.exc_detect_%s()', d) into v_rows;
      v_res := v_res || jsonb_build_array(flow.exc_sync('detector:' || d, v_rows));
    exception when others then
      v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:' || d, 'error', sqlerrm));
      perform flow.notify('detector_failed', 'warning', 'Exception detector failed: ' || d, sqlerrm, null, null);
    end;
  end loop;
  begin
    v_res := v_res || jsonb_build_array(flow.exc_sync('detector:completed_open', flow.exc_detect_completed_open()));
  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:completed_open', 'error', sqlerrm));
  end;
  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? 'error');
  v_out := jsonb_build_object('ok', v_ok, 'at', now(), 'detectors', v_res,
    'open_now', (select count(*) from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')),
    'critical_open', (select count(*) from flow.exceptions where severity = 'critical' and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')));
  insert into flow.flow_runs (workflow, status, triggered_by, started_at, finished_at, summary, error)
  values ('exceptions', case when v_ok then 'success' else 'partial' end::flow.run_status, 'detector', v_start, clock_timestamp(),
          jsonb_build_object('open_now', v_out->'open_now', 'critical_open', v_out->'critical_open'),
          (select string_agg(x->>'detector' || ': ' || (x->>'error'), '; ') from jsonb_array_elements(v_res) x where x ? 'error'));
  return v_out;
end $$;

create or replace view public.ui_exceptions with (security_invoker = true) as select * from flow.v_exceptions_open;
create or replace view public.ui_exception_summary with (security_invoker = true) as select * from flow.v_exception_summary;
create or replace view public.ui_exception_history with (security_invoker = true) as select * from flow.v_exception_history;
create or replace view public.ui_order_accountability with (security_invoker = true) as select * from flow.v_order_accountability;
create or replace view public.ui_exception_types with (security_invoker = true) as select code, label, category, default_severity, blocks, owner_role, recommended_action from flow.exception_types where is_active;
create or replace view public.ui_status with (security_invoker = true) as
  select (select max(finished_at) from flow.flow_runs where workflow = 'exceptions' and status in ('success','partial')) as last_detection_at, now() as server_time;

create or replace function public.ui_my_role() returns text language sql stable security definer set search_path = flow, public as $$
  select role::text from flow.user_roles where user_id = auth.uid()
$$;

revoke all on public.ui_exceptions, public.ui_exception_summary, public.ui_exception_history, public.ui_order_accountability, public.ui_exception_types, public.ui_status from public, anon;
grant select on public.ui_exceptions, public.ui_exception_summary, public.ui_exception_history, public.ui_order_accountability, public.ui_exception_types, public.ui_status to authenticated;
revoke all on function public.ui_my_role() from public, anon;
grant execute on function public.ui_my_role() to authenticated;
