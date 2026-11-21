-- 21 Nov 2026: re-checking every order after a rule change now includes inactive orders (applied to the live project 21 Nov 2026 as "flow_rules_recheck_inactive").
-- flow.rules_evaluate_all only looked at orders marked active, but the reader's save (flow.order_facts_ingest) checks every order it saves, active or not.
-- Inactive orders (dispatched ones are inactive) could therefore keep an old decision after a rule was added or changed. Found 21 Nov 2026 when four
-- dispatched orders kept "would change" after migration 70. The function is patched in place from its current definition and fails loudly if the
-- line it patches is not found. Still shadow mode only.

do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.rules_evaluate_all(text)'::regprocedure);
  v_new := replace(v_def,
    $a$from flow.order_facts f join flow.orders o on o.id = f.order_id where o.is_active loop$a$,
    $b$from flow.order_facts f join flow.orders o on o.id = f.order_id loop$b$);
  if v_new = v_def then raise exception 'rules_evaluate_all: the line to patch was not found'; end if;
  execute v_new;
end $$;

-- Refresh every decision now so the four dispatched orders pick up migration 70.
select flow.rules_evaluate_all('migration 72');
