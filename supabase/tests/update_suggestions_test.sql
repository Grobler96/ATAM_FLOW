-- Update log suggestions: suggest, rate, change a rating, withdraw, status, and who can do what.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
insert into public.profiles (id, full_name, email) values ('00000000-0000-0000-0000-0000005ad001', 'Dan Tester', 'dan@x.test') on conflict do nothing;
insert into flow.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000005ad001', 'admin'), ('00000000-0000-0000-0000-0000005ad002', 'viewer') on conflict do nothing;

select pg_temp.as_user('00000000-0000-0000-0000-0000005ad001');
select (public.update_log_suggest('  Add a supplier league table ', 'Rank suppliers by lateness', 'Suppliers', 4)->>'id')::uuid as s1 \gset
select pg_temp.assert((select title = 'Add a supplier league table' and suggested_by_name = 'Dan Tester' and mine and votes = 1 and points = 4 and my_rating = 4 and status = 'open' from public.ui_update_suggestions where id = :'s1'), 'a suggestion is saved trimmed, with the name and the first rating');
select pg_temp.assert(not (public.update_log_suggest('ab', null, null, 3)->>'ok')::bool, 'a too-short title is refused');
select pg_temp.assert(not (public.update_log_suggest('A fine title', null, null, 9)->>'ok')::bool, 'a rating outside 1 to 5 is refused');

select pg_temp.as_user('00000000-0000-0000-0000-0000005ad002');
select pg_temp.assert((public.update_log_rate(:'s1', 2)->>'ok')::bool, 'a viewer can rate');
select pg_temp.assert((select votes = 2 and points = 6 and avg_importance = 3.0 and my_rating = 2 and not mine from public.ui_update_suggestions where id = :'s1'), 'ratings add up and each person sees their own');
select public.update_log_rate(:'s1', 5);
select pg_temp.assert((select votes = 2 and points = 9 from public.ui_update_suggestions where id = :'s1'), 'changing a rating replaces the old one');
select public.update_log_rate(:'s1', null);
select pg_temp.assert((select votes = 1 and my_rating is null from public.ui_update_suggestions where id = :'s1'), 'a null rating takes it back');
select pg_temp.assert(not (public.update_log_withdraw(:'s1')->>'ok')::bool, 'someone else cannot take it back');
select pg_temp.assert(not (public.update_log_set_status(:'s1', 'planned')->>'ok')::bool, 'a viewer cannot change the status');

select pg_temp.as_user('00000000-0000-0000-0000-0000005ad001');
select pg_temp.assert((public.update_log_set_status(:'s1', 'planned')->>'ok')::bool, 'an admin can change the status');
select pg_temp.assert((select status = 'planned' and status_at is not null from public.ui_update_suggestions where id = :'s1'), 'it is now planned');
select pg_temp.assert(not (public.update_log_set_status(:'s1', 'bogus')->>'ok')::bool, 'an unknown status is refused');
select pg_temp.assert(not (public.update_log_withdraw(:'s1')->>'ok')::bool, 'a planned suggestion can no longer be taken back');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where action = 'update_suggestion_status'), 'the status change is in the audit log');
select (public.update_log_suggest('Take me back', null, null, 1)->>'id')::uuid as s2 \gset
select pg_temp.assert((public.update_log_withdraw(:'s2')->>'ok')::bool, 'the owner can take back an open suggestion');
select pg_temp.assert(not exists (select 1 from public.ui_update_suggestions where id = :'s2'), 'and it is gone');

select pg_temp.as_user('00000000-0000-0000-0000-0000005ad009');
select pg_temp.assert((select count(*) = 0 from public.ui_update_suggestions), 'someone outside the team sees nothing');
select pg_temp.assert(not (public.update_log_suggest('Outsider idea', null, null, 3)->>'ok')::bool, 'someone outside the team cannot suggest');
select pg_temp.assert(not has_function_privilege('anon', 'public.update_log_suggest(text,text,text,int)', 'execute') and not has_table_privilege('anon', 'public.ui_update_suggestions', 'select') and not has_table_privilege('authenticated', 'flow.update_suggestions', 'insert'), 'anonymous visitors have nothing and nobody writes the tables directly');
select 'update_suggestions_test OK' as result;
