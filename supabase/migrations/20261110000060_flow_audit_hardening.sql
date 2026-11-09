-- Findings from the independent permissions audit (10 Nov 2026), flow schema only.
-- 1. Three crew history views were plain (owner-rights) views that any logged-in user could read, bypassing row level security.
--    They are only ever read inside security definer functions, so logged-in users lose direct access.
-- 2. flow.order_blocking_exceptions answered for any logged-in user. It now answers only for the team (or the service role).
-- Neither was reachable through the public API today (the flow schema is not exposed); this closes them anyway.
do $$
declare v text;
begin
  foreach v in array array['v_operator_history', 'v_operator_customer_history', 'v_operator_quality'] loop
    if to_regclass('flow.' || v) is not null then execute format('revoke all on flow.%I from public, anon, authenticated', v); end if;
  end loop;
end $$;

do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.order_blocking_exceptions(uuid,text)'::regprocedure) into v_def;
  if v_def not like '%auth.uid() is null or flow.is_member()%' then
    v_def := regexp_replace(v_def, '\n  \) x\n', E'\n  ) x\n  where auth.uid() is null or flow.is_member()\n');
    if v_def not like '%auth.uid() is null or flow.is_member()%' then raise exception 'order_blocking_exceptions anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;
