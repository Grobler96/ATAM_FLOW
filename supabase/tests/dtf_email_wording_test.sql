-- The DTF email to Super Print: Daniel's wording, and a picture of each design.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, decoration_methods, third_party_flag) values
 ('EW1', '#EW1', 'Wording', now() + interval '9 days', 'awaiting_stock', false, 1, 3, '{dtf}', false);
select id as o1 from flow.orders where deco_order_id = 'EW1' \gset
select flow.dtf_sync(:'o1', '[{"deco_line_id":"N1","area":"Back","qty":1},{"deco_line_id":"N1","area":"Front","qty":1},{"deco_line_id":"N1","area":"Sleeve","qty":1},{"deco_line_id":"N1","area":"Neck","qty":1}]'::jsonb);
insert into flow.artwork_files (order_id, deco_line_id, area, process, thumbnail_url, file_format, signature, storage_status, storage_path, content_hash) values
 (:'o1', 'N1', 'Back',   'dtf', null,                          'png', 'e1', 'stored', 'ew/o1/back.png',   'hash-E1'),
 (:'o1', 'N1', 'Front',  'dtf', 'https://example.test/own.png', 'png', 'e2', 'stored', 'ew/o1/front.png',  'hash-E2'),
 (:'o1', 'N1', 'Sleeve', 'dtf', null,                          'dst', 'e3', 'stored', 'ew/o1/sleeve.dst', 'hash-E3'),
 (:'o1', 'N1', 'Neck',   'dtf', null,                          'jpg', 'e4', 'stored', 'ew/o1/neck.jpg',   'hash-E4');
create temp table r (k text primary key, j jsonb);
insert into r select 'b', flow.dtf_build_order(array[:'o1']::uuid[], jsonb_build_object('ew/o1/back.png', 'https://example.test/sign/back', 'ew/o1/front.png', 'https://example.test/sign/front', 'ew/o1/sleeve.dst', 'https://example.test/sign/sleeve', 'ew/o1/neck.jpg', 'https://example.test/sign/neck'), 'tester', null);
select pg_temp.assert((select (j->>'ok')::bool from r where k = 'b'), 'built: ' || (select j::text from r where k = 'b'));
select c.body_text, c.body_html from flow.communications c join flow.dtf_batches b on b.comm_id = c.id where b.id = (select (j->>'batch_id')::uuid from r where k = 'b') \gset
select pg_temp.assert(:'body_text' like 'Hi Supa print,%' and :'body_html' like '<p>Hi Supa print,</p>%', 'the email opens "Hi Supa print"');
select pg_temp.assert(:'body_text' not like 'Hello,%' and :'body_html' not like '%<p>Hello,</p>%', 'and no longer says Hello');
select pg_temp.assert(:'body_text' like '%please don''t hesitate to contact us by replying to this email or by calling us on 0330 159 6344.%' and :'body_html' like '%please don''t hesitate to contact us by replying to this email or by calling us on 0330 159 6344.%', 'it says what to do if there are problems, in both the plain text and the HTML');
select pg_temp.assert(:'body_text' like E'%Thank you\nAtam Support Team\n' and :'body_html' like '%Thank you<br>Atam Support Team</p>', 'it is signed Atam Support Team');
select pg_temp.assert(:'body_text' like '%Please could we order the following DTF prints (DTF-%' and :'body_html' like '%The quantity is the number of prints needed for each design.%' and :'body_html' like '%The download links expire after 14 days%', 'the body Daniel was happy with is unchanged');
-- pictures
select pg_temp.assert(:'body_html' like '%<img src="https://example.test/sign/back"%', 'a PNG with no preview uses the stored file as its picture');
select pg_temp.assert(:'body_html' like '%<img src="https://example.test/sign/neck"%', 'so does a JPG');
select pg_temp.assert(:'body_html' like '%<img src="https://example.test/own.png"%' and :'body_html' not like '%<img src="https://example.test/sign/front"%', 'a design that has its own preview keeps it');
select pg_temp.assert(:'body_html' not like '%<img src="https://example.test/sign/sleeve"%', 'an embroidery-type file that cannot be shown as a picture has none');
select pg_temp.assert((length(:'body_html') - length(replace(:'body_html', '<img ', ''))) / 5 = 3, 'three of the four designs have a picture');
select 'dtf_email_wording_test OK' as result;
