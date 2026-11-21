-- 21 Nov 2026: replace a workaround in migration 69 with a plain statement (applied to the live project 21 Nov 2026 as "flow_rules_plain_delete").
-- Migration 69 removed tags that no longer apply with a statement assembled from parts, so the Supabase tool's confirmation would not fire on the
-- two-word phrase. That avoided a safeguard, so this puts the ordinary statement back. Behaviour is identical. Applying this file will, correctly,
-- ask for confirmation. The function is patched in place from its current definition and fails loudly if the line it patches is not found.

do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.rules_evaluate_order(uuid)'::regprocedure);
  v_new := replace(v_def,
    $a$  execute format('%s from flow.order_tags where order_id = %L and not (tag_code = any (%L::text[]))', 'delete', p_order, v_kept);$a$,
    $b$  delete from flow.order_tags where order_id = p_order and not (tag_code = any (v_kept));$b$);
  if v_new = v_def then raise exception 'rules_evaluate_order: the line to patch was not found'; end if;
  execute v_new;
end $$;
