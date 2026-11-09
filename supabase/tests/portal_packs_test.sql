-- Decorator job pack downloads: own jobs only, current version only, only files that are in those packs, no costs.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.as_user(p_uid text) returns void language sql as $$ select set_config('request.jwt.claim.sub', p_uid, false) $$;
create or replace function pg_temp.try(p_sql text) returns text language plpgsql as $$ begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create temp table r (k text primary key, j jsonb);
grant all on r to authenticated;

update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'false') where key = 'artwork.options';
insert into flow.producers (code, name, address, contact_name, turnaround_days, can_direct_dispatch, capable_methods) values
  ('PJA', 'Pack Stitchers', '1 Mill St', 'Sam', 3, false, '{embroidery}'), ('PJB', 'Pack Others', '2 Dock Rd', 'Nia', 3, false, '{embroidery}');
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, priority, total_units, created_at) values
  ('PJP1', '#PJP1', 'Pack FC', now() + interval '10 days', 'ready_for_production', true, 1, 0, 5, now() - interval '2 days'),
  ('PJP2', '#PJP2', 'Pack Other', now() + interval '10 days', 'ready_for_production', true, 1, 0, 4, now() - interval '2 days'),
  ('PJP3', '#PJP3', 'Pack Draft', now() + interval '10 days', 'ready_for_production', true, 1, 0, 3, now() - interval '2 days');
insert into flow.order_lines (deco_workflow_item_id, order_id, sku, colour, size, garment_type, product_name, qty_required, decoration_methods)
  select v.wi, o.id, v.sku, 'Navy', 'M', 'Polos', 'Polo shirt', v.q, '{embroidery}' from (values ('PJL1', 'PJP1', 'PJ-POLO-M', 5), ('PJL2', 'PJP2', 'PJ-POLO-L', 4), ('PJL3', 'PJP3', 'PJ-POLO-S', 3)) v(wi, oid, sku, q) join flow.orders o on o.deco_order_id = v.oid;
select flow.generate_bins('OUT', 'PJK', 8);
select id as pja from flow.producers where code = 'PJA' \gset
select id as pjb from flow.producers where code = 'PJB' \gset
select id as pjl1 from flow.order_lines where deco_workflow_item_id = 'PJL1' \gset
select id as pjl2 from flow.order_lines where deco_workflow_item_id = 'PJL2' \gset
select id as pjl3 from flow.order_lines where deco_workflow_item_id = 'PJL3' \gset
select id as pjo1 from flow.orders where deco_order_id = 'PJP1' \gset
select id as pjo2 from flow.orders where deco_order_id = 'PJP2' \gset
insert into r select 'a', flow.create_outbound_movement(:'pja', jsonb_build_array(jsonb_build_object('order_line_id', :'pjl1', 'qty', 5)), 'wh');
insert into r select 'b', flow.create_outbound_movement(:'pjb', jsonb_build_array(jsonb_build_object('order_line_id', :'pjl2', 'qty', 4)), 'wh');
insert into r select 'd', flow.create_outbound_movement(:'pja', jsonb_build_array(jsonb_build_object('order_line_id', :'pjl3', 'qty', 3)), 'wh');
select j->>'movement_code' as mva from r where k = 'a' \gset
select j->>'movement_code' as mvb from r where k = 'b' \gset
select j->>'movement_code' as mvd from r where k = 'd' \gset
select flow.tp_scan(:'mva', 'picked', 'w'); select flow.tp_scan(:'mva', 'packed', 'w'); select flow.tp_scan(:'mva', 'dispatched', 'w', '{"date":"2026-11-09"}');
select flow.tp_scan(:'mvb', 'picked', 'w'); select flow.tp_scan(:'mvb', 'packed', 'w'); select flow.tp_scan(:'mvb', 'dispatched', 'w', '{"date":"2026-11-09"}');
select id as mva_id from flow.tp_movements where movement_code = :'mva' \gset
select id as mvb_id from flow.tp_movements where movement_code = :'mvb' \gset
select id as mvd_id from flow.tp_movements where movement_code = :'mvd' \gset

-- Sam's pack: version 1 superseded by version 2; a blocked pack for the draft job; Nia has her own pack. Contents carry a (made-up) cost field to prove it is never passed on.
insert into flow.job_packs (pack_ref, order_id, producer_id, movement_id, version, status, contents, artwork_sig, content_hash) values
 ('JP-PJ-A1', :'pjo1', :'pja', :'mva_id', 1, 'superseded', '{"order_ref":"#PJP1","artwork":[{"area":"Old","file":"pj/old-v1.dst","approval":"approved"}]}', 's1', 'h1'),
 ('JP-PJ-A2', :'pjo1', :'pja', :'mva_id', 2, 'ready', jsonb_build_object('order_ref', '#PJP1', 'due_date', '2026-11-20', 'special_instructions', 'Left chest only', 'unit_cost', 4.5, 'margin', 0.4,
    'lines', jsonb_build_array(jsonb_build_object('product', 'Polo shirt', 'colour', 'Navy', 'placement', 'Left chest', 'sizes', jsonb_build_array(jsonb_build_object('size', 'M', 'qty', 5)), 'total_qty', 5, 'cost', 9)),
    'artwork', jsonb_build_array(jsonb_build_object('artwork_id', gen_random_uuid(), 'area', 'Left chest', 'process', 'embroidery', 'version', 2, 'file_format', 'dst', 'file', 'pj/sam/left-chest-v2.dst', 'stitch_count', 5200, 'width_mm', 90, 'height_mm', 40, 'placement', 'Left chest', 'approval', 'approved', 'source_url', 'https://secret.example/x'))), 's2', 'h2'),
 ('JP-PJ-D1', :'pjo2', :'pja', :'mvd_id', 1, 'blocked', '{"order_ref":"#PJP3","artwork":[{"area":"Back","file":"pj/sam/blocked.dst"}]}', 's3', 'h3'),
 ('JP-PJ-B1', :'pjo2', :'pjb', :'mvb_id', 1, 'ready', '{"order_ref":"#PJP2","artwork":[{"area":"Chest","file":"pj/nia/chest.dst","approval":"approved"}]}', 's4', 'h4');

insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000d1', 'sam@packs.test', now()), ('00000000-0000-0000-0000-0000000000d2', 'nia@packs.test', now());
select (flow.pp_add_user(:'pja', 'sam@packs.test', 'Sam', 'tester')->>'ok')::bool as u1 \gset
select (flow.pp_add_user(:'pjb', 'nia@packs.test', 'Nia', 'tester')->>'ok')::bool as u2 \gset
select pg_temp.assert(:'u1'::bool and :'u2'::bool, 'users added');

-- 1. Sam reads the current pack for his own job
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
set role authenticated;
insert into r select 'pack', public.portal_job_pack(:'mva');
select pg_temp.assert((select j->'packs'->0->>'pack_ref' from r where k = 'pack') = 'JP-PJ-A2' and jsonb_array_length((select j->'packs' from r where k = 'pack')) = 1, 'only the current pack is returned, not the superseded one');
select pg_temp.assert((select j->'packs'->0->'artwork'->0->>'file_name' from r where k = 'pack') = 'left-chest-v2.dst' and (select j->'packs'->0->'artwork'->0->>'file' from r where k = 'pack') = 'pj/sam/left-chest-v2.dst', 'the artwork file and its name are returned');
select pg_temp.assert((select (j->'packs'->0->'artwork'->0->>'stitch_count')::int = 5200 and j->'packs'->0->>'instructions' = 'Left chest only' from r where k = 'pack'), 'specs and instructions are returned');
select pg_temp.assert(not ((select j::text from r where k = 'pack') ~* '(cost|margin|price|source_url|secret|artwork_id)'), 'no costs, margins, source links or internal ids');
select pg_temp.assert(pg_temp.try(format('select public.portal_job_pack(%L)', :'mvb')) like '%not found%', 'another decorator''s job is not found');
select pg_temp.assert(pg_temp.try(format('select public.portal_job_pack(%L)', :'mvd')) like '%not found%', 'a job that has not been sent yet is not found');
-- 2. which files Sam may fetch
select pg_temp.assert(flow.portal_can_read_artwork('pj/sam/left-chest-v2.dst'), 'a file in his current pack can be read');
select pg_temp.assert(not flow.portal_can_read_artwork('pj/old-v1.dst'), 'a file from a superseded pack cannot');
select pg_temp.assert(not flow.portal_can_read_artwork('pj/nia/chest.dst'), 'another decorator''s file cannot');
select pg_temp.assert(not flow.portal_can_read_artwork('pj/sam/blocked.dst'), 'a file in a blocked pack for an unsent job cannot');
select pg_temp.assert(not flow.portal_can_read_artwork('anything/else.pdf') and not flow.portal_can_read_artwork(null), 'nothing else in the bucket can');
reset role;
-- 3. Nia sees only hers
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d2');
set role authenticated;
select public.portal_whoami();   -- the portal always loads first, which links the login to the invitation
select pg_temp.assert(flow.portal_can_read_artwork('pj/nia/chest.dst') and not flow.portal_can_read_artwork('pj/sam/left-chest-v2.dst'), 'the other decorator can read only her own file');
reset role;
-- 4. a declined job gives nothing
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
set role authenticated;
select (public.portal_decline(:'mva', 'Machine is down this week')->>'ok')::bool as declined \gset
select pg_temp.assert(:'declined'::bool and not flow.portal_can_read_artwork('pj/sam/left-chest-v2.dst') and jsonb_array_length((public.portal_job_pack(:'mva'))->'packs') = 0, 'after declining, the pack and its files are no longer available');
reset role;
-- 5. nobody signed out, and the helpers are not callable directly
select pg_temp.as_user('');
select pg_temp.assert(not flow.portal_can_read_artwork('pj/sam/left-chest-v2.dst'), 'a visitor with no login can read nothing');
select pg_temp.assert(not has_function_privilege('anon', 'public.portal_job_pack(text)', 'execute') and not has_function_privilege('anon', 'flow.portal_can_read_artwork(text)', 'execute'), 'anonymous visitors can call nothing');
select pg_temp.assert(not has_function_privilege('authenticated', 'flow.portal_packs(flow.tp_movements)', 'execute'), 'the pack finder is internal only');
\echo portal_packs_test OK
