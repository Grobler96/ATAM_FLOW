-- Artwork storage on screen and customer proofs.
-- A proof is a picture or PDF shown to the customer for approval (made outside DecoNetwork, for example emailed). It is tied to the exact artwork versions it shows.
-- Lifecycle: draft -> sent (who it went to, how) -> the customer's answer (approved / changes requested / rejected, who said so, with the evidence). An approval is only accepted
-- while the artwork it shows is still the current version, and then marks those areas approved. Nothing is sent from here: sending is recorded by a person.
-- Two things raise an exception so a proof cannot be forgotten: sent and not answered after a few days, and an approved proof whose artwork has since changed.

create sequence if not exists flow.proof_seq;

create table flow.artwork_proofs (
  id            uuid primary key default gen_random_uuid(),
  proof_ref     text not null unique,
  order_id      uuid not null references flow.orders(id),
  artwork_ids   uuid[] not null check (cardinality(artwork_ids) > 0),   -- the exact artwork versions this proof shows
  areas         text[] not null,                                         -- their area names, for display
  storage_path  text not null,                                           -- the proof file in the private artwork bucket
  file_name     text not null,
  status        text not null default 'draft' check (status in ('draft', 'sent', 'approved', 'changes_requested', 'rejected', 'superseded', 'withdrawn')),
  note          text,
  created_by    text not null,
  created_at    timestamptz not null default now(),
  sent_to       text,
  sent_via      text check (sent_via is null or sent_via in ('email', 'phone', 'in_person', 'portal', 'other')),
  sent_by       text,
  sent_at       timestamptz,
  answered_by   text,                                                    -- the person at the customer who answered
  answer_note   text,
  answer_evidence_path text,                                             -- for example a screenshot of the customer's email
  recorded_by   text,                                                    -- who in ATAM recorded the answer
  answered_at   timestamptz,
  closed_reason text,
  closed_by     text,
  closed_at     timestamptz
);
create index artwork_proofs_order on flow.artwork_proofs (order_id, created_at desc);
create index artwork_proofs_sent on flow.artwork_proofs (sent_at) where status = 'sent';
alter table flow.artwork_proofs enable row level security;
create policy artwork_proofs_read on flow.artwork_proofs for select to authenticated using (flow.is_member());

insert into flow.flow_settings (key, value, description) values ('artwork.proofs', '{"reminder_days": 3}'::jsonb, 'Proofs: days after a proof is sent before an unanswered proof is raised as an exception')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Actions (service role, called by the Operations actions workflow)
-- ---------------------------------------------------------------------------
create or replace function flow.proof_create(p_order uuid, p_artwork_ids uuid[], p_storage_path text, p_file_name text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare o flow.orders; v_n int; v_ref text; v_id uuid; v_areas text[]; v_old text;
begin
  select * into o from flow.orders where id = p_order;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'Order not found.'); end if;
  if p_artwork_ids is null or cardinality(p_artwork_ids) = 0 then return jsonb_build_object('ok', false, 'error', 'Choose which artwork areas the proof shows.'); end if;
  select count(*), array_agg(a.area order by a.area) into v_n, v_areas from flow.artwork_files a where a.id = any (p_artwork_ids) and a.order_id = p_order and a.is_current;
  if v_n <> cardinality(p_artwork_ids) then return jsonb_build_object('ok', false, 'error', 'Those areas are not all current artwork on this order. Refresh and choose again.'); end if;
  if coalesce(p_storage_path, '') not like 'proofs/' || replace(o.order_ref, '#', '') || '/%' then return jsonb_build_object('ok', false, 'error', 'The proof file is not stored in this order''s proofs folder.'); end if;
  if length(btrim(coalesce(p_file_name, ''))) = 0 or length(p_file_name) > 200 then return jsonb_build_object('ok', false, 'error', 'The proof needs a file name.'); end if;
  v_ref := 'PRF-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('flow.proof_seq')::text, 5, '0');
  -- a new proof for the same areas replaces any earlier one that has not been answered
  select string_agg(proof_ref, ', ') into v_old from flow.artwork_proofs where order_id = p_order and status in ('draft', 'sent') and artwork_ids && p_artwork_ids;
  update flow.artwork_proofs set status = 'superseded', closed_reason = 'Replaced by ' || v_ref, closed_by = p_actor, closed_at = now()
    where order_id = p_order and status in ('draft', 'sent') and artwork_ids && p_artwork_ids;
  insert into flow.artwork_proofs (proof_ref, order_id, artwork_ids, areas, storage_path, file_name, note, created_by)
  values (v_ref, p_order, p_artwork_ids, v_areas, p_storage_path, btrim(p_file_name), nullif(btrim(coalesce(p_note, '')), ''), p_actor) returning id into v_id;
  perform flow.wh_audit(p_actor, 'proof_create', 'order', o.order_ref, null, jsonb_build_object('proof', v_ref, 'areas', v_areas, 'replaced', v_old), p_note);
  return jsonb_build_object('ok', true, 'proof_id', v_id, 'proof_ref', v_ref, 'order_ref', o.order_ref, 'replaced', v_old);
end $$;

create or replace function flow.proof_send(p_proof uuid, p_to text, p_via text, p_note text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.artwork_proofs; o flow.orders;
begin
  select * into p from flow.artwork_proofs where id = p_proof; if p.id is null then return jsonb_build_object('ok', false, 'error', 'Proof not found.'); end if;
  select * into o from flow.orders where id = p.order_id;
  if p.status <> 'draft' then return jsonb_build_object('ok', false, 'error', 'Only a draft proof can be marked as sent (this one is ' || replace(p.status, '_', ' ') || ').'); end if;
  if length(btrim(coalesce(p_to, ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Who was it sent to? Enter a name or email address.'); end if;
  if coalesce(p_via, '') not in ('email', 'phone', 'in_person', 'portal', 'other') then return jsonb_build_object('ok', false, 'error', 'Say how it was sent.'); end if;
  if exists (select 1 from flow.artwork_files a where a.id = any (p.artwork_ids) and not a.is_current) then
    return jsonb_build_object('ok', false, 'error', 'The artwork has changed since this proof was made. Make a new proof first.');
  end if;
  update flow.artwork_proofs set status = 'sent', sent_to = btrim(p_to), sent_via = p_via, sent_by = p_actor, sent_at = now(), note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note) where id = p.id;
  perform flow.wh_audit(p_actor, 'proof_send', 'order', o.order_ref, null, jsonb_build_object('proof', p.proof_ref, 'to', btrim(p_to), 'via', p_via), p_note);
  return jsonb_build_object('ok', true, 'proof_ref', p.proof_ref, 'order_ref', o.order_ref);
end $$;

-- The customer's answer. An approval marks the areas it shows as approved, but only while they are still the current versions.
create or replace function flow.proof_respond(p_proof uuid, p_outcome text, p_by text, p_note text, p_evidence text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.artwork_proofs; o flow.orders; v_status text; v_art text; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into p from flow.artwork_proofs where id = p_proof; if p.id is null then return jsonb_build_object('ok', false, 'error', 'Proof not found.'); end if;
  select * into o from flow.orders where id = p.order_id;
  if p.status <> 'sent' then return jsonb_build_object('ok', false, 'error', 'Only a proof that has been sent can be answered (this one is ' || replace(p.status, '_', ' ') || ').'); end if;
  if coalesce(p_outcome, '') not in ('approved', 'changes_requested', 'rejected') then return jsonb_build_object('ok', false, 'error', 'Choose approved, changes requested or rejected.'); end if;
  if length(btrim(coalesce(p_by, ''))) < 2 then return jsonb_build_object('ok', false, 'error', 'Who at the customer gave this answer?'); end if;
  if p_outcome <> 'approved' and (v_note is null or length(v_note) < 5) then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Write down what the customer said (at least a few words).'); end if;
  if p_evidence is not null and p_evidence not like 'proofs/' || replace(o.order_ref, '#', '') || '/%' then return jsonb_build_object('ok', false, 'error', 'The evidence file is not stored in this order''s proofs folder.'); end if;
  if p_outcome = 'approved' and exists (select 1 from flow.artwork_files a where a.id = any (p.artwork_ids) and not a.is_current) then
    return jsonb_build_object('ok', false, 'error', 'The artwork changed after this proof was made, so this approval cannot cover the new version. Make a new proof and send it.');
  end if;
  v_status := p_outcome;
  v_art := case p_outcome when 'approved' then 'approved' when 'rejected' then 'rejected' else 'pending' end;
  update flow.artwork_proofs set status = v_status, answered_by = btrim(p_by), answer_note = v_note, answer_evidence_path = p_evidence, recorded_by = p_actor, answered_at = now() where id = p.id;
  update flow.artwork_files set approval_status = v_art,
         note = concat_ws(E'\n', note, p_actor || ': approval set to ' || v_art || ' by proof ' || p.proof_ref || ' (' || btrim(p_by) || ')' || coalesce(' - ' || v_note, ''))
   where id = any (p.artwork_ids) and is_current;
  perform flow.wh_audit(p_actor, 'proof_answer', 'order', o.order_ref, null, jsonb_build_object('proof', p.proof_ref, 'outcome', p_outcome, 'by', btrim(p_by), 'areas', p.areas), v_note);
  return jsonb_build_object('ok', true, 'proof_ref', p.proof_ref, 'order_ref', o.order_ref, 'status', v_status, 'artwork_approval', v_art, 'areas', to_jsonb(p.areas));
end $$;

create or replace function flow.proof_withdraw(p_proof uuid, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare p flow.artwork_proofs; o flow.orders; v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into p from flow.artwork_proofs where id = p_proof; if p.id is null then return jsonb_build_object('ok', false, 'error', 'Proof not found.'); end if;
  select * into o from flow.orders where id = p.order_id;
  if p.status not in ('draft', 'sent') then return jsonb_build_object('ok', false, 'error', 'Only a draft or sent proof can be withdrawn (this one is ' || replace(p.status, '_', ' ') || ').'); end if;
  if length(v_reason) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why the proof is being withdrawn (at least a few words).'); end if;
  update flow.artwork_proofs set status = 'withdrawn', closed_reason = v_reason, closed_by = p_actor, closed_at = now() where id = p.id;
  perform flow.wh_audit(p_actor, 'proof_withdraw', 'order', o.order_ref, null, jsonb_build_object('proof', p.proof_ref), v_reason);
  return jsonb_build_object('ok', true, 'proof_ref', p.proof_ref, 'order_ref', o.order_ref);
end $$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------
-- Every artwork version with its stored file, for the Artwork screen (preview, download, history). Source and production links from DecoNetwork are not included.
create or replace view public.ui_artwork_files with (security_invoker = true) as
select a.id, a.order_id, o.order_ref, o.customer_name, o.due_date, a.deco_line_id, a.area, a.process, a.version, a.is_current, a.source, a.approval_status, a.storage_status, a.storage_path,
       a.file_format, a.stitch_count, a.width_mm, a.height_mm, a.placement, a.readable, (a.proof_url is not null) as has_deconetwork_proof, a.proof_url, a.note, a.created_by, a.created_at, a.stored_at
from flow.artwork_files a join flow.orders o on o.id = a.order_id;

create or replace view public.ui_artwork_proofs with (security_invoker = true) as
select p.id, p.proof_ref, p.order_id, o.order_ref, o.customer_name, o.due_date, p.artwork_ids, p.areas, p.storage_path, p.file_name, p.status, p.note, p.created_by, p.created_at,
       p.sent_to, p.sent_via, p.sent_by, p.sent_at, p.answered_by, p.answer_note, p.answer_evidence_path, p.recorded_by, p.answered_at, p.closed_reason, p.closed_by, p.closed_at,
       exists (select 1 from flow.artwork_files a where a.id = any (p.artwork_ids) and not a.is_current) as is_out_of_date,
       case when p.status = 'sent' then floor(extract(epoch from (now() - p.sent_at)) / 86400)::int end as days_waiting
from flow.artwork_proofs p join flow.orders o on o.id = p.order_id;

-- ---------------------------------------------------------------------------
-- Exceptions: a proof that is waiting too long, and an approval that no longer covers the artwork
-- ---------------------------------------------------------------------------
insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('proof_unanswered', 'Proof not answered', 'artwork', 'medium', '{}', 'production', 'Chase the customer for an answer on the proof, then record it on the Artwork screen.'),
 ('proof_out_of_date', 'Approved proof no longer matches the artwork', 'artwork', 'high', '{}', 'production', 'The artwork was replaced after the customer approved a proof. Make a new proof, send it and get it approved before producing.')
on conflict (code) do nothing;

create or replace function flow.exc_detect_proofs() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('type', 'proof_unanswered', 'key', 'proof_wait:' || p.id,
      'description', format('Proof %s for %s (%s) was sent to %s %s day(s) ago and has not been answered', p.proof_ref, o.order_ref, array_to_string(p.areas, ', '), p.sent_to, floor(extract(epoch from (now() - p.sent_at)) / 86400)::int),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)),
      'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'customer', 'detected_by', 'automation', 'source_type', 'proof', 'source_id', p.id::text)) as x
    from flow.artwork_proofs p join flow.orders o on o.id = p.order_id
    where p.status = 'sent' and o.is_active and o.shipped_at is null and o.order_status <> 'dispatched'
      and p.sent_at < now() - make_interval(days => coalesce((flow.setting('artwork.proofs')->>'reminder_days')::int, 3))
    union all
    select jsonb_build_object('type', 'proof_out_of_date', 'key', 'proof_old:' || p.id,
      'description', format('The customer approved proof %s for %s, but the artwork (%s) has been replaced since, so the new version has not been approved by the customer', p.proof_ref, o.order_ref, array_to_string(p.areas, ', ')),
      'links', jsonb_build_array(jsonb_build_object('type', 'order', 'id', o.id)),
      'opts', jsonb_build_object('severity', 'high', 'root_cause', 'artwork', 'detected_by', 'automation', 'source_type', 'proof', 'source_id', p.id::text))
    from flow.artwork_proofs p join flow.orders o on o.id = p.order_id
    where p.status = 'approved' and o.is_active and o.shipped_at is null and o.order_status <> 'dispatched'
      and exists (select 1 from flow.artwork_files a where a.id = any (p.artwork_ids) and not a.is_current)
      and not exists (select 1 from flow.artwork_proofs q where q.order_id = p.order_id and q.status = 'approved' and q.created_at > p.created_at and q.artwork_ids && p.artwork_ids
                        and not exists (select 1 from flow.artwork_files b where b.id = any (q.artwork_ids) and not b.is_current))
  ) q
$$;

-- Add the proofs detector to the run list without rewriting the rest of the function.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.exceptions_detect_all()'::regprocedure) into v_def;
  if v_def not like '%''proofs''%' then
    v_def := replace(v_def, '''portal''] loop', '''portal'',''proofs''] loop');
    if v_def not like '%''proofs''%' then raise exception 'detector list anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- Wrappers for n8n (service role only) and grants
create or replace function public.flow_proof_create(p_order uuid, p_artwork_ids uuid[], p_storage_path text, p_file_name text, p_note text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.proof_create(p_order, p_artwork_ids, p_storage_path, p_file_name, p_note, p_actor) $$;
create or replace function public.flow_proof_send(p_proof uuid, p_to text, p_via text, p_note text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.proof_send(p_proof, p_to, p_via, p_note, p_actor) $$;
create or replace function public.flow_proof_respond(p_proof uuid, p_outcome text, p_by text, p_note text, p_evidence text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.proof_respond(p_proof, p_outcome, p_by, p_note, p_evidence, p_actor) $$;
create or replace function public.flow_proof_withdraw(p_proof uuid, p_reason text, p_actor text) returns jsonb
language sql security definer set search_path = flow, public as $$ select flow.proof_withdraw(p_proof, p_reason, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['flow.proof_create(uuid,uuid[],text,text,text,text)', 'flow.proof_send(uuid,text,text,text,text)', 'flow.proof_respond(uuid,text,text,text,text,text)', 'flow.proof_withdraw(uuid,text,text)', 'flow.exc_detect_proofs()',
      'public.flow_proof_create(uuid,uuid[],text,text,text,text)', 'public.flow_proof_send(uuid,text,text,text,text)', 'public.flow_proof_respond(uuid,text,text,text,text,text)', 'public.flow_proof_withdraw(uuid,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  foreach f in array array['public.flow_proof_create(uuid,uuid[],text,text,text,text)', 'public.flow_proof_send(uuid,text,text,text,text)', 'public.flow_proof_respond(uuid,text,text,text,text,text)', 'public.flow_proof_withdraw(uuid,text,text)']
  loop execute format('grant execute on function %s to service_role', f); end loop;
  revoke all on flow.artwork_proofs from public, anon;
  grant select on flow.artwork_proofs to authenticated;
  revoke all on public.ui_artwork_files, public.ui_artwork_proofs from public, anon;
  grant select on public.ui_artwork_files, public.ui_artwork_proofs to authenticated;
end $$;
