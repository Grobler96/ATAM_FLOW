-- 24 Nov 2026: suggestions for the Update log (NOT YET APPLIED).
-- The functions are named update_log_*, NOT suggest_update etc., because ATAM GO shares this Supabase project and already owns those names.
-- The Update log page (timeline of every change) lives in the dashboard code. This adds the other half, the same as ATAM GO has: the team's
-- suggestions for new updates, each rated 1 (nice to have) to 5 (needed now), ranked by points.
--   * Anyone on the team (any role) can suggest, rate and take back their own open suggestion. Nobody outside the team sees anything.
--   * One rating per person per suggestion; changing it replaces the old one. The suggester's own rating goes in with the suggestion.
--   * Managers and admins move a suggestion between open / planned / built / declined, from the page.
--   * Nothing is ever hard-deleted except a person taking back their own open suggestion.
create table flow.update_suggestions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 3 and 120),
  detail text check (detail is null or char_length(detail) <= 1000),
  area text check (area is null or char_length(area) <= 40),
  suggested_by uuid not null,
  suggested_by_name text,
  status text not null default 'open' check (status in ('open', 'planned', 'built', 'declined')),
  status_by uuid,
  status_at timestamptz,
  created_at timestamptz not null default now()
);
create table flow.update_suggestion_ratings (
  suggestion_id uuid not null references flow.update_suggestions(id) on delete cascade,
  user_id uuid not null,
  importance int not null check (importance between 1 and 5),
  rated_at timestamptz not null default now(),
  primary key (suggestion_id, user_id)
);
alter table flow.update_suggestions enable row level security;
alter table flow.update_suggestion_ratings enable row level security;
revoke all on flow.update_suggestions, flow.update_suggestion_ratings from public, anon, authenticated;
grant select on flow.update_suggestions, flow.update_suggestion_ratings to authenticated;
create policy team_read on flow.update_suggestions for select to authenticated using (flow.is_member());
create policy team_read on flow.update_suggestion_ratings for select to authenticated using (flow.is_member());

create or replace view public.ui_update_suggestions with (security_invoker = true) as
select s.id, s.title, s.detail, s.area, s.suggested_by_name, s.status, s.status_at, s.created_at,
       (s.suggested_by = auth.uid()) as mine,
       count(r.user_id)::int as votes,
       coalesce(sum(r.importance), 0)::int as points,
       round(avg(r.importance)::numeric, 1) as avg_importance,
       max(r.importance) filter (where r.user_id = auth.uid()) as my_rating
from flow.update_suggestions s
left join flow.update_suggestion_ratings r on r.suggestion_id = s.id
where flow.is_member()
group by s.id;

create or replace function public.update_log_suggest(p_title text, p_detail text, p_area text, p_importance int) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_name text; v_id uuid;
begin
  if not flow.is_member() then return jsonb_build_object('ok', false, 'error', 'Only the team can add suggestions.'); end if;
  if char_length(btrim(coalesce(p_title, ''))) < 3 then return jsonb_build_object('ok', false, 'error', 'Give the suggestion a short title first.'); end if;
  if char_length(btrim(p_title)) > 120 then return jsonb_build_object('ok', false, 'error', 'Keep the title under 120 characters.'); end if;
  if char_length(coalesce(p_detail, '')) > 1000 then return jsonb_build_object('ok', false, 'error', 'Keep the details under 1,000 characters.'); end if;
  if p_importance is null or p_importance not between 1 and 5 then return jsonb_build_object('ok', false, 'error', 'Rate it from 1 to 5.'); end if;
  select coalesce(nullif(btrim(p.full_name), ''), p.email, (select u.email from auth.users u where u.id = auth.uid())) into v_name from public.profiles p where p.id = auth.uid();
  if v_name is null then select u.email into v_name from auth.users u where u.id = auth.uid(); end if;
  insert into flow.update_suggestions (title, detail, area, suggested_by, suggested_by_name)
  values (btrim(p_title), nullif(btrim(coalesce(p_detail, '')), ''), nullif(left(btrim(coalesce(p_area, '')), 40), ''), auth.uid(), v_name) returning id into v_id;
  insert into flow.update_suggestion_ratings (suggestion_id, user_id, importance) values (v_id, auth.uid(), p_importance);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.update_log_rate(p_id uuid, p_importance int) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.is_member() then return jsonb_build_object('ok', false, 'error', 'Only the team can rate suggestions.'); end if;
  if not exists (select 1 from flow.update_suggestions where id = p_id) then return jsonb_build_object('ok', false, 'error', 'That suggestion no longer exists.'); end if;
  if p_importance is null then
    delete from flow.update_suggestion_ratings where suggestion_id = p_id and user_id = auth.uid();
  else
    if p_importance not between 1 and 5 then return jsonb_build_object('ok', false, 'error', 'Rate it from 1 to 5.'); end if;
    insert into flow.update_suggestion_ratings (suggestion_id, user_id, importance) values (p_id, auth.uid(), p_importance)
    on conflict (suggestion_id, user_id) do update set importance = excluded.importance, rated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.update_log_withdraw(p_id uuid) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
declare v_n int;
begin
  if not flow.is_member() then return jsonb_build_object('ok', false, 'error', 'Only the team can change suggestions.'); end if;
  delete from flow.update_suggestions where id = p_id and suggested_by = auth.uid() and status = 'open';
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'You can only take back your own suggestion while it is still open.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.update_log_set_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = flow, public as $$
begin
  if not flow.has_role('admin', 'manager') then return jsonb_build_object('ok', false, 'error', 'Only managers and admins change a suggestion''s status.'); end if;
  if p_status not in ('open', 'planned', 'built', 'declined') then return jsonb_build_object('ok', false, 'error', 'Unknown status.'); end if;
  update flow.update_suggestions set status = p_status, status_by = auth.uid(), status_at = now() where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'That suggestion no longer exists.'); end if;
  insert into flow.audit_log (actor, action, entity, entity_id, after) values ('staff:' || auth.uid()::text, 'update_suggestion_status', 'update_suggestions', p_id::text, jsonb_build_object('status', p_status));
  return jsonb_build_object('ok', true);
end $$;

do $$
begin
  revoke all on public.ui_update_suggestions from public, anon;
  grant select on public.ui_update_suggestions to authenticated;
  revoke all on function public.update_log_suggest(text, text, text, int), public.update_log_rate(uuid, int), public.update_log_withdraw(uuid), public.update_log_set_status(uuid, text) from public, anon;
  grant execute on function public.update_log_suggest(text, text, text, int), public.update_log_rate(uuid, int), public.update_log_withdraw(uuid), public.update_log_set_status(uuid, text) to authenticated;
end $$;
