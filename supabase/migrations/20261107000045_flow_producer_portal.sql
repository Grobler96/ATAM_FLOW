-- Third-party decorator portal (database side).
-- A decorator signs in with its own secure login (email link), sees only the consignments sent to it, accepts or declines a job, checks the goods in
-- (count and condition, with photos), updates the process stage, ships back with courier and tracking, and messages us.
-- Security model: portal users are NOT in flow.user_roles, so every internal view and function stays closed to them. They can run only the
-- public.portal_* functions below, each of which resolves "who am I" from the login and then touches only that decorator's own consignments.
-- Custody note: checking in still moves the full sent quantity to "at producer" (the system of record); a count or condition problem raises an
-- exception for us to reconcile, it does not change the stock ledger by itself.

create table flow.producer_users (
  id          uuid primary key default gen_random_uuid(),
  producer_id uuid not null references flow.producers(id),
  email       text not null,
  name        text,
  user_id     uuid unique,
  is_active   boolean not null default true,
  invited_by  text,
  invited_at  timestamptz not null default now(),
  last_seen_at timestamptz
);
create unique index producer_users_email on flow.producer_users (lower(email));
alter table flow.producer_users enable row level security;
create policy producer_users_read on flow.producer_users for select to authenticated using (flow.is_member());

alter table flow.tp_movements
  add column if not exists portal_accepted_at timestamptz, add column if not exists portal_accepted_by text,
  add column if not exists portal_declined_at timestamptz, add column if not exists portal_declined_reason text;

create table flow.tp_receipts (
  id           uuid primary key default gen_random_uuid(),
  movement_id  uuid not null references flow.tp_movements(id),
  item_id      uuid not null references flow.tp_movement_items(id),
  qty_sent     int not null,
  qty_counted  int not null check (qty_counted >= 0),
  qty_damaged  int not null default 0 check (qty_damaged >= 0),
  issue        text check (issue in ('short', 'over', 'damaged', 'wrong_item', 'wrong_size', 'other')),
  note         text,
  received_by  text,
  received_at  timestamptz not null default now(),
  resolved_at  timestamptz, resolved_by text, resolution_note text,
  unique (item_id)
);
create table flow.tp_messages (
  id          uuid primary key default gen_random_uuid(),
  movement_id uuid not null references flow.tp_movements(id),
  side        text not null check (side in ('producer', 'atam')),
  author      text,
  body        text not null check (length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index tp_messages_mv on flow.tp_messages (movement_id, created_at);
create table flow.tp_evidence (
  id           uuid primary key default gen_random_uuid(),
  movement_id  uuid not null references flow.tp_movements(id),
  item_id      uuid references flow.tp_movement_items(id),
  storage_path text not null,
  kind         text not null default 'issue' check (kind in ('issue', 'goods_in', 'finished', 'dispatch', 'other')),
  caption      text,
  uploaded_by  text,
  created_at   timestamptz not null default now()
);
alter table flow.tp_receipts enable row level security;
alter table flow.tp_messages enable row level security;
alter table flow.tp_evidence enable row level security;
create policy tp_receipts_read on flow.tp_receipts for select to authenticated using (flow.is_member());
create policy tp_messages_read on flow.tp_messages for select to authenticated using (flow.is_member());
create policy tp_evidence_read on flow.tp_evidence for select to authenticated using (flow.is_member());

insert into flow.exception_types (code, label, category, default_severity, blocks, owner_role, recommended_action) values
 ('producer_receipt_issue', 'Decorator reported a problem with the goods received', 'producer', 'high', '{}', 'manager', 'Read the count and photos, decide whether to resend, replace or accept, and tell the decorator. Mark the issue resolved with a note.'),
 ('producer_declined', 'Decorator declined a job', 'producer', 'critical', '{}', 'manager', 'Find out why and either change the job or move it to another decorator.'),
 ('producer_delay', 'Decorator reported a delay', 'producer', 'high', '{}', 'manager', 'Check the new date against the customer promise and tell the customer if needed.'),
 ('producer_partial_ship', 'Decorator sent back fewer units than expected', 'producer', 'high', '{}', 'manager', 'Find out where the rest are and when they will follow.'),
 ('producer_query', 'Decorator message waiting for a reply', 'producer', 'medium', '{}', 'manager', 'Reply to the decorator on the consignment.')
on conflict (code) do nothing;

-- who is this login?  Claims the invitation on first use (matched on the verified email), and refuses anyone else.
create or replace function flow.portal_ctx() returns flow.producer_users
language plpgsql security definer set search_path = flow, public as $$
declare u uuid := auth.uid(); v_email text; v_conf timestamptz; pu flow.producer_users;
begin
  if u is null then raise exception 'Please sign in.'; end if;
  select * into pu from flow.producer_users where user_id = u and is_active;
  if pu.id is null then
    select email, email_confirmed_at into v_email, v_conf from auth.users where id = u;
    if v_conf is not null and v_email is not null then
      update flow.producer_users set user_id = u where lower(email) = lower(v_email) and is_active and user_id is null returning * into pu;
    end if;
  end if;
  if pu.id is null then raise exception 'This login does not have access to the decorator portal. Ask ATAM for an invitation.'; end if;
  if not exists (select 1 from flow.producers where id = pu.producer_id and is_active) then raise exception 'This decorator account is switched off.'; end if;
  update flow.producer_users set last_seen_at = now() where id = pu.id;
  return pu;
end $$;

create or replace function public.portal_my_producer() returns uuid language sql stable security definer set search_path = flow, public as $$
  select producer_id from flow.producer_users where user_id = auth.uid() and is_active $$;

create or replace function flow.portal_state(m flow.tp_movements) returns text language sql stable set search_path = flow, public as $$
  select case
    when m.portal_declined_at is not null then 'declined'
    when m.status = 'dispatched' and m.portal_accepted_at is null then 'to_accept'
    when m.status = 'dispatched' then 'accepted'
    when m.status = 'received_by_producer' then 'checked_in'
    when m.status = 'in_production' then 'in_production'
    when m.status = 'production_complete' then 'ready_to_ship'
    when m.status in ('in_transit_back', 'partially_returned') then 'sent_back'
    when m.status in ('returned', 'checked', 'closed') then 'done'
    else m.status::text end $$;

create or replace function flow.portal_own(p_code text, p_pid uuid) returns flow.tp_movements language plpgsql stable security definer set search_path = flow, public as $$
declare m flow.tp_movements;
begin
  m := flow.tp_find(p_code);
  if m.id is null or m.producer_id <> p_pid or m.status in ('draft', 'picked', 'packed', 'cancelled') then raise exception 'That job was not found.'; end if;
  return m;
end $$;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
create or replace function public.portal_whoami() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; pr flow.producers;
begin
  pu := flow.portal_ctx();
  select * into pr from flow.producers where id = pu.producer_id;
  return jsonb_build_object('ok', true, 'producer', pr.name, 'producer_id', pr.id, 'user', coalesce(pu.name, pu.email), 'instructions', pr.special_instructions);
end $$;

create or replace function public.portal_jobs() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users;
begin
  pu := flow.portal_ctx();
  return coalesce((select jsonb_agg(j order by j->>'sort') from (
    select jsonb_build_object('code', m.movement_code, 'state', flow.portal_state(m), 'status', m.status, 'dispatch_date', m.dispatch_date, 'expected_return_date', m.expected_return_date,
      'direct_to_customer', m.movement_type = 'direct_dispatch_to_customer',
      'units', (select coalesce(sum(i.qty_sent), 0) from flow.tp_movement_items i where i.movement_id = m.id),
      'orders', (select jsonb_agg(distinct jsonb_build_object('order_ref', o.order_ref, 'customer', o.customer_name)) from flow.tp_movement_items i join flow.orders o on o.id = i.order_id where i.movement_id = m.id),
      'unread', (select count(*) from flow.tp_messages g where g.movement_id = m.id and g.side = 'atam' and g.created_at > coalesce(pu.last_seen_at, 'epoch')),
      'sort', case when flow.portal_state(m) in ('to_accept', 'accepted') then '1' when flow.portal_state(m) in ('checked_in', 'in_production', 'ready_to_ship') then '2' when flow.portal_state(m) = 'sent_back' then '3' else '9' end || coalesce(m.expected_return_date::text, '9999')) as j
    from flow.tp_movements m
    where m.producer_id = pu.producer_id and m.status not in ('draft', 'picked', 'packed', 'cancelled')
      and (m.status not in ('returned', 'checked', 'closed') or m.updated_at > now() - interval '30 days')) x), '[]'::jsonb);
end $$;

create or replace function public.portal_job(p_code text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements; pr flow.producers;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id);
  select * into pr from flow.producers where id = m.producer_id;
  return jsonb_build_object('ok', true, 'code', m.movement_code, 'state', flow.portal_state(m), 'status', m.status,
    'direct_to_customer', m.movement_type = 'direct_dispatch_to_customer', 'dispatch_date', m.dispatch_date, 'expected_return_date', m.expected_return_date,
    'carrier_in', m.carrier, 'tracking_in', m.tracking_ref, 'return_tracking', m.return_tracking_ref, 'customer_tracking', m.customer_tracking_ref,
    'accepted_at', m.portal_accepted_at, 'declined_reason', m.portal_declined_reason, 'instructions', pr.special_instructions,
    'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', i.id, 'order_ref', o.order_ref, 'customer', o.customer_name, 'sku', i.sku, 'product', l.product_name, 'colour', i.colour, 'size', i.size,
        'qty_sent', i.qty_sent, 'qty_outstanding', i.qty_outstanding,
        'counted', r.qty_counted, 'damaged', r.qty_damaged, 'issue', r.issue, 'issue_note', r.note, 'issue_resolved', r.resolved_at is not null) order by o.order_ref, i.sku)
      from flow.tp_movement_items i join flow.orders o on o.id = i.order_id join flow.order_lines l on l.id = i.order_line_id left join flow.tp_receipts r on r.item_id = i.id where i.movement_id = m.id), '[]'::jsonb),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('side', g.side, 'author', g.author, 'body', g.body, 'at', g.created_at) order by g.created_at) from flow.tp_messages g where g.movement_id = m.id), '[]'::jsonb),
    'evidence', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'path', e.storage_path, 'kind', e.kind, 'caption', e.caption, 'at', e.created_at) order by e.created_at) from flow.tp_evidence e where e.movement_id = m.id), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('event', ev.event, 'at', ev.at, 'note', ev.note) order by ev.at) from flow.tp_movement_events ev where ev.movement_id = m.id
        and ev.event in ('dispatched', 'producer_accepted', 'producer_declined', 'producer_check_in', 'received_by_producer', 'production_started', 'production_complete', 'producer_delay', 'return_dispatched', 'direct_dispatched')), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
create or replace function public.portal_accept(p_code text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id);
  if m.status <> 'dispatched' then return jsonb_build_object('ok', false, 'error', 'This job can only be accepted before the goods are checked in.'); end if;
  if m.portal_accepted_at is not null then return jsonb_build_object('ok', false, 'error', 'You have already accepted this job.'); end if;
  update flow.tp_movements set portal_accepted_at = now(), portal_accepted_by = coalesce(pu.name, pu.email), portal_declined_at = null, portal_declined_reason = null where id = m.id;
  perform flow.tp_log(m.id, 'producer_accepted', 'producer:' || coalesce(pu.name, pu.email));
  perform flow.wh_audit('producer:' || coalesce(pu.name, pu.email), 'portal_accept', 'movement', m.movement_code, null, null, null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.portal_decline(p_code text, p_reason text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements; who text;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id); who := 'producer:' || coalesce(pu.name, pu.email);
  if m.status <> 'dispatched' then return jsonb_build_object('ok', false, 'error', 'This job can only be declined before the goods are checked in.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Please say why you cannot take this job.'); end if;
  update flow.tp_movements set portal_declined_at = now(), portal_declined_reason = btrim(p_reason), portal_accepted_at = null where id = m.id;
  perform flow.tp_log(m.id, 'producer_declined', who, '{}'::jsonb, p_reason);
  perform flow.exc_raise('producer_declined', 'decl:' || m.movement_code, null, format('%s declined %s: %s', (select name from flow.producers where id = m.producer_id), m.movement_code, btrim(p_reason)),
    jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)), jsonb_build_object('severity', 'critical', 'root_cause', 'producer', 'detected_by', 'producer_portal'));
  perform flow.wh_audit(who, 'portal_decline', 'movement', m.movement_code, null, null, p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- p_items: [{item_id, qty_counted, qty_damaged, issue, note}] for EVERY line
create or replace function public.portal_check_in(p_code text, p_items jsonb, p_note text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements; it flow.tp_movement_items; e jsonb; v_cnt int; v_dam int; v_issue text; v_bad boolean := false; v_lines int; v_res jsonb; who text; v_summary text := '';
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id); who := 'producer:' || coalesce(pu.name, pu.email);
  if m.status <> 'dispatched' then return jsonb_build_object('ok', false, 'error', 'Goods can only be checked in once, while the job is on its way to you.'); end if;
  if m.portal_declined_at is not null then return jsonb_build_object('ok', false, 'error', 'You declined this job. Accept it first or message us.'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then return jsonb_build_object('ok', false, 'error', 'Count every line.'); end if;
  select count(*) into v_lines from flow.tp_movement_items where movement_id = m.id;
  if jsonb_array_length(p_items) <> v_lines then return jsonb_build_object('ok', false, 'error', 'Count every line before checking the goods in.'); end if;
  for e in select * from jsonb_array_elements(p_items) loop
    select * into it from flow.tp_movement_items where id = (e->>'item_id')::uuid and movement_id = m.id;
    if it.id is null then return jsonb_build_object('ok', false, 'error', 'A line does not belong to this job.'); end if;
    v_cnt := (e->>'qty_counted')::int; v_dam := coalesce((e->>'qty_damaged')::int, 0);
    if v_cnt is null or v_cnt < 0 or v_dam < 0 or v_dam > v_cnt then return jsonb_build_object('ok', false, 'error', 'Check the counts: damaged units cannot be more than the units counted.'); end if;
    if v_cnt <> it.qty_sent or v_dam > 0 then
      v_bad := true;
      v_issue := coalesce(nullif(e->>'issue', ''), case when v_cnt < it.qty_sent then 'short' when v_cnt > it.qty_sent then 'over' else 'damaged' end);
      if v_issue not in ('short', 'over', 'damaged', 'wrong_item', 'wrong_size', 'other') then return jsonb_build_object('ok', false, 'error', 'Unknown problem type.'); end if;
      if length(btrim(coalesce(e->>'note', ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what is wrong with ' || coalesce(it.sku, 'this line') || ' (at least a few words).'); end if;
    else v_issue := null; end if;
    insert into flow.tp_receipts (movement_id, item_id, qty_sent, qty_counted, qty_damaged, issue, note, received_by)
    values (m.id, it.id, it.qty_sent, v_cnt, v_dam, v_issue, nullif(btrim(coalesce(e->>'note', '')), ''), who);
    if v_issue is not null then v_summary := v_summary || format('%s: sent %s, counted %s, damaged %s (%s). ', coalesce(it.sku, 'line'), it.qty_sent, v_cnt, v_dam, v_issue); end if;
  end loop;
  v_res := flow.tp_scan(m.movement_code, 'received_by_producer', who, jsonb_build_object('note', p_note));
  if not coalesce((v_res->>'ok')::boolean, false) then raise exception '%', v_res->>'error'; end if;
  update flow.tp_movements set portal_accepted_at = coalesce(portal_accepted_at, now()), portal_accepted_by = coalesce(portal_accepted_by, coalesce(pu.name, pu.email)) where id = m.id;
  perform flow.tp_log(m.id, 'producer_check_in', who, jsonb_build_object('clean', not v_bad), case when v_bad then v_summary else p_note end);
  if v_bad then
    perform flow.exc_raise('producer_receipt_issue', 'rcpt:' || m.movement_code, null, format('%s reported a problem on %s: %s', (select name from flow.producers where id = m.producer_id), m.movement_code, btrim(v_summary)),
      jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)), jsonb_build_object('severity', 'high', 'root_cause', 'unknown', 'detected_by', 'producer_portal'));
  end if;
  perform flow.wh_audit(who, 'portal_check_in', 'movement', m.movement_code, null, jsonb_build_object('clean', not v_bad), p_note);
  return jsonb_build_object('ok', true, 'clean', not v_bad);
end $$;

create or replace function public.portal_stage(p_code text, p_stage text, p_note text, p_new_date date) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements; who text; v_res jsonb;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id); who := 'producer:' || coalesce(pu.name, pu.email);
  if p_stage = 'in_production' then
    v_res := flow.tp_scan(m.movement_code, 'production_started', who, jsonb_build_object('note', p_note));
  elsif p_stage = 'production_complete' then
    v_res := flow.tp_scan(m.movement_code, 'production_complete', who, jsonb_build_object('note', p_note));
  elsif p_stage = 'delayed' then
    if m.status not in ('received_by_producer', 'in_production', 'production_complete') then return jsonb_build_object('ok', false, 'error', 'Check the goods in first.'); end if;
    if p_new_date is null or p_new_date < current_date then return jsonb_build_object('ok', false, 'error', 'Enter the new date you can finish by.'); end if;
    if length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why it is delayed (at least a few words).'); end if;
    update flow.tp_movements set expected_return_date = p_new_date where id = m.id;
    perform flow.tp_log(m.id, 'producer_delay', who, jsonb_build_object('new_date', p_new_date, 'was', m.expected_return_date), p_note);
    perform flow.exc_raise('producer_delay', 'delay:' || m.movement_code || ':' || p_new_date, null, format('%s says %s will be late: now %s. %s', (select name from flow.producers where id = m.producer_id), m.movement_code, to_char(p_new_date, 'DD Mon'), btrim(p_note)),
      jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)), jsonb_build_object('severity', 'high', 'root_cause', 'producer', 'detected_by', 'producer_portal'));
    v_res := jsonb_build_object('ok', true);
  else
    return jsonb_build_object('ok', false, 'error', 'Unknown stage.');
  end if;
  if not coalesce((v_res->>'ok')::boolean, false) then return jsonb_build_object('ok', false, 'error', v_res->>'error'); end if;
  perform flow.wh_audit(who, 'portal_stage_' || p_stage, 'movement', m.movement_code, null, null, p_note);
  return jsonb_build_object('ok', true);
end $$;

-- p_items: [{item_id, qty_shipped}] (outbound jobs); direct-to-customer jobs just need the carrier and tracking
create or replace function public.portal_ship(p_code text, p_items jsonb, p_carrier text, p_tracking text, p_note text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements; who text; v_res jsonb; v_out int; v_ship int := 0; e jsonb;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id); who := 'producer:' || coalesce(pu.name, pu.email);
  if length(btrim(coalesce(p_carrier, ''))) < 2 or length(btrim(coalesce(p_tracking, ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Enter the courier and the tracking reference.'); end if;
  if m.movement_type = 'direct_dispatch_to_customer' then
    v_res := flow.tp_direct_dispatch(m.movement_code, btrim(p_tracking), btrim(p_carrier), jsonb_build_object('note', p_note), who);
  else
    select coalesce(sum(qty_outstanding), 0) into v_out from flow.tp_movement_items where movement_id = m.id;
    for e in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop v_ship := v_ship + greatest(coalesce((e->>'qty_shipped')::int, 0), 0); end loop;
    if v_ship <= 0 then return jsonb_build_object('ok', false, 'error', 'Enter how many units you are sending back.'); end if;
    if v_ship < v_out and length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'You are sending fewer units than expected. Say what is happening with the rest.'); end if;
    v_res := flow.tp_scan(m.movement_code, 'return_dispatched', who, jsonb_build_object('carrier', btrim(p_carrier), 'tracking_ref', btrim(p_tracking), 'note', p_note, 'units', v_ship));
    if coalesce((v_res->>'ok')::boolean, false) and v_ship < v_out then
      perform flow.exc_raise('producer_partial_ship', 'part:' || m.movement_code, null, format('%s sent back %s of %s units on %s. %s', (select name from flow.producers where id = m.producer_id), v_ship, v_out, m.movement_code, btrim(p_note)),
        jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)), jsonb_build_object('severity', 'high', 'root_cause', 'producer', 'detected_by', 'producer_portal'));
    end if;
  end if;
  if not coalesce((v_res->>'ok')::boolean, false) then return jsonb_build_object('ok', false, 'error', coalesce(v_res->>'error', 'Could not record that.')); end if;
  perform flow.wh_audit(who, 'portal_ship', 'movement', m.movement_code, null, jsonb_build_object('carrier', p_carrier, 'tracking', p_tracking), p_note);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.portal_message(p_code text, p_body text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id);
  if length(btrim(coalesce(p_body, ''))) < 1 or length(p_body) > 2000 then return jsonb_build_object('ok', false, 'error', 'Write a message of up to 2000 characters.'); end if;
  insert into flow.tp_messages (movement_id, side, author, body) values (m.id, 'producer', coalesce(pu.name, pu.email), btrim(p_body));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.portal_evidence_add(p_code text, p_item uuid, p_path text, p_kind text, p_caption text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users; m flow.tp_movements;
begin
  pu := flow.portal_ctx(); m := flow.portal_own(p_code, pu.producer_id);
  if p_path is null or p_path not like (pu.producer_id::text || '/' || m.movement_code || '/%') then return jsonb_build_object('ok', false, 'error', 'That file is not stored in your folder for this job.'); end if;
  if p_item is not null and not exists (select 1 from flow.tp_movement_items where id = p_item and movement_id = m.id) then return jsonb_build_object('ok', false, 'error', 'That line does not belong to this job.'); end if;
  insert into flow.tp_evidence (movement_id, item_id, storage_path, kind, caption, uploaded_by) values (m.id, p_item, p_path, coalesce(nullif(p_kind, ''), 'issue'), nullif(btrim(coalesce(p_caption, '')), ''), coalesce(pu.name, pu.email));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Our side: reply, resolve a receipt issue, manage who can sign in
-- ---------------------------------------------------------------------------
create or replace function flow.pp_reply(p_movement text, p_body text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements;
begin
  m := flow.tp_find(p_movement);
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Consignment not found.'); end if;
  if length(btrim(coalesce(p_body, ''))) < 1 or length(p_body) > 2000 then return jsonb_build_object('ok', false, 'error', 'Write a message of up to 2000 characters.'); end if;
  insert into flow.tp_messages (movement_id, side, author, body) values (m.id, 'atam', p_actor, btrim(p_body));
  return jsonb_build_object('ok', true);
end $$;

create or replace function flow.pp_resolve_receipt(p_movement text, p_note text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare m flow.tp_movements; v_n int;
begin
  m := flow.tp_find(p_movement);
  if m.id is null then return jsonb_build_object('ok', false, 'error', 'Consignment not found.'); end if;
  if length(btrim(coalesce(p_note, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say what was decided (at least a few words).'); end if;
  update flow.tp_receipts set resolved_at = now(), resolved_by = p_actor, resolution_note = btrim(p_note) where movement_id = m.id and issue is not null and resolved_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'There is no open receipt problem on that consignment.'); end if;
  insert into flow.tp_messages (movement_id, side, author, body) values (m.id, 'atam', p_actor, 'We have looked at the goods-in problem you reported: ' || btrim(p_note));
  perform flow.wh_audit(p_actor, 'portal_receipt_resolved', 'movement', m.movement_code, null, null, p_note);
  return jsonb_build_object('ok', true, 'resolved', v_n);
end $$;

create or replace function flow.pp_add_user(p_producer uuid, p_email text, p_name text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pr flow.producers; v_email text := lower(btrim(coalesce(p_email, '')));
begin
  select * into pr from flow.producers where id = p_producer and is_active;
  if pr.id is null then return jsonb_build_object('ok', false, 'error', 'Decorator not found or not active.'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'Enter a valid email address.'); end if;
  if exists (select 1 from flow.producer_users where lower(email) = v_email) then return jsonb_build_object('ok', false, 'error', 'That email already has portal access (or had it). Switch it back on instead.'); end if;
  if exists (select 1 from flow.user_roles ur join auth.users u on u.id = ur.user_id where lower(u.email) = v_email) then return jsonb_build_object('ok', false, 'error', 'That email belongs to an ATAM team login. A decorator needs a different email.'); end if;
  insert into flow.producer_users (producer_id, email, name, invited_by) values (p_producer, v_email, nullif(btrim(coalesce(p_name, '')), ''), p_actor);
  perform flow.wh_audit(p_actor, 'portal_user_added', 'producer', pr.code, null, jsonb_build_object('email', v_email), null);
  return jsonb_build_object('ok', true, 'producer', pr.name, 'email', v_email);
end $$;

create or replace function flow.pp_set_user_active(p_user uuid, p_active boolean, p_reason text, p_actor text) returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare pu flow.producer_users;
begin
  select * into pu from flow.producer_users where id = p_user;
  if pu.id is null then return jsonb_build_object('ok', false, 'error', 'User not found.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'needs_reason', true, 'error', 'Say why (at least a few words).'); end if;
  update flow.producer_users set is_active = p_active where id = p_user;
  perform flow.wh_audit(p_actor, case when p_active then 'portal_user_on' else 'portal_user_off' end, 'producer', pu.email, null, null, p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- exceptions that need no one to do anything inside the portal: a message left waiting
create or replace function flow.exc_detect_portal() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', 'producer_query', 'key', 'qry:' || m.movement_code,
    'description', format('%s asked a question on %s and has had no reply for %s hours', p.name, m.movement_code, round(extract(epoch from now() - last_q.at) / 3600)),
    'links', jsonb_build_array(jsonb_build_object('type', 'movement', 'id', m.id)),
    'opts', jsonb_build_object('severity', 'medium', 'root_cause', 'producer', 'detected_by', 'automation'))), '[]'::jsonb)
  from flow.tp_movements m join flow.producers p on p.id = m.producer_id
  join lateral (select max(created_at) as at from flow.tp_messages g where g.movement_id = m.id and g.side = 'producer') last_q on true
  where last_q.at is not null and last_q.at < now() - interval '24 hours' and m.status not in ('closed', 'cancelled')
    and not exists (select 1 from flow.tp_messages g where g.movement_id = m.id and g.side = 'atam' and g.created_at > last_q.at)
$$;

create or replace function flow.exceptions_detect_all() returns jsonb language plpgsql security definer set search_path = flow, public as $$
declare d text; v_res jsonb := '[]'::jsonb; v_rows jsonb; v_out jsonb; v_ok boolean; v_start timestamptz := clock_timestamp();
begin
  foreach d in array array['supplier','producer_discrepancies','artwork','purchasing','stock_shortage','orders_at_risk','sync','logistics','system','integrity','machine_downtime','quality','producer_risk','order_changes','courier','portal'] loop
    begin
      execute format('select flow.exc_detect_%s()', d) into v_rows;
      if d = 'machine_downtime' and not flow.inhouse_on() then v_rows := '[]'::jsonb; end if;       -- in-house production is switched off: machine problems are not our business
      v_rows := coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) e
                          where not exists (select 1 from jsonb_array_elements(coalesce(e->'links', '[]'::jsonb)) l join flow.orders o on o.id::text = l->>'id'
                                            where l->>'type' = 'order' and flow.order_scope(o) = 'out_of_scope')), '[]'::jsonb);
      v_res := v_res || jsonb_build_array(flow.exc_sync('detector:' || d, v_rows));
    exception when others then
      v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:' || d, 'error', sqlerrm));
      perform flow.notify('detector_failed', 'warning', 'Exception detector failed: ' || d, sqlerrm, null, null);
    end;
  end loop;
  begin
    v_res := v_res || jsonb_build_array(flow.exc_sync('detector:completed_open', flow.exc_detect_completed_open()));
  exception when others then v_res := v_res || jsonb_build_array(jsonb_build_object('detector', 'detector:completed_open', 'error', sqlerrm));
  end;
  v_ok := not exists (select 1 from jsonb_array_elements(v_res) x where x ? 'error');
  v_out := jsonb_build_object('ok', v_ok, 'at', now(), 'detectors', v_res,
    'open_now', (select count(*) from flow.exceptions where status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')),
    'critical_open', (select count(*) from flow.exceptions where severity = 'critical' and status in ('open','investigating','awaiting_supplier','awaiting_producer','awaiting_customer')));
  insert into flow.flow_runs (workflow, status, triggered_by, started_at, finished_at, summary, error)
  values ('exceptions', case when v_ok then 'success' else 'partial' end::flow.run_status, 'detector', v_start, clock_timestamp(),
          jsonb_build_object('open_now', v_out->'open_now', 'critical_open', v_out->'critical_open'),
          (select string_agg(x->>'detector' || ': ' || (x->>'error'), '; ') from jsonb_array_elements(v_res) x where x ? 'error'));
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- Read models for our side, wrappers, grants, photo storage
-- ---------------------------------------------------------------------------
create or replace view public.ui_portal_users with (security_invoker = true) as
  select u.id, u.producer_id, p.name as producer, u.email, u.name, u.is_active, (u.user_id is not null) as has_signed_in, u.invited_at, u.last_seen_at
  from flow.producer_users u join flow.producers p on p.id = u.producer_id;
create or replace view public.ui_tp_messages with (security_invoker = true) as
  select g.id, m.movement_code, g.side, g.author, g.body, g.created_at from flow.tp_messages g join flow.tp_movements m on m.id = g.movement_id;
create or replace view public.ui_tp_receipts with (security_invoker = true) as
  select r.id, m.movement_code, i.sku, i.colour, i.size, r.qty_sent, r.qty_counted, r.qty_damaged, r.issue, r.note, r.received_by, r.received_at, r.resolved_at, r.resolved_by, r.resolution_note
  from flow.tp_receipts r join flow.tp_movements m on m.id = r.movement_id join flow.tp_movement_items i on i.id = r.item_id;
create or replace view public.ui_tp_evidence with (security_invoker = true) as
  select e.id, m.movement_code, i.sku, e.storage_path, e.kind, e.caption, e.uploaded_by, e.created_at
  from flow.tp_evidence e join flow.tp_movements m on m.id = e.movement_id left join flow.tp_movement_items i on i.id = e.item_id;

create or replace function public.flow_pp_reply(p_movement text, p_body text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pp_reply(p_movement, p_body, p_actor) $$;
create or replace function public.flow_pp_resolve_receipt(p_movement text, p_note text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pp_resolve_receipt(p_movement, p_note, p_actor) $$;
create or replace function public.flow_pp_add_user(p_producer uuid, p_email text, p_name text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pp_add_user(p_producer, p_email, p_name, p_actor) $$;
create or replace function public.flow_pp_set_user_active(p_user uuid, p_active boolean, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.pp_set_user_active(p_user, p_active, p_reason, p_actor) $$;

do $$
declare f text;
begin
  -- internal wrappers: service role only
  foreach f in array array['public.flow_pp_reply(text,text,text)', 'public.flow_pp_resolve_receipt(text,text,text)', 'public.flow_pp_add_user(uuid,text,text,text)', 'public.flow_pp_set_user_active(uuid,boolean,text,text)']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); execute format('grant execute on function %s to service_role', f); end loop;
  -- everything in flow stays closed to browser roles
  foreach f in array array['flow.portal_ctx()', 'flow.portal_own(text,uuid)', 'flow.pp_reply(text,text,text)', 'flow.pp_resolve_receipt(text,text,text)', 'flow.pp_add_user(uuid,text,text,text)', 'flow.pp_set_user_active(uuid,boolean,text,text)', 'flow.exc_detect_portal()', 'flow.exceptions_detect_all()']
  loop execute format('revoke all on function %s from public, anon, authenticated', f); end loop;
  grant execute on function flow.portal_state(flow.tp_movements) to authenticated, service_role;
  -- the portal: logged-in decorators only, never anonymous
  foreach f in array array['public.portal_my_producer()', 'public.portal_whoami()', 'public.portal_jobs()', 'public.portal_job(text)', 'public.portal_accept(text)', 'public.portal_decline(text,text)', 'public.portal_check_in(text,jsonb,text)', 'public.portal_stage(text,text,text,date)', 'public.portal_ship(text,jsonb,text,text,text)', 'public.portal_message(text,text)', 'public.portal_evidence_add(text,uuid,text,text,text)']
  loop execute format('revoke all on function %s from public, anon', f); execute format('grant execute on function %s to authenticated', f); end loop;
  revoke all on public.ui_portal_users, public.ui_tp_messages, public.ui_tp_receipts, public.ui_tp_evidence from public, anon;
  grant select on public.ui_portal_users, public.ui_tp_messages, public.ui_tp_receipts, public.ui_tp_evidence to authenticated;
end $$;

-- private photo storage, one folder per decorator: <producer id>/<consignment>/<file>
do $$
begin
  if to_regclass('storage.objects') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('producer-evidence', 'producer-evidence', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
    on conflict (id) do nothing;
    execute $p$create policy producer_evidence_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'producer-evidence' and (storage.foldername(name))[1] = public.portal_my_producer()::text)$p$;
    execute $p$create policy producer_evidence_select on storage.objects for select to authenticated
      using (bucket_id = 'producer-evidence' and ((storage.foldername(name))[1] = public.portal_my_producer()::text or flow.is_member()))$p$;
  end if;
end $$;
