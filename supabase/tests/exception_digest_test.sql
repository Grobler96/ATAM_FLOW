-- Exception digest: flags, due-soon warnings (once), digest counts.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

select flow.exc_raise('manual_review', 'digest:overdue', 'test', 'Digest test overdue', '[]'::jsonb, '{"severity":"high"}'::jsonb) is not null as r_overdue \gset
select flow.exc_raise('manual_review', 'digest:soon', 'test', 'Digest test due soon', '[]'::jsonb, '{"severity":"medium"}'::jsonb) is not null as r_soon \gset
select flow.exc_raise('manual_review', 'digest:calm', 'test', 'Digest test calm', '[]'::jsonb, '{"severity":"low"}'::jsonb) is not null as r_calm \gset
update flow.exceptions set response_deadline = now() - interval '1 hour' where dedupe_key = 'digest:overdue';
update flow.exceptions set response_deadline = now() + interval '2 hours' where dedupe_key = 'digest:soon';
update flow.exceptions set response_deadline = now() + interval '5 days' where dedupe_key = 'digest:calm';

select pg_temp.assert((select 'overdue' = any(reasons) from public.ui_exception_attention where description = 'Digest test overdue'), 'overdue flagged');
select pg_temp.assert((select 'no_owner' = any(reasons) from public.ui_exception_attention where description = 'Digest test overdue'), 'high with no owner flagged');
select pg_temp.assert((select 'due_soon' = any(reasons) from public.ui_exception_attention where description = 'Digest test due soon'), 'due soon flagged');
select pg_temp.assert(not exists (select 1 from public.ui_exception_attention where description = 'Digest test calm'), 'a calm, recent issue is not in the attention list');

select flow.exceptions_warn_due() as w1 \gset
select pg_temp.assert(:w1 >= 1 and exists (select 1 from flow.notifications n join flow.exceptions e on e.id = n.entity_id where n.kind = 'exception_due_soon' and e.dedupe_key = 'digest:soon'), 'due-soon warning created');
select pg_temp.assert(not exists (select 1 from flow.notifications n join flow.exceptions e on e.id = n.entity_id where n.kind = 'exception_due_soon' and e.dedupe_key in ('digest:calm', 'digest:overdue')), 'no warning for calm or already overdue');
select count(*) as c1 from flow.notifications where kind = 'exception_due_soon' \gset
select flow.exceptions_warn_due();
select pg_temp.assert((select count(*) from flow.notifications where kind = 'exception_due_soon') = :c1, 'warned only once per deadline');

select pg_temp.assert((flow.exceptions_escalate()->>'ok')::bool and (flow.exceptions_escalate() ? 'warned'), 'escalation run reports the warnings');
select pg_temp.assert((select 'escalated' = any(reasons) from public.ui_exception_attention where description = 'Digest test overdue'), 'overdue issue escalated and flagged');

-- stale: no human action for longer than the limit
update flow.exceptions set detected_at = now() - interval '5 days' where dedupe_key = 'digest:calm';
select pg_temp.assert((select 'untouched' = any(reasons) from public.ui_exception_attention where description = 'Digest test calm'), 'untouched issue flagged');
select pg_temp.assert((select sum(open_count) >= 3 and sum(needs_attention) >= 3 from public.ui_exception_digest), 'digest totals by role');
\echo exception_digest_test OK
