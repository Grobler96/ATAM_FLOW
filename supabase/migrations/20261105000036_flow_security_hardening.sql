-- Security hardening.
-- 1. flow.order_blocking_exceptions was executable by anon (found in the permission audit). Close it to anon and the
--    public pseudo-role, but keep it for logged-in users and the service role.
-- 2. New functions in flow are private by default from now on (each migration then grants only what is needed).
do $$
begin
  if to_regprocedure('flow.order_blocking_exceptions(uuid,text)') is not null then
    revoke execute on function flow.order_blocking_exceptions(uuid, text) from public, anon;
    grant execute on function flow.order_blocking_exceptions(uuid, text) to authenticated, service_role;
  end if;
end $$;

alter default privileges in schema flow revoke execute on functions from public;
