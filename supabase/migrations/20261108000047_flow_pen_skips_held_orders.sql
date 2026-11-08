-- Orders that are On hold (in DecoNetwork, or held here on purpose) are paused deliberately, so they are not "something wrong" and stay out of the holding pen.
-- Live check on 8 Nov 2026: all 72 first-run pen cases were DecoNetwork On hold orders with no due date and no lines. They still show as On hold in the pipeline,
-- and when one resumes it is checked like any other order. Patches the live function body so it keeps whatever else is in it; safe to run twice.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.pen_refresh()'::regprocedure) into v_def;
  if v_def not like '%order_status <> ''on_hold''%' then
    v_def := replace(v_def, 'where o.is_active and o.order_status <> ''dispatched''', 'where o.is_active and o.order_status not in (''dispatched'', ''on_hold'')');
    if v_def not like '%''dispatched'', ''on_hold''%' then raise exception 'pen_refresh anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;
