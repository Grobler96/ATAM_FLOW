-- Migration 45 rebuilt flow.exceptions_detect_all() from a copy that predates the holding pen, which silently removed the pen refresh that
-- migration 43 had added. Put it back. Safe to run any number of times: it only patches the function when the hook is missing, so it does nothing
-- on a database where 43 was applied after 45 (the live project).
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%pen_refresh%' then
    v_def := replace(v_def, '  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? ''error'');',
      E'  begin\n    v_res := v_res || jsonb_build_array(jsonb_build_object(''detector'', ''detector:pen'', ''result'', flow.pen_refresh()));\n  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object(''detector'', ''detector:pen'', ''error'', sqlerrm));\n  end;\n  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? ''error'');');
    if v_def not like '%pen_refresh%' then raise exception 'exceptions_detect_all anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;
