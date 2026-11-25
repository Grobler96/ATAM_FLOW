-- 25 Nov 2026: the DTF order email to Super Print, reworded and with a picture of each design (NOT YET APPLIED).
-- Daniel's feedback on the first real DTF email (DTF-2026-00002): the body is good (the supplier likes it), but
--   * it should open "Hi Supa print",
--   * it should say what to do if there are problems (reply to the email or call 0330 159 6344),
--   * it should be signed "Atam Support Team", and
--   * it needs a picture of each design, which helps the supplier.
-- The Picture column was empty because files imported from Google Drive have no preview image held in Flow. For an image file (PNG, JPG, GIF or WebP) the stored file
-- itself now serves as the picture, through the same download link the email already carries (it expires after 14 days, like the link). An embroidery or other
-- file that cannot be shown as a picture still has none.
-- Patched in place from the live function, and each change raises if its anchor is missing, so it can never silently do nothing. Emails already written are not changed.
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.dtf_build_order(uuid[],jsonb,text,text)'::regprocedure);
  v_new := v_def;

  -- 1. a picture: the design's own preview, else the stored image file through its download link
  v_new := replace(v_new, $a$        v_link text; v_missing int := 0; v_ids uuid[]; v_ordlist text;$a$, $b$        v_link text; v_missing int := 0; v_ids uuid[]; v_ordlist text; v_pic text;$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the declaration to patch was not found'; end if;
  v_def := v_new;
  v_new := replace(v_new, $a$    v_ordlist := (select string_agg(x, ', ') from jsonb_array_elements_text(d->'orders') x);$a$, $b$    v_ordlist := (select string_agg(x, ', ') from jsonb_array_elements_text(d->'orders') x);
    v_pic := coalesce(nullif(d->>'thumbnail_url', ''), case when lower(coalesce(d->>'file_format', '')) in ('png', 'jpg', 'jpeg', 'gif', 'webp') then nullif(v_link, '') end);$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the loop line to patch was not found'; end if;
  v_def := v_new;
  v_new := replace(v_new, $a$      || case when coalesce(d->>'thumbnail_url', '') <> '' then '<img src="' || flow.dtf_html_esc(d->>'thumbnail_url') || '" alt="" height="64" style="max-width:96px">' else '' end$a$, $b$      || case when coalesce(v_pic, '') <> '' then '<img src="' || flow.dtf_html_esc(v_pic) || '" alt="" height="64" style="max-width:96px">' else '' end$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the picture line to patch was not found'; end if;
  v_def := v_new;

  -- 2. the wording (plain text and HTML)
  v_new := replace(v_new, $a$v_text := 'Hello,' || E'\n\n' || 'Please could we order$a$, $b$v_text := 'Hi Supa print,' || E'\n\n' || 'Please could we order$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the plain-text greeting to patch was not found'; end if;
  v_def := v_new;
  v_new := replace(v_new, $a$reply if you need them again.\n\nThank you\n';$a$, $b$reply if you need them again.\n\nIf there are any problems, please don''t hesitate to contact us by replying to this email or by calling us on 0330 159 6344.\n\nThank you\nAtam Support Team\n';$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the plain-text ending to patch was not found'; end if;
  v_def := v_new;
  v_new := replace(v_new, $a$v_html := '<p>Hello,</p><p>Please could we order$a$, $b$v_html := '<p>Hi Supa print,</p><p>Please could we order$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the HTML greeting to patch was not found'; end if;
  v_def := v_new;
  v_new := replace(v_new, $a$reply if you need them again.</p><p>Thank you</p>';$a$, $b$reply if you need them again.</p><p>If there are any problems, please don''t hesitate to contact us by replying to this email or by calling us on 0330 159 6344.</p><p>Thank you<br>Atam Support Team</p>';$b$);
  if v_new = v_def then raise exception 'dtf_build_order: the HTML ending to patch was not found'; end if;

  execute v_new;
end $$;
