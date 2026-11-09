-- Decorator portal hardening (all inside the portal, nothing shared with other apps on the project):
--  1. Inactivity sign-out, enforced by the database on every portal call (the page also signs out on its own).
--  2. A sign-in log: first sign-ins, new devices, and refused logins (someone signed in who is not an invited decorator).
--  3. Company addresses only: personal mail domains cannot be invited unless an admin allows that address with a reason.
-- Values are PLACEHOLDERS in flow_settings 'portal.security' until the business sets real ones.
insert into flow.flow_settings (key, value, description) values
 ('portal.security', '{"idle_minutes": 120, "block_personal_email": true,
   "personal_domains": ["gmail.com","googlemail.com","outlook.com","hotmail.com","hotmail.co.uk","live.com","live.co.uk","msn.com","yahoo.com","yahoo.co.uk","icloud.com","me.com","aol.com","proton.me","protonmail.com","btinternet.com","sky.com","talktalk.net","virginmedia.com","mail.com"]}'::jsonb,
  'PLACEHOLDERS. Decorator portal: minutes of inactivity before a decorator is signed out; whether personal email domains are refused when inviting; and which domains count as personal.')
on conflict (key) do nothing;

-- Fix: the settings reader flow.setting() is private, and views run as the staff login, so the small read-only helpers behind the
-- exception digest (57), purchasing (58) and this portal view were failing for staff ("permission denied for function setting").
-- They now run as their owner, like flow.stocktake_rules(); they only return configuration values.
create or replace function flow.exc_digest_cfg() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select '{"due_soon_hours": 4, "stale_hours": 48}'::jsonb || coalesce(flow.setting('exceptions.digest'), '{}'::jsonb)
$$;
create or replace function flow.purchasing_rules() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select '{"approve_over_value": 500, "no_self_approval": true, "invoice_tolerance_pct": 2, "invoice_tolerance_value": 5, "chase_enabled": false, "chase_min_days_late": 2, "chase_repeat_days": 3}'::jsonb || coalesce(flow.setting('purchasing.rules'), '{}'::jsonb)
$$;

create or replace function flow.portal_security() returns jsonb language sql stable security definer set search_path = flow, public as $$
  select '{"idle_minutes": 120, "block_personal_email": true, "personal_domains": ["gmail.com","googlemail.com","outlook.com","hotmail.com","hotmail.co.uk","live.com","live.co.uk","msn.com","yahoo.com","yahoo.co.uk","icloud.com","me.com","aol.com","proton.me","protonmail.com","btinternet.com","sky.com","talktalk.net","virginmedia.com","mail.com"]}'::jsonb
    || coalesce(flow.setting('portal.security'), '{}'::jsonb)
$$;

create table flow.portal_sessions (
  session_id       uuid primary key,
  producer_user_id uuid not null references flow.producer_users(id),
  started_at       timestamptz not null default now(),
  last_active_at   timestamptz not null default now(),
  device           text,
  ua               text,
  ip               text
);
create index portal_sessions_user on flow.portal_sessions (producer_user_id, started_at desc);

create table flow.portal_sign_ins (
  id               bigint generated always as identity primary key,
  at               timestamptz not null default now(),
  event            text not null check (event in ('first_sign_in', 'signed_in', 'new_device', 'refused')),
  producer_user_id uuid references flow.producer_users(id),
  email            text,
  device           text,
  ua               text,
  ip               text,
  note             text
);
create index portal_sign_ins_at on flow.portal_sign_ins (at desc);
alter table flow.portal_sessions enable row level security;
alter table flow.portal_sign_ins enable row level security;
create policy portal_sign_ins_read on flow.portal_sign_ins for select to authenticated using (flow.is_member());

create table flow.portal_email_allowances (
  email      text primary key,
  reason     text not null,
  allowed_by text not null,
  allowed_at timestamptz not null default now()
);
alter table flow.portal_email_allowances enable row level security;
create policy portal_email_allowances_read on flow.portal_email_allowances for select to authenticated using (flow.is_member());

create or replace function flow.portal_is_personal_email(p_email text) returns boolean language sql stable set search_path = flow, public as $$
  select split_part(lower(btrim(coalesce(p_email, ''))), '@', 2) in (select jsonb_array_elements_text(flow.portal_security()->'personal_domains'))
$$;

create or replace function flow.portal_allow_email(p_email text, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'Enter a valid email address.'); end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then return jsonb_build_object('ok', false, 'error', 'Say why this personal address is acceptable (at least a short sentence).'); end if;
  insert into flow.portal_email_allowances (email, reason, allowed_by) values (v_email, btrim(p_reason), p_actor)
  on conflict (email) do update set reason = excluded.reason, allowed_by = excluded.allowed_by, allowed_at = now();
  perform flow.wh_audit(p_actor, 'portal_email_allowed', 'portal', v_email, null, jsonb_build_object('email', v_email), p_reason);
  return jsonb_build_object('ok', true);
end $$;

-- 3. Company addresses only: patch the invite check in place.
do $$
declare v_def text;
begin
  select pg_get_functiondef('flow.pp_add_user(uuid,text,text,text)'::regprocedure) into v_def;
  if v_def not like '%portal_is_personal_email%' then
    v_def := replace(v_def, '''Enter a valid email address.''); end if;',
      '''Enter a valid email address.''); end if;
  if coalesce((flow.portal_security()->>''block_personal_email'')::boolean, true) and flow.portal_is_personal_email(v_email) and not exists (select 1 from flow.portal_email_allowances where email = v_email) then
    return jsonb_build_object(''ok'', false, ''personal_email'', true, ''error'', ''That is a personal email address. Decorators should use a company address. An admin can allow this one address, with a reason.''); end if;');
    if v_def not like '%portal_is_personal_email%' then raise exception 'pp_add_user anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- 1 and 2. Identity check on every portal call now also tracks the session: inactivity limit, sign-in log, new-device note.
create or replace function flow.portal_ctx() returns flow.producer_users
language plpgsql security definer set search_path = flow, public as $$
declare u uuid := auth.uid(); v_email text; v_conf timestamptz; pu flow.producer_users;
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb; v_hdr jsonb := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  v_sid uuid := nullif(v_claims->>'session_id', '')::uuid; v_ua text := left(coalesce(v_hdr->>'user-agent', ''), 300); v_ip text := nullif(btrim(split_part(coalesce(v_hdr->>'x-forwarded-for', ''), ',', 1)), '');
  v_dev text; v_idle int := coalesce((flow.portal_security()->>'idle_minutes')::int, 0); s flow.portal_sessions; v_first boolean; v_other boolean;
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
  if v_sid is not null then
    v_dev := md5(v_ua);
    select * into s from flow.portal_sessions where session_id = v_sid;
    if s.session_id is not null then
      if v_idle > 0 and s.last_active_at < now() - make_interval(mins => v_idle) then
        raise exception 'You were signed out after % minutes of inactivity. Please sign in again.', v_idle;
      end if;
      update flow.portal_sessions set last_active_at = now() where session_id = v_sid;
    else
      select not exists (select 1 from flow.portal_sessions where producer_user_id = pu.id) into v_first;
      select exists (select 1 from flow.portal_sessions where producer_user_id = pu.id and device = v_dev) into v_other;
      insert into flow.portal_sessions (session_id, producer_user_id, device, ua, ip) values (v_sid, pu.id, v_dev, v_ua, v_ip);
      insert into flow.portal_sign_ins (event, producer_user_id, email, device, ua, ip, note)
        values (case when v_first then 'first_sign_in' when not v_other then 'new_device' else 'signed_in' end, pu.id, pu.email, v_dev, v_ua, v_ip,
                case when not v_first and not v_other then 'Signed in from a device this person has not used before' end);
    end if;
  end if;
  update flow.producer_users set last_seen_at = now() where id = pu.id;
  return pu;
end $$;

-- The portal page asks how long the inactivity limit is.
do $$
declare v_def text;
begin
  select pg_get_functiondef('public.portal_whoami()'::regprocedure) into v_def;
  if v_def not like '%idle_minutes%' then
    v_def := replace(v_def, '''instructions'', pr.special_instructions);', '''instructions'', pr.special_instructions, ''idle_minutes'', coalesce((flow.portal_security()->>''idle_minutes'')::int, 0));');
    if v_def not like '%idle_minutes%' then raise exception 'portal_whoami anchor not found; update migration'; end if;
    execute v_def;
  end if;
end $$;

-- A login that is not an invited decorator reaches the portal: note it (once an hour per address). Staff can see who tried.
create or replace function public.portal_report_refused() returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare u uuid := auth.uid(); v_email text; v_hdr jsonb := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
begin
  if u is null then return jsonb_build_object('ok', false); end if;
  if exists (select 1 from flow.producer_users where user_id = u and is_active) then return jsonb_build_object('ok', true); end if;
  select email into v_email from auth.users where id = u;
  if v_email is not null and not exists (select 1 from flow.portal_sign_ins where event = 'refused' and lower(email) = lower(v_email) and at > now() - interval '1 hour') then
    insert into flow.portal_sign_ins (event, email, device, ua, ip, note) values ('refused', v_email, md5(left(coalesce(v_hdr->>'user-agent', ''), 300)), left(coalesce(v_hdr->>'user-agent', ''), 300),
      nullif(btrim(split_part(coalesce(v_hdr->>'x-forwarded-for', ''), ',', 1)), ''), 'Signed in, but is not an invited decorator');
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace view public.ui_portal_sign_ins with (security_invoker = true) as
  select s.id, s.at, s.event, s.email, p.name as producer, s.ip, s.ua, s.note, coalesce(s.producer_user_id, null) as user_id
  from flow.portal_sign_ins s left join flow.producer_users u on u.id = s.producer_user_id left join flow.producers p on p.id = u.producer_id
  where s.at > now() - interval '90 days';

create or replace view public.ui_portal_users with (security_invoker = true) as
  select u.id, u.producer_id, p.name as producer, u.email, u.name, u.is_active, (u.user_id is not null) as has_signed_in, u.invited_at, u.last_seen_at,
         flow.portal_is_personal_email(u.email) as personal_email,
         (select max(started_at) from flow.portal_sessions x where x.producer_user_id = u.id) as last_sign_in_at,
         exists (select 1 from flow.portal_sign_ins n where n.producer_user_id = u.id and n.event = 'new_device' and n.at > now() - interval '30 days') as new_device_30d
  from flow.producer_users u join flow.producers p on p.id = u.producer_id;

create or replace function public.flow_portal_allow_email(p_email text, p_reason text, p_actor text) returns jsonb language sql security definer set search_path = flow, public as $$ select flow.portal_allow_email(p_email, p_reason, p_actor) $$;

do $$
declare f text;
begin
  foreach f in array array['public.flow_portal_allow_email(text,text,text)', 'flow.portal_allow_email(text,text,text)', 'flow.portal_ctx()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  grant execute on function public.flow_portal_allow_email(text, text, text) to service_role;
  grant execute on function flow.portal_ctx() to service_role;
  -- Plain read helpers used inside views that staff query (security_invoker views run as the staff login). Functions created after
  -- migration 36 are private by default, so grant these explicitly (this also covers earlier digest and purchasing helpers on a fresh build).
  revoke all on function flow.portal_security(), flow.portal_is_personal_email(text), flow.exc_digest_cfg(), flow.purchasing_rules() from public, anon;
  grant execute on function flow.portal_security(), flow.portal_is_personal_email(text), flow.exc_digest_cfg(), flow.purchasing_rules() to authenticated, service_role;
  revoke all on function public.portal_report_refused() from public, anon;
  grant execute on function public.portal_report_refused() to authenticated, service_role;
  revoke all on flow.portal_sessions, flow.portal_sign_ins, flow.portal_email_allowances, public.ui_portal_sign_ins, public.ui_portal_users from public, anon;
  grant select on flow.portal_sign_ins, flow.portal_email_allowances, public.ui_portal_sign_ins, public.ui_portal_users to authenticated;
end $$;
