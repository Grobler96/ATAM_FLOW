-- Embroidery step 2b: the swatch email and its editable templates.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create temp table r (k text primary key, j jsonb);

-- 1. templates ---------------------------------------------------------------------------------------------------------------------------------
select pg_temp.assert((select count(*) = 1 and bool_and(is_default) from public.ui_email_templates where kind = 'embroidery_swatch' and code = 'embroidery_swatch_default'), 'a standard swatch template is there, and it is the default');
select pg_temp.assert((select body like '%{customer}%' and body like '%{logo}%' and body like '%{order_ref}%' and subject like '%{logo}%' from flow.email_templates where code = 'embroidery_swatch_default'), 'it uses the placeholders the dashboard fills in');
insert into r select 't0', flow.email_template_save(null, '', 'Subject', 'Body', false, true, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 't0'), 'a template needs a name');
insert into r select 't1', flow.email_template_save(null, 'Short and friendly', 'Swatch: {logo}', 'Hi {customer}, here is your swatch.', false, true, 'dashboard:tester');
select j->>'code' as t1 from r where k = 't1' \gset
select pg_temp.assert((select (j->>'ok')::bool from r where k = 't1') and (select name = 'Short and friendly' and not is_default and is_active from flow.email_templates where code = :'t1'), 'a new template can be added');
insert into r select 't2', flow.email_template_save(:'t1', 'Short and friendly v2', 'Swatch: {logo}', 'Hi {customer}, here is your swatch. Thanks', false, true, 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 't2') and (select name = 'Short and friendly v2' and body like '%Thanks' and updated_by = 'dashboard:tester' from flow.email_templates where code = :'t1'), 'a template can be edited');
insert into r select 't3', flow.email_template_save('nope', 'X', 'Y', 'Z', false, true, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 't3'), 'a template that does not exist is refused');
insert into r select 't4', flow.email_template_save('embroidery_swatch_default', 'Swatch for approval (standard)', 'S', 'B', false, true, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 't4'), 'the default cannot be un-defaulted without choosing another');
insert into r select 't5', flow.email_template_save(:'t1', 'Short and friendly v2', 'Swatch: {logo}', 'Hi {customer}', true, true, 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 't5') and (select count(*) = 1 from flow.email_templates where kind = 'embroidery_swatch' and is_default) and (select is_default from flow.email_templates where code = :'t1') and not (select is_default from flow.email_templates where code = 'embroidery_swatch_default'), 'making another template the default switches the old one off');
insert into r select 't6', flow.email_template_save(:'t1', 'Short and friendly v2', 'Swatch: {logo}', 'Hi {customer}', true, false, 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 't6'), 'the default cannot be switched off');
select pg_temp.assert((select count(*) >= 3 from flow.audit_log where action = 'email_template_saved'), 'template changes are audited');
select flow.email_template_save('embroidery_swatch_default', 'Swatch for approval (standard)', 'Your embroidery sample for approval: {logo} ({order_ref})', 'Hello {customer}', true, true, 'dashboard:tester');

-- 2. the swatch email ---------------------------------------------------------------------------------------------------------------------------
insert into flow.orders (deco_order_id, order_ref, customer_id, customer_name, due_date, order_status, stock_secured, deco_status, total_units, created_at, decoration_methods, is_active) values
 ('SW1', '#SW1', 'CUST-S', 'Seaview FC', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true),
 ('SW2', '#SW2', 'CUST-T', 'Other Club', now() + interval '9 days', 'awaiting_stock', false, 1, 8, now(), '{embroidery}', true);
select id as o1 from flow.orders where deco_order_id = 'SW1' \gset
select id as o2 from flow.orders where deco_order_id = 'SW2' \gset
insert into flow.artwork_files (order_id, deco_line_id, area, process, file_format, signature, storage_status, approval_status, stitch_count, width_mm, height_mm, source, thumbnail_url) values
 (:'o1', 'S1', 'Left Chest', 'embroidery', 'dst', 'sig-sw', 'failed', 'unknown', 5000, 80, 60, 'deconetwork', 'https://example.test/visual.png'),
 (:'o2', 'S2', 'Left Chest', 'embroidery', 'dst', 'sig-sx', 'failed', 'unknown', 5000, 80, 60, 'deconetwork', null);
insert into r select 'c1', flow.emb_create_design(:'o1', 'S1', 'Left Chest', 'Seaview crest', 'dashboard:tester');
select j->>'design_id' as d1 from r where k = 'c1' \gset
select 'https://example.test/storage/v1/object/sign/artwork/swatches/' || :'d1' || '/r1-1.jpg?token=abc' as url1 \gset
select 'swatches/' || :'d1' || '/r1-1.jpg' as path1 \gset
insert into r select 's0', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', 'embroidery_swatch_default', array['fan@seaview.test'], 'Subject', 'Body', :'path1', :'url1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's0'), 'a swatch email cannot go before the swatch is in progress');
select flow.emb_set_status(:'d1', 'swatch_in_progress', 'dashboard:tester', null);
insert into r select 's1', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', 'embroidery_swatch_default', array['not-an-email'], 'Subject', 'Body', :'path1', :'url1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's1'), 'a bad address is refused');
insert into r select 's2', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', null, array['fan@seaview.test'], 'Subject', 'Body', 'swatches/other/x.jpg', :'url1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's2'), 'a photo that is not this design''s is refused');
insert into r select 's3', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', null, array['fan@seaview.test'], 'Subject', 'Body', :'path1', 'https://evil.test/x.png', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's3'), 'a photo link that is not one of ours is refused');
insert into r select 's4', flow.emb_swatch_send(:'d1', :'o2', 'S2', 'Left Chest', null, array['fan@seaview.test'], 'Subject', 'Body', :'path1', :'url1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's4'), 'another customer''s order is refused');
insert into r select 's5', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', null, array['fan@seaview.test'], '', 'Body', :'path1', :'url1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 's5'), 'a subject is needed');
insert into r select 'q1', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', 'embroidery_swatch_default', array['Fan@Seaview.test', 'fan@seaview.test', 'boss@seaview.test'],
  'Your embroidery sample for approval: Seaview crest (#SW1)', E'Hello Seaview FC,\n\nHere is your <b>swatch</b> & more.\nSecond line.\n\nKind regards\nATAM', :'path1', :'url1', 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'comm_status' = 'pending_review' and (j->>'comm_ref') like 'COM-%' from r where k = 'q1'), 'the email is queued for approval, not sent: ' || (select j::text from r where k = 'q1'));
select j->>'comm_id' as c1, j->>'swatch_id' as sw1 from r where k = 'q1' \gset
select pg_temp.assert((select kind = 'other' and status = 'pending_review' and requires_review and to_addresses = array['fan@seaview.test', 'boss@seaview.test'] and entity_type = 'emb_swatch' and subject like 'Your embroidery sample%' from flow.communications where id = :'c1'), 'it waits in the normal approval queue, addresses tidied and not repeated');
select pg_temp.assert((select body_text like '%Here is your <b>swatch</b> & more.%' and body_text like '%Photo of the swatch: https://example.test/storage/v1/object/sign/artwork/swatches/%' from flow.communications where id = :'c1'), 'the plain text carries the message and the photo link');
select pg_temp.assert((select body_html like '%&lt;b&gt;swatch&lt;/b&gt; &amp; more.<br>Second line.%' and body_html like '%<img src="https://example.test/storage/v1/object/sign/artwork/swatches/%' and body_html like '%https://example.test/visual.png%' and body_html not like '%<b>swatch</b>%' from flow.communications where id = :'c1'), 'the HTML escapes what staff typed, keeps line breaks, and shows the swatch photo and the visual');
insert into r select 'q2', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', null, array['fan@seaview.test'], 'Again', 'Body', :'path1', :'url1', 'dashboard:tester');
select pg_temp.assert(not (select (j->>'ok')::bool from r where k = 'q2') and (select j->>'error' from r where k = 'q2') like '%already waiting%', 'a second email for the same round is refused while one is waiting');
select pg_temp.assert((select status = 'queued' and comm_status = 'pending_review' and comm_ref like 'COM-%' and round = 1 from public.ui_emb_swatches where id = :'sw1'), 'staff can see the queued swatch email and where it has got to');
select pg_temp.assert((select count(*) = 1 from flow.audit_log where action = 'emb_swatch_email_queued' and entity_id = :'d1') and exists (select 1 from flow.emb_events where design_id = :'d1' and event = 'swatch_email_queued'), 'queuing is audited and in the history');
select pg_temp.assert((select status = 'swatch_in_progress' from flow.emb_designs where id = :'d1'), 'queuing does not move the design: only sending does');

-- 3. a person approves it and the sender sends it: the design moves to "swatch sent"
select flow.comm_approve(:'c1'::uuid, 'dashboard:approver');
select flow.comm_mark_sent(:'c1'::uuid, 'provider-1');
select pg_temp.assert((select status = 'swatch_sent' and status_by = 'system' from flow.emb_designs where id = :'d1'), 'once sent, the design is "swatch sent"');
select pg_temp.assert((select status = 'sent' and sent_at is not null and comm_status = 'sent' from public.ui_emb_swatches where id = :'sw1'), 'the swatch email shows as sent');
select pg_temp.assert(exists (select 1 from flow.emb_events where design_id = :'d1' and event = 'status' and from_status = 'swatch_in_progress' and to_status = 'swatch_sent' and note = 'Swatch email sent'), 'the move is in the history');

-- 4. the customer wants changes: round 2, another email, this one cancelled before sending
select flow.emb_set_status(:'d1', 'changes_needed', 'dashboard:tester', 'Thread too dark');
select flow.emb_set_status(:'d1', 'swatch_in_progress', 'dashboard:tester', null);
select 'swatches/' || :'d1' || '/r2-1.jpg' as path2 \gset
select 'https://example.test/storage/v1/object/sign/artwork/swatches/' || :'d1' || '/r2-1.jpg?token=def' as url2 \gset
insert into r select 'q3', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', null, array['fan@seaview.test'], 'Sample 2', 'Here is the second sample.', :'path2', :'url2', 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'q3') and (select round = 2 from flow.emb_swatches where id = (select (j->>'swatch_id')::uuid from r where k = 'q3')), 'round 2 can have its own email');
select j->>'comm_id' as c3 from r where k = 'q3' \gset
select flow.comm_cancel(:'c3'::uuid, 'dashboard:tester');
select pg_temp.assert((select status = 'cancelled' from flow.emb_swatches where comm_id = :'c3') and (select status = 'swatch_in_progress' from flow.emb_designs where id = :'d1') and exists (select 1 from flow.emb_events where design_id = :'d1' and event = 'swatch_email_cancelled'), 'cancelling marks the swatch email cancelled and leaves the design where it was');
insert into r select 'q4', flow.emb_swatch_send(:'d1', :'o1', 'S1', 'Left Chest', null, array['fan@seaview.test'], 'Sample 2 again', 'Here is the second sample, again.', :'path2', :'url2', 'dashboard:tester');
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'q4'), 'after cancelling, a new email can be queued for the same round');

-- 5. privileges
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_emb_swatch_send(uuid,uuid,text,text,text,text[],text,text,text,text,text)', 'execute') and not has_function_privilege('anon', 'public.flow_email_template_save(text,text,text,text,boolean,boolean,text)', 'execute') and has_function_privilege('service_role', 'public.flow_emb_swatch_send(uuid,uuid,text,text,text,text[],text,text,text,text,text)', 'execute') and not has_function_privilege('authenticated', 'flow.emb_swatch_send(uuid,uuid,text,text,text,text[],text,text,text,text,text)', 'execute'), 'only the service role can queue a swatch email or save a template');
select pg_temp.assert(has_table_privilege('authenticated', 'flow.email_templates', 'select') and not has_table_privilege('authenticated', 'flow.email_templates', 'update') and not has_table_privilege('authenticated', 'flow.emb_swatches', 'insert'), 'staff can read templates and swatch emails but not write them directly');
select 'emb_swatch_test OK';
