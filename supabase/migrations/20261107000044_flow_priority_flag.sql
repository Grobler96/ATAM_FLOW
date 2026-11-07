-- The DecoNetwork "Priority Order" flag (API field is_priority; shown with a shield in DecoNetwork) marks an order as third-party work.
-- A small separate workflow reads that flag for recent orders and passes it here. The flag only sets flow.orders.third_party_flag;
-- a person's manual scope (scope_override) still wins. A flag that changes on an order we are already working on shows up as an order change to review.

create or replace function flow.log_order_change() returns trigger language plpgsql security definer set search_path = flow, public as $$
declare v_prot boolean; v_n int := 0;
begin
  if tg_op <> 'UPDATE' then return new; end if;
  v_prot := flow.oc_is_protected(new.id);
  if new.due_date is distinct from old.due_date and old.due_date is not null and (new.due_date at time zone 'Europe/London')::date is distinct from (old.due_date at time zone 'Europe/London')::date then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'due_date', 'Dispatch date', to_char(old.due_date at time zone 'Europe/London', 'DD Mon YYYY'), to_char(new.due_date at time zone 'Europe/London', 'DD Mon YYYY'), old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if new.total_units is distinct from old.total_units and old.total_units > 0 then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'total_units', 'Total units', old.total_units::text, new.total_units::text, old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if new.deco_status is distinct from old.deco_status and new.deco_status in (4, 6, 7) then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'deco_status', 'DecoNetwork status', coalesce((select label from flow.deco_status_map where code = old.deco_status), old.deco_status::text), coalesce((select label from flow.deco_status_map where code = new.deco_status), new.deco_status::text), old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if old.is_active and not new.is_active and new.shipped_at is null then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'is_active', 'Order no longer open in DecoNetwork', 'open', 'closed or removed', old.order_status::text, case when v_prot then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if new.shipping_method is distinct from old.shipping_method and old.shipping_method is not null then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'shipping_method', 'Shipping method', old.shipping_method, new.shipping_method, old.order_status::text, 'info'); v_n := v_n + 1;
  end if;
  if new.third_party_flag is distinct from old.third_party_flag and old.third_party_flag is not null then
    insert into flow.order_changes (order_id, order_ref, field, label, old_value, new_value, status_at_change, severity)
    values (new.id, new.order_ref, 'third_party_flag', 'DecoNetwork Priority Order flag (third-party)', case when old.third_party_flag then 'on' else 'off' end, case when new.third_party_flag then 'on' else 'off' end, old.order_status::text, case when v_prot and new.scope_override is null then 'high' else 'warning' end); v_n := v_n + 1;
  end if;
  if v_n > 0 and new.label_status = 'printed' and (new.due_date is distinct from old.due_date or new.total_units is distinct from old.total_units or new.shipping_method is distinct from old.shipping_method) then
    new.label_status := 'reprint_needed';
  end if;
  return new;
end $$;

create or replace function flow.sync_priority_flags(p_flags jsonb, p_triggered_by text default 'n8n') returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_run uuid; v_total int; v_on int := 0; v_off int := 0; v_unknown int := 0; v_changed int := 0; r record;
begin
  if p_flags is null or jsonb_typeof(p_flags) <> 'array' then return jsonb_build_object('ok', false, 'error', 'Expected a list of order ids with their priority flag.'); end if;
  insert into flow.flow_runs (workflow, triggered_by) values ('priority_flags', p_triggered_by) returning id into v_run;
  v_total := jsonb_array_length(p_flags);
  for r in select x.order_id, x.is_priority from jsonb_to_recordset(p_flags) as x(order_id text, is_priority boolean) where x.order_id is not null loop
    if r.is_priority then v_on := v_on + 1; else v_off := v_off + 1; end if;
    update flow.orders set third_party_flag = coalesce(r.is_priority, false) where deco_order_id = r.order_id and third_party_flag is distinct from coalesce(r.is_priority, false);
    if found then v_changed := v_changed + 1;
    elsif not exists (select 1 from flow.orders where deco_order_id = r.order_id) then v_unknown := v_unknown + 1;
    end if;
  end loop;
  update flow.flow_runs set status = 'success', finished_at = now(), summary = jsonb_build_object('read', v_total, 'flagged', v_on, 'not_flagged', v_off, 'changed', v_changed, 'not_in_flow', v_unknown) where id = v_run;
  return jsonb_build_object('ok', true, 'run_id', v_run, 'read', v_total, 'flagged', v_on, 'not_flagged', v_off, 'changed', v_changed, 'not_in_flow', v_unknown);
end $$;

create or replace function public.flow_sync_priority_flags(p_flags jsonb, p_triggered_by text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.sync_priority_flags(p_flags, p_triggered_by) $$;

do $$
begin
  revoke all on function public.flow_sync_priority_flags(jsonb,text) from public, anon, authenticated;
  grant execute on function public.flow_sync_priority_flags(jsonb,text) to service_role;
  revoke all on function flow.sync_priority_flags(jsonb,text) from public, anon, authenticated;
  revoke all on function flow.log_order_change() from public, anon, authenticated;
end $$;
