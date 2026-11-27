-- 27 Nov 2026: Drive artwork files that waited for their order are now picked up when it arrives (NOT YET APPLIED to the live project).
-- Audit finding: about 178 Drive files (mostly embroidery) sat as "waiting - the order is not in Flow yet" although 31 of their 36 orders are now in Flow with the matching
-- line. The n8n job only lists Drive files created in the last 7 days (up to 500), and Flow only re-checked the files in that list, so a file whose order arrived later than
-- the list covered it was never looked at again, and the order's artwork stayed blocked. Also, 12 files for order 636850 have sat as "ready" since 23 Nov (the first
-- upload did not arrive) and are never retried.
--   1. flow.drive_recheck(seen, limit): looks at the design files Flow already knows about that are waiting or ready and were NOT in this run's Drive list. A waiting file whose
--      order and line are now in Flow becomes ready and is handed to the job to fetch (up to the limit, counting a try each time). A ready file that has used its 5 tries is marked failed
--      so it shows up instead of sitting there forever. A file whose order is in Flow but no longer active (shipped or closed: for example the 12 for order 636850) is set aside as ignored.
--      Files whose order is still missing from Flow are left waiting.
--   2. flow.drive_plan calls it after the files in the list, so the n8n job needs no change (it already fetches whatever the plan returns, by Drive file id).
--   3. flow.drive_import takes a lock per order, line and area first. Two files for the same area imported at the same moment each saw the same old version, and the second one failed
--      with "duplicate key value violates unique constraint artwork_current_area" (seen in the n8n runs of 24 and 26 Nov). Waiting for the lock lets the second one see the first.
-- drive_plan and drive_import are patched in place from the live text and raise if an anchor is missing, so they can never silently do nothing.
create or replace function flow.drive_recheck(p_seen text[], p_limit int) returns jsonb
language plpgsql security definer set search_path to 'flow', 'public' as $$
declare r flow.drive_files; cur flow.drive_files; v_ord uuid; v_act boolean; v_out jsonb := '[]'::jsonb; v_n int := 0;
begin
  for r in select * from flow.drive_files
           where kind = 'design' and status in ('waiting', 'ready') and not (drive_file_id = any (coalesce(p_seen, '{}'::text[])))
           order by first_seen limit 500 loop
    select id, is_active into v_ord, v_act from flow.orders where deco_order_id = r.deco_order_id;
    if v_ord is not null and not v_act then
      update flow.drive_files set status = 'ignored', reason = 'The order is no longer active, so this file was not applied' where drive_file_id = r.drive_file_id;
      continue;
    end if;
    if v_ord is null or not exists (select 1 from flow.order_lines where order_id = v_ord and deco_line_id = r.line_id) then continue; end if;
    if r.status = 'ready' and r.attempts >= 5 then
      update flow.drive_files set status = 'failed', reason = 'Could not be fetched or stored after 5 tries' where drive_file_id = r.drive_file_id;
      continue;
    end if;
    if r.status = 'waiting' then update flow.drive_files set status = 'ready', reason = null where drive_file_id = r.drive_file_id; end if;
    if v_n < greatest(coalesce(p_limit, 0), 0) then
      update flow.drive_files set attempts = attempts + 1 where drive_file_id = r.drive_file_id and attempts < 5 returning * into cur;
      if cur.drive_file_id is not null then
        v_n := v_n + 1;
        v_out := v_out || jsonb_build_array(jsonb_build_object('drive_file_id', cur.drive_file_id, 'name', cur.name, 'md5', cur.md5, 'size', cur.size_bytes,
          'storage_path', 'drive/' || cur.deco_order_id || '/' || cur.line_id || '/' || cur.drive_file_id || '-' || regexp_replace(cur.name, '[^A-Za-z0-9._-]', '_', 'g')));
      end if;
    end if;
  end loop;
  return v_out;
end $$;
revoke all on function flow.drive_recheck(text[], int) from public, anon, authenticated;

do $patch$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.drive_plan(jsonb,integer)'::regprocedure);
  v_new := replace(v_def, $a$c_fail int := 0;$a$, $b$c_fail int := 0; v_seen text[] := '{}'::text[]; v_extra jsonb;$b$);
  if v_new = v_def then raise exception 'drive_plan: the declaration was not found, nothing changed'; end if; v_def := v_new;
  v_new := replace(v_def, $a$if coalesce(f->>'id', '') = '' then continue; end if;$a$, $b$if coalesce(f->>'id', '') = '' then continue; end if; v_seen := v_seen || (f->>'id');$b$);
  if v_new = v_def then raise exception 'drive_plan: the file loop was not found, nothing changed'; end if; v_def := v_new;
  v_new := replace(v_def, $a$return jsonb_build_object('ok', true, 'to_import', v_out,$a$, $b$v_extra := flow.drive_recheck(v_seen, greatest(p_limit, 1) - v_n); v_out := v_out || v_extra; v_n := v_n + jsonb_array_length(v_extra); return jsonb_build_object('ok', true, 'rechecked', jsonb_array_length(v_extra), 'to_import', v_out,$b$);
  if v_new = v_def then raise exception 'drive_plan: the return was not found, nothing changed'; end if;
  execute v_new;

  v_def := pg_get_functiondef('flow.drive_import(text,text,text)'::regprocedure);
  v_new := replace(v_def, $a$v_proc := flow.drive_process(d.process_code);$a$, $b$perform pg_advisory_xact_lock(hashtextextended('drive_import|' || coalesce(d.deco_order_id, '') || '|' || coalesce(d.line_id, '') || '|' || lower(coalesce(d.area, '')), 0));
  v_proc := flow.drive_process(d.process_code);$b$);
  if v_new = v_def then raise exception 'drive_import: the process line was not found, nothing changed'; end if;
  execute v_new;
end $patch$;
