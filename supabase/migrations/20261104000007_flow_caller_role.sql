-- Lets n8n webhooks check a verified Supabase user's ATAM_FLOW role. Service role only.
create or replace function public.flow_caller_role(p_user uuid) returns text
language sql security definer set search_path = flow, public as $$
  select role::text from flow.user_roles where user_id = p_user
$$;
revoke all on function public.flow_caller_role(uuid) from public, anon, authenticated;
grant execute on function public.flow_caller_role(uuid) to service_role;
