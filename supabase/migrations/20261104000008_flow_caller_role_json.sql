-- Return an object ({"role": "admin"|null}) instead of a bare string so REST/n8n response shape is deterministic.
drop function if exists public.flow_caller_role(uuid);
create function public.flow_caller_role(p_user uuid) returns jsonb
language sql security definer set search_path = flow, public as $$
  select jsonb_build_object('role', (select role::text from flow.user_roles where user_id = p_user))
$$;
revoke all on function public.flow_caller_role(uuid) from public, anon, authenticated;
grant execute on function public.flow_caller_role(uuid) to service_role;
