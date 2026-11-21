-- 21 Nov 2026: routing rules never move an order that has already been dispatched (applied to the live project 21 Nov 2026 as "flow_rules_finished_orders").
-- The first live run of the order facts reader (21 Nov 2026) showed 4 of the 5 orders a rule "would change" were already dispatched. A dispatched order is
-- now left alone: it gets the existing 'protected' outcome (would be left alone and flagged) with a detail that says it has been dispatched. Still shadow
-- mode only. No table definition changes. The function is patched in place from its current definition and fails loudly if the line it patches is not found.

do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.rules_evaluate_order(uuid)'::regprocedure);
  v_new := replace(v_def,
    $a$  elsif o.scope_override is not null then v_out := 'manual_wins';$a$,
    $b$  elsif o.order_status = 'dispatched' then v_out := 'protected'; v_detail := 'This order has already been dispatched, so it is never moved. ' || v_detail;
  elsif o.scope_override is not null then v_out := 'manual_wins';$b$);
  if v_new = v_def then raise exception 'rules_evaluate_order: the line to patch was not found'; end if;
  execute v_new;
end $$;

-- Re-check every order with facts so existing decisions pick up the change.
select flow.rules_evaluate_all('migration 70');
