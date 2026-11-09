-- Exception escalation, in-app only (no emails yet). The ladder itself already exists (exceptions_escalate). This adds:
--  * a "due soon" warning before a deadline passes (in-app notification, once per deadline),
--  * a digest view per responsible role and an attention list that says WHY each issue needs a person
--    (overdue, escalated, due soon, critical with no owner, untouched for too long).
insert into flow.flow_settings (key, value, description) values
 ('exceptions.digest', '{"due_soon_hours": 4, "stale_hours": 48}'::jsonb,
  'In-app exception digest: warn this many hours before a response deadline; call an issue untouched after this many hours with no action.')
on conflict (key) do nothing;

create or replace function flow.exc_digest_cfg() returns jsonb language sql stable set search_path = flow, public as $$
  select '{"due_soon_hours": 4, "stale_hours": 48}'::jsonb || coalesce(flow.setting('exceptions.digest'), '{}'::jsonb)
$$;

create or replace function flow.exceptions_warn_due() returns int language plpgsql security definer set search_path = flow, public as $$
declare e record; v_n int := 0; v_h int := (flow.exc_digest_cfg()->>'due_soon_hours')::int;
begin
  for e in select x.* from flow.exceptions x
           where flow.exc_unresolved(x.status) and x.response_deadline > now() and x.response_deadline <= now() + make_interval(hours => v_h)
             and not exists (select 1 from flow.notifications n where n.kind = 'exception_due_soon' and n.entity_id = x.id and n.created_at > coalesce(x.escalated_at, x.detected_at)) loop
    perform flow.notify('exception_due_soon', case when e.severity in ('high', 'critical') then 'critical' else 'warning' end,
      'Due soon: ' || e.exc_ref, format('%s (respond by %s, %s)', e.description, to_char(e.response_deadline, 'DD Mon HH24:MI'), coalesce(e.owner, 'nobody owns it yet, ' || e.owner_role::text || ' is responsible')), 'exception', e.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Warn as part of the escalation run, so no new schedule is needed.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_escalate()'::regprocedure) into v_def;
  if v_def not like '%exceptions_warn_due%' then
    v_def := replace(v_def, 'return jsonb_build_object(''ok'', true, ''escalated'', v_n, ''items'', v_items);', 'return jsonb_build_object(''ok'', true, ''escalated'', v_n, ''items'', v_items, ''warned'', flow.exceptions_warn_due());');
    if v_def not like '%exceptions_warn_due%' then raise exception 'escalate anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

create or replace view flow.v_exception_flags with (security_invoker = true) as
with last_act as (select exception_id, max(at) as last_at from flow.exception_actions where actor is distinct from 'system' and action not in ('detected', 'updated', 'severity_raised', 'escalated') group by exception_id),
b as (
  select v.id, v.exc_ref, v.type_label, v.category, v.severity, v.severity_rank, v.status, v.description, v.owner, v.owner_role, v.needs_owner, v.response_deadline, v.is_overdue, v.escalation_level, v.is_blocking, v.order_refs,
         coalesce(a.last_at, v.detected_at) as last_activity,
         (v.response_deadline > now() and v.response_deadline <= now() + make_interval(hours => (flow.exc_digest_cfg()->>'due_soon_hours')::int)) as due_soon,
         (coalesce(a.last_at, v.detected_at) < now() - make_interval(hours => (flow.exc_digest_cfg()->>'stale_hours')::int)) as is_stale
  from flow.v_exceptions_open v left join last_act a on a.exception_id = v.id)
select b.*, array_remove(array[case when b.is_overdue then 'overdue' end, case when b.escalation_level > 0 then 'escalated' end, case when b.due_soon then 'due_soon' end,
    case when b.needs_owner and b.severity in ('high', 'critical') then 'no_owner' end, case when b.is_stale then 'untouched' end], null) as reasons
from b;

create or replace view public.ui_exception_attention with (security_invoker = true) as select * from flow.v_exception_flags where cardinality(reasons) > 0;

create or replace view public.ui_exception_digest with (security_invoker = true) as
select owner_role::text as owner_role, count(*) as open_count, count(*) filter (where is_overdue) as overdue, count(*) filter (where escalation_level > 0) as escalated,
       count(*) filter (where due_soon) as due_soon, count(*) filter (where needs_owner) as unowned, count(*) filter (where severity = 'critical') as critical,
       count(*) filter (where is_stale) as untouched, count(*) filter (where cardinality(reasons) > 0) as needs_attention
from flow.v_exception_flags group by owner_role;

do $$
begin
  revoke all on function flow.exceptions_warn_due() from public, anon, authenticated;
  revoke all on flow.v_exception_flags, public.ui_exception_attention, public.ui_exception_digest from public, anon;
  grant select on flow.v_exception_flags, public.ui_exception_attention, public.ui_exception_digest to authenticated;
end $$;
