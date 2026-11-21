-- 21 Nov 2026: embroidery, step 2b: emailing the swatch to the customer from Flow, with an editable template. (APPLIED to the live project on 21 Nov 2026)
-- A new logo needs a physical swatch, sent to the customer to sign off. This queues that email through the NORMAL approval queue (Purchasing > Emails,
-- kind "other", review required): nothing is sent until a person approves it, and the live sender (which cannot attach files) sends the swatch PHOTO as
-- a picture and link inside the email. Replies come back to the shared mailbox; staff then mark the swatch approved or changes needed.
--   * flow.email_templates: wording staff can edit and add to (kind "embroidery_swatch"). One is the default. Placeholders such as {customer}, {logo},
--     {order_ref}, {placement} and {round} are filled in by the dashboard before staff see the text; the saved subject and body are what is sent.
--   * flow.emb_swatches: one row per swatch email (design, round, order and area, recipients, photo, the queued message, queued / sent / cancelled).
--   * flow.emb_swatch_send: checks everything, builds a safe HTML email (all text escaped) with the logo visual and the swatch photo, and queues it.
--   * Sending it (flow.comm_mark_sent, patched in place) moves a design that is "swatch in progress" to "swatch sent"; cancelling it
--     (flow.comm_cancel, patched in place) marks the swatch email cancelled and leaves the design where it was.
-- Staff write through the n8n "Pre-production actions" workflow (service role only).

create table flow.email_templates (
  code        text primary key,
  kind        text not null check (kind in ('embroidery_swatch')),
  name        text not null,
  subject     text not null,
  body        text not null,
  is_default  boolean not null default false,
  is_active   boolean not null default true,
  created_by  text,
  created_at  timestamptz not null default now(),
  updated_by  text,
  updated_at  timestamptz not null default now()
);
create unique index email_templates_one_default on flow.email_templates (kind) where is_default and is_active;
insert into flow.email_templates (code, kind, name, subject, body, is_default, created_by) values
 ('embroidery_swatch_default', 'embroidery_swatch', 'Swatch for approval (standard)',
  'Your embroidery sample for approval: {logo} ({order_ref})',
  E'Hello {customer},\n\nBefore we start your order {order_ref}, we have stitched a sample (swatch) of your {logo} embroidery ({placement}) so you can check it matches what you expect. A photo of it is below.\n\nPlease look closely at the colours, size and detail, because a stitched logo can come out a little different from the on-screen visual. Then reply to this email to either:\n\n- approve it, and we will go ahead with your order, or\n- tell us what you would like changed, and we will make a new sample.\n\nWe will not start production until we have your approval.\n\nKind regards\nATAM Workwear', true, 'seed');

create table flow.emb_swatches (
  id           uuid primary key default gen_random_uuid(),
  design_id    uuid not null references flow.emb_designs(id),
  round        int not null,
  order_id     uuid references flow.orders(id),
  order_ref    text,
  deco_line_id text,
  area         text,
  to_addresses text[] not null,
  subject      text not null,
  template_code text,
  photo_path   text not null,
  comm_id      uuid references flow.communications(id),
  status       text not null default 'queued' check (status in ('queued', 'sent', 'cancelled')),
  created_by   text,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz
);
create index emb_swatches_design on flow.emb_swatches (design_id, created_at);
create unique index emb_swatches_one_waiting on flow.emb_swatches (design_id, round) where status = 'queued';
alter table flow.email_templates enable row level security;
alter table flow.emb_swatches enable row level security;
create policy email_templates_read on flow.email_templates for select to authenticated using (flow.is_member());
create policy emb_swatches_read on flow.emb_swatches for select to authenticated using (flow.is_member());

-- 1. Templates: add to them, edit them, choose the default --------------------------------------------------------------------------------------
create or replace function flow.email_template_save(p_code text, p_name text, p_subject text, p_body text, p_is_default boolean, p_is_active boolean, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare v_actor text := flow.emb_actor(p_actor); v_code text := nullif(btrim(coalesce(p_code, '')), ''); t flow.email_templates; v_name text := btrim(coalesce(p_name, '')); v_subj text := btrim(coalesce(p_subject, '')); v_body text := btrim(coalesce(p_body, ''));
        v_def boolean := coalesce(p_is_default, false); v_act boolean := coalesce(p_is_active, true);
begin
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'Give the template a name.'); end if;
  if v_subj = '' then return jsonb_build_object('ok', false, 'error', 'Give the template a subject line.'); end if;
  if v_body = '' then return jsonb_build_object('ok', false, 'error', 'Write the message.'); end if;
  if length(v_name) > 120 or length(v_subj) > 200 or length(v_body) > 8000 then return jsonb_build_object('ok', false, 'error', 'That is too long: keep the name under 120, the subject under 200 and the message under 8,000 characters.'); end if;
  if v_def and not v_act then return jsonb_build_object('ok', false, 'error', 'The default template has to be switched on.'); end if;
  if v_code is not null then
    select * into t from flow.email_templates where code = v_code for update;
    if not found then return jsonb_build_object('ok', false, 'error', 'That template does not exist.'); end if;
    if t.is_default and not v_def then return jsonb_build_object('ok', false, 'error', 'This is the default template. Make another one the default first.'); end if;
    if v_def then update flow.email_templates set is_default = false where kind = t.kind and is_default and code <> v_code; end if;
    update flow.email_templates set name = v_name, subject = v_subj, body = v_body, is_default = v_def, is_active = v_act, updated_by = v_actor, updated_at = now() where code = v_code;
  else
    v_code := 'emb_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
    if v_def then update flow.email_templates set is_default = false where kind = 'embroidery_swatch' and is_default; end if;
    insert into flow.email_templates (code, kind, name, subject, body, is_default, is_active, created_by, updated_by) values (v_code, 'embroidery_swatch', v_name, v_subj, v_body, v_def, v_act, v_actor, v_actor);
  end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'email_template_saved', 'email_templates', v_code, jsonb_build_object('name', v_name, 'default', v_def, 'active', v_act));
  return jsonb_build_object('ok', true, 'code', v_code);
end $$;

-- 2. Queue the swatch email ---------------------------------------------------------------------------------------------------------------------
create or replace function flow.emb_html_esc(p text) returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;') $$;

create or replace function flow.emb_swatch_send(p_design uuid, p_order uuid, p_deco_line text, p_area text, p_template text, p_to text[], p_subject text, p_body text, p_photo_path text, p_photo_url text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d flow.emb_designs; o flow.orders; a flow.artwork_files; v_actor text := flow.emb_actor(p_actor); v_subj text := btrim(coalesce(p_subject, '')); v_body text := btrim(coalesce(p_body, '')); v_to text[] := '{}'::text[]; x text;
        v_id uuid := gen_random_uuid(); v_html text := ''; v_text text; v_comm uuid; para text; v_visual text;
begin
  select * into d from flow.emb_designs where id = p_design for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'That design does not exist.'); end if;
  if d.status <> 'swatch_in_progress' then return jsonb_build_object('ok', false, 'error', 'The swatch email can be sent while the swatch is "in progress". This design is "' || replace(d.status, '_', ' ') || '".'); end if;
  select * into o from flow.orders where id = p_order;
  if not found or not o.is_active then return jsonb_build_object('ok', false, 'error', 'That order is not active.'); end if;
  if o.customer_id is distinct from d.customer_id then return jsonb_build_object('ok', false, 'error', 'That order belongs to a different customer.'); end if;
  select * into a from flow.artwork_files where order_id = p_order and coalesce(deco_line_id, '') = coalesce(p_deco_line, '') and area = p_area and is_current and lower(coalesce(process, '')) = 'embroidery';
  if not found then return jsonb_build_object('ok', false, 'error', 'That embroidery area is not on this order.'); end if;
  if not exists (select 1 from flow.emb_links l where l.design_id = p_design and l.order_id = p_order and l.deco_line_id = coalesce(p_deco_line, '') and l.area = p_area and l.is_active) then return jsonb_build_object('ok', false, 'error', 'This area is not linked to that design.'); end if;
  if v_subj = '' or v_body = '' then return jsonb_build_object('ok', false, 'error', 'The email needs a subject and a message.'); end if;
  if length(v_subj) > 200 or length(v_body) > 8000 then return jsonb_build_object('ok', false, 'error', 'The email is too long.'); end if;
  foreach x in array coalesce(p_to, '{}'::text[]) loop
    x := lower(btrim(x));
    if x !~ '^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$' then return jsonb_build_object('ok', false, 'error', '"' || x || '" is not an email address.'); end if;
    if not (x = any (v_to)) then v_to := v_to || x; end if;
  end loop;
  if cardinality(v_to) = 0 then return jsonb_build_object('ok', false, 'error', 'Add the customer''s email address.'); end if;
  if cardinality(v_to) > 5 then return jsonb_build_object('ok', false, 'error', 'Five addresses at most.'); end if;
  if coalesce(p_photo_path, '') !~ ('^swatches/' || p_design::text || '/') or p_photo_path ~ '\.\.' then return jsonb_build_object('ok', false, 'error', 'Add a photo of the swatch.'); end if;
  if coalesce(p_photo_url, '') !~ '^https://[^\s"<>]+/storage/v1/object/sign/artwork/swatches/' then return jsonb_build_object('ok', false, 'error', 'The swatch photo link is not valid. Add the photo again.'); end if;
  if exists (select 1 from flow.emb_swatches s where s.design_id = p_design and s.round = d.round and s.status = 'queued') then return jsonb_build_object('ok', false, 'error', 'A swatch email for this round is already waiting for approval. Cancel it first if you want to send a different one.'); end if;
  -- the plain text, then the same words as safe HTML with the pictures
  v_text := v_body || E'\n\nPhoto of the swatch: ' || p_photo_url;
  for para in select btrim(x2) from unnest(regexp_split_to_array(replace(v_body, E'\r', ''), E'\n\n+')) x2 where btrim(x2) <> '' loop
    v_html := v_html || '<p style="font-family:Arial,sans-serif;font-size:14px;line-height:1.5">' || replace(flow.emb_html_esc(para), E'\n', '<br>') || '</p>';
  end loop;
  v_visual := case when coalesce(a.thumbnail_url, '') ~ '^https?://[^\s"<>]+$' then a.thumbnail_url end;
  v_html := v_html || '<p style="font-family:Arial,sans-serif;font-size:14px"><b>Your swatch</b><br><a href="' || flow.emb_html_esc(p_photo_url) || '"><img src="' || flow.emb_html_esc(p_photo_url) || '" alt="Photo of the embroidery swatch" style="max-width:480px;width:100%;border:1px solid #ccc"></a></p>'
    || case when v_visual is not null then '<p style="font-family:Arial,sans-serif;font-size:14px"><b>The visual we showed you</b><br><img src="' || flow.emb_html_esc(v_visual) || '" alt="The logo visual" style="max-width:240px;border:1px solid #ccc"></p>' else '' end;
  v_comm := flow.queue_comm('other', v_to, v_subj, v_text, v_html, 'emb_swatch', v_id, null, null, v_actor);
  insert into flow.emb_swatches (id, design_id, round, order_id, order_ref, deco_line_id, area, to_addresses, subject, template_code, photo_path, comm_id, created_by)
    values (v_id, p_design, d.round, p_order, o.order_ref, coalesce(p_deco_line, ''), p_area, v_to, v_subj, nullif(btrim(coalesce(p_template, '')), ''), p_photo_path, v_comm, v_actor);
  insert into flow.emb_events (design_id, event, round, actor, order_ref, note) values (p_design, 'swatch_email_queued', d.round, v_actor, o.order_ref, array_to_string(v_to, ', '));
  insert into flow.audit_log (actor, action, entity, entity_id, after) values (v_actor, 'emb_swatch_email_queued', 'emb_designs', p_design::text, jsonb_build_object('order', o.order_ref, 'round', d.round, 'to', v_to, 'comm_id', v_comm));
  return jsonb_build_object('ok', true, 'swatch_id', v_id, 'comm_id', v_comm, 'comm_ref', (select comm_ref from flow.communications where id = v_comm), 'comm_status', (select status from flow.communications where id = v_comm));
end $$;

create or replace function public.flow_email_template_save(p_code text, p_name text, p_subject text, p_body text, p_is_default boolean, p_is_active boolean, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.email_template_save(p_code, p_name, p_subject, p_body, p_is_default, p_is_active, p_actor) $$;
create or replace function public.flow_emb_swatch_send(p_design uuid, p_order uuid, p_deco_line text, p_area text, p_template text, p_to text[], p_subject text, p_body text, p_photo_path text, p_photo_url text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.emb_swatch_send(p_design, p_order, p_deco_line, p_area, p_template, p_to, p_subject, p_body, p_photo_path, p_photo_url, p_actor) $$;

-- 3. Sending the email moves the design on; cancelling it keeps the design where it was (patched in place) -----------------------------------------
do $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('flow.comm_mark_sent(uuid,text)'::regprocedure);
  v_new := replace(v_def, $a$  if c.entity_type = 'dtf_batch' and c.entity_id is not null then$a$, $b$  if c.entity_type = 'emb_swatch' and c.entity_id is not null then
    update flow.emb_swatches set status = 'sent', sent_at = now() where id = c.entity_id and status = 'queued';
    insert into flow.emb_events (design_id, event, from_status, to_status, round, actor, note, order_ref)
      select s.design_id, 'status', 'swatch_in_progress', 'swatch_sent', d.round, 'system', 'Swatch email sent', s.order_ref from flow.emb_swatches s join flow.emb_designs d on d.id = s.design_id
       where s.id = c.entity_id and d.status = 'swatch_in_progress';
    update flow.emb_designs set status = 'swatch_sent', status_by = 'system', status_at = now() where status = 'swatch_in_progress' and id = (select design_id from flow.emb_swatches where id = c.entity_id);
  end if;
  if c.entity_type = 'dtf_batch' and c.entity_id is not null then$b$);
  if v_new = v_def then raise exception 'comm_mark_sent: the line to patch was not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('flow.comm_cancel(uuid,text)'::regprocedure);
  v_new := replace(v_def, $a$  update flow.dtf_batches set status = 'cancelled' where comm_id = p_id and status = 'draft';$a$, $b$  insert into flow.emb_events (design_id, event, round, actor, order_ref, note) select s.design_id, 'swatch_email_cancelled', s.round, p_actor, s.order_ref, s.subject from flow.emb_swatches s where s.comm_id = p_id and s.status = 'queued';
  update flow.emb_swatches set status = 'cancelled' where comm_id = p_id and status = 'queued';
  update flow.dtf_batches set status = 'cancelled' where comm_id = p_id and status = 'draft';$b$);
  if v_new = v_def then raise exception 'comm_cancel: the line to patch was not found'; end if;
  execute v_new;
end $$;

-- 4. What staff see -----------------------------------------------------------------------------------------------------------------------------
create or replace view public.ui_email_templates with (security_invoker = true) as
  select t.code, t.kind, t.name, t.subject, t.body, t.is_default, t.is_active, t.updated_by, t.updated_at from flow.email_templates t;
create or replace view public.ui_emb_swatches with (security_invoker = true) as
  select s.id, s.design_id, s.round, s.order_ref, s.area, s.to_addresses, s.subject, s.template_code, s.photo_path, s.status, s.created_by, s.created_at, s.sent_at,
         c.comm_ref, c.status as comm_status
  from flow.emb_swatches s left join flow.communications c on c.id = s.comm_id;

do $$
declare f text;
begin
  revoke all on flow.email_templates, flow.emb_swatches from public, anon, authenticated;
  grant select on flow.email_templates, flow.emb_swatches to authenticated;
  revoke all on public.ui_email_templates, public.ui_emb_swatches from public, anon;
  grant select on public.ui_email_templates, public.ui_emb_swatches to authenticated;
  foreach f in array array['flow.email_template_save(text,text,text,text,boolean,boolean,text)', 'flow.emb_html_esc(text)', 'flow.emb_swatch_send(uuid,uuid,text,text,text,text[],text,text,text,text,text)',
                           'public.flow_email_template_save(text,text,text,text,boolean,boolean,text)', 'public.flow_emb_swatch_send(uuid,uuid,text,text,text,text[],text,text,text,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_email_template_save(text, text, text, text, boolean, boolean, text), public.flow_emb_swatch_send(uuid, uuid, text, text, text, text[], text, text, text, text, text) to service_role;
end $$;
