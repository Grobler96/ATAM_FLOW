-- 26 Nov 2026: staff could not raise purchase orders (APPLIED to the live project 26 Nov 2026 as "flow_buy_lines_grant" and "flow_buy_lines_guard").
-- "Raise purchase orders" said "No orders need stock buying right now" for everyone, for any order. Cause: public.ui_order_buy_lines (migration 67) reads
-- flow.po_requirements(), the view runs with the caller's rights, and logged-in users had never been allowed to run that function ("permission denied for function
-- po_requirements"), so the dashboard got no rows. The database tests missed it because they run with full rights.
-- The function is security definer and had no check of its own, so before it is opened to logged-in users it gets one: it returns nothing unless the caller is a team member
-- (or there is no login at all, which is how the server-side jobs call it). Patched in place from the live text; raises if the anchor is missing.
do $patch$
declare v_def text := pg_get_functiondef('flow.po_requirements(uuid[])'::regprocedure); v_new text;
begin
  v_new := replace(v_def, $a$  where o.is_active and not o.stock_secured$a$, $b$  where (auth.uid() is null or flow.is_member()) and o.is_active and not o.stock_secured$b$);
  if v_new = v_def then raise exception 'po_requirements: the where clause was not found, nothing changed'; end if;
  execute v_new;
end $patch$;
grant execute on function flow.po_requirements(uuid[]) to authenticated;
