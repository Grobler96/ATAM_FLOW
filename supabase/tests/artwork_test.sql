-- Artwork versions, validation, job packs and the dispatch gate.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as
$$ begin if not coalesce(cond, false) then raise exception 'ASSERT FAILED: %', msg; end if; end $$;
create or replace function pg_temp.try_scan(p_code text, p_event text) returns jsonb language plpgsql as
$$ begin return flow.tp_scan(p_code, p_event, 'tester'); exception when others then return jsonb_build_object('ok', false, 'error', sqlerrm); end $$;

update flow.flow_settings set value = jsonb_set(value, '{enforce_before_dispatch}', 'true') where key = 'artwork.options';
insert into flow.producers (code, name, address, turnaround_days, capable_methods, special_instructions) values ('ART', 'Artworks Ltd', '9 Print Lane', 3, '{embroidery,dtf}', 'Pack flat');
insert into flow.orders (deco_order_id, order_ref, customer_name, due_date, order_status, stock_secured, deco_status, total_units, order_value) values
  ('W1','#W1','Artwork Customer','2026-12-01 12:00+00','ready_for_production',true,1,20,999.99);
insert into flow.order_lines (deco_workflow_item_id, deco_line_id, order_id, sku, product_code, colour, size, product_name, qty_required, decoration_methods, emb_areas, decoration_placement)
select v.wi, v.dl, o.id, v.sku, v.pc, 'Navy', v.s, v.pn, v.q, v.m::text[], v.ea, 'Left chest'
from (values ('WL1','DL1','ART-POLO-M','ART-POLO','M','Polo',8,'{embroidery}',2), ('WL2','DL1','ART-POLO-L','ART-POLO','L','Polo',8,'{embroidery}',2),
             ('WL3','DL2','ART-TEE-M','ART-TEE','M','Tee',4,'{dtf}',null)) v(wi, dl, sku, pc, s, pn, q, m, ea)
join flow.orders o on o.deco_order_id = 'W1';
select id as ord from flow.orders where deco_order_id = 'W1' \gset
select id as prod from flow.producers where code = 'ART' \gset
select flow.generate_bins('OUT', 'OUT', 2);

-- 1. nothing uploaded: embroidery needs 2 areas, dtf needs 1
select pg_temp.assert((flow.artwork_validate(:'ord')->>'blocking')::int = 2 and not (flow.artwork_validate(:'ord')->>'ok')::bool, 'missing artwork blocks: ' || flow.artwork_validate(:'ord')::text);

-- 2. sync brings in artwork
create temp table r (k text primary key, j jsonb);
insert into r select 'u1', flow.artwork_upsert(jsonb_build_array(
  jsonb_build_object('deco_order_id','W1','deco_line_id','DL1','area','Left chest','process','embroidery','production_url','https://dn.test/a.dst','source_url','https://dn.test/a.ai','file_format','DST','stitch_count',5200,'width_mm',90,'height_mm',40,'approval_status','approved'),
  jsonb_build_object('deco_order_id','W1','deco_line_id','DL1','area','Back','process','embroidery','production_url','https://dn.test/b.dst','file_format','DST','approval_status','pending'),
  jsonb_build_object('deco_order_id','W1','deco_line_id','DL2','area','Front','process','dtf','production_url','https://dn.test/c.png','file_format','PNG','approval_status','approved','transfer',jsonb_build_object('temp_c',160,'seconds',12)),
  jsonb_build_object('deco_order_id','NOPE','area','x')));
select pg_temp.assert((select (j->>'new')::int = 3 and jsonb_array_length(j->'skipped') = 1 from r where k='u1'), 'three new, one skipped: ' || (select j::text from r where k='u1'));
insert into r select 'u2', flow.artwork_upsert(jsonb_build_array(
  jsonb_build_object('deco_order_id','W1','deco_line_id','DL1','area','Left chest','process','embroidery','production_url','https://dn.test/a.dst','source_url','https://dn.test/a.ai','file_format','DST','stitch_count',5200,'width_mm',90,'height_mm',40,'approval_status','approved')));
select pg_temp.assert((select (j->>'unchanged')::int = 1 and (j->>'new')::int = 0 and (j->>'updated')::int = 0 from r where k='u2'), 'identical sync changes nothing');
select pg_temp.assert((select count(*) from flow.artwork_files where order_id = :'ord') = 3, 'still three rows');

-- 3. issues: Back not approved, not downloaded and no stitch count; others not downloaded
select pg_temp.assert((select count(*) from flow.artwork_issues(:'ord') where issue = 'not_approved') = 1 and (select count(*) from flow.artwork_issues(:'ord') where issue = 'not_stored') = 3
  and (select count(*) from flow.artwork_issues(:'ord') where issue = 'missing_stitch_count') = 1, 'issues reported');
select pg_temp.assert((flow.artwork_pending_downloads(10) is not null) and jsonb_array_length(flow.artwork_pending_downloads(10)) = 3, 'three files queued for download');

-- 4. download: one unreadable
select id as a1 from flow.artwork_files where area = 'Left chest' and order_id = :'ord' \gset
select id as a2 from flow.artwork_files where area = 'Back' and order_id = :'ord' \gset
select id as a3 from flow.artwork_files where area = 'Front' and order_id = :'ord' \gset
select flow.artwork_mark_stored(:'a1', 'artwork/W1/left-chest-v1.dst', 'h1', true);
select flow.artwork_mark_stored(:'a3', 'artwork/W1/front-v1.png', 'h3', false, 'corrupt PNG');
select flow.artwork_mark_stored(:'a2', 'artwork/W1/back-v1.dst', 'h2', true);
select pg_temp.assert((select count(*) from flow.artwork_issues(:'ord') where issue = 'unreadable_file') = 1, 'unreadable file flagged');

-- 5. pack is blocked, with the reasons
insert into r select 'p1', flow.build_job_pack(:'ord', :'prod', 'tester');
select pg_temp.assert((select (j->>'ok')::bool and j->>'status' = 'blocked' and (j->>'blocking')::int >= 2 from r where k='p1'), 'pack blocked: ' || (select j::text from r where k='p1'));
select (j->>'pack_id')::uuid as jp1 from r where k = 'p1' \gset
select pg_temp.assert(not (flow.job_pack_mark_sent(:'jp1', 'tester')->>'ok')::bool, 'a blocked pack cannot be sent');

-- 6. fix: approve Back (with a note), replace the corrupt Front by hand, add the missing stitch count by manual replacement
select pg_temp.assert(not (flow.artwork_set_approval(:'a2', 'approved', 'tester', '')->>'ok')::bool, 'approval needs a note');
select pg_temp.assert((flow.artwork_set_approval(:'a2', 'approved', 'tester', 'customer confirmed by phone')->>'ok')::bool, 'approved with note');
insert into r select 'm1', flow.artwork_manual_replace(:'ord', 'DL1', 'Back', 'artwork/W1/back-manual-v2.dst', 'tester', 'Corrected stitch count', jsonb_build_object('stitch_count', 3100, 'file_format', 'DST'));
select pg_temp.assert((select (j->>'ok')::bool and (j->>'version')::int = 2 from r where k='m1'), 'manual replace is version 2');
insert into r select 'm2', flow.artwork_manual_replace(:'ord', 'DL2', 'Front', 'artwork/W1/front-manual-v2.png', 'tester', 'Re-uploaded clean PNG', '{}'::jsonb);
select pg_temp.assert((select count(*) from flow.artwork_files where order_id = :'ord' and is_current) = 3 and (select count(*) from flow.artwork_files where order_id = :'ord') = 5, 'history kept: 5 rows, 3 current');
select pg_temp.assert((flow.artwork_validate(:'ord')->>'ok')::bool, 'no blocking issues left: ' || flow.artwork_validate(:'ord')::text);

-- 7. sync must not overwrite a manual replacement
insert into r select 'u3', flow.artwork_upsert(jsonb_build_array(jsonb_build_object('deco_order_id','W1','deco_line_id','DL1','area','Back','process','embroidery','production_url','https://dn.test/b2.dst','approval_status','approved')));
select pg_temp.assert((select (j->>'manual_kept')::int = 1 from r where k='u3') and (select version from flow.artwork_files where order_id = :'ord' and area = 'Back' and is_current) = 2, 'manual version protected from sync');

-- 8. ready pack, then stale when artwork changes
insert into r select 'p2', flow.build_job_pack(:'ord', :'prod', 'tester');
select pg_temp.assert((select j->>'status' = 'ready' and (j->>'version')::int = 2 from r where k='p2'), 'pack ready (v2): ' || (select j::text from r where k='p2'));
select pg_temp.assert((select status from flow.job_packs where id = :'jp1') = 'superseded', 'old blocked pack superseded');
select (j->>'pack_id')::uuid as jp2 from r where k = 'p2' \gset
select pg_temp.assert((select (flow.build_job_pack(:'ord', :'prod', 'tester')->>'unchanged')::bool), 'rebuilding with no change returns the same pack');
select pg_temp.assert((select contents::text not like '%order_value%' and contents::text not like '%999.99%' and contents::text not like '%https://%' and contents::text not like '%unit_cost%' and contents::text like '%Pack flat%'
   and (contents->'lines'->0->>'total_qty')::int in (16, 4) from flow.job_packs where id = :'jp2'), 'pack carries no costs or source URLs, but has producer instructions and quantities');
select pg_temp.assert((select count(*) from flow.job_packs where id = :'jp2' and jsonb_array_length(contents->'artwork') = 3) = 1, 'three artwork areas in the pack');

-- 9. dispatch gate
insert into r select 'mv', flow.create_outbound_movement(:'prod', (select jsonb_agg(jsonb_build_object('order_line_id', id, 'qty', qty_required)) from flow.order_lines where order_id = :'ord'), 'tester');
select j->>'movement_code' as mv from r where k = 'mv' \gset
select pg_temp.assert((select (j->>'ok')::bool from r where k='mv'), 'movement created: ' || (select j::text from r where k='mv'));
select flow.tp_scan(:'mv', 'picked', 'tester'); select flow.tp_scan(:'mv', 'packed', 'tester');
select flow.artwork_manual_replace(:'ord', 'DL1', 'Left chest', 'artwork/W1/left-chest-v2.dst', 'tester', 'Late change', jsonb_build_object('stitch_count', 5300));
select pg_temp.assert((select is_stale from flow.v_job_packs where id = :'jp2'), 'pack is stale after artwork changes');
select pg_temp.assert(not (flow.job_pack_mark_sent(:'jp2', 'tester')->>'ok')::bool, 'stale pack cannot be sent');
select pg_temp.assert(not (pg_temp.try_scan(:'mv', 'dispatched')->>'ok')::bool, 'dispatch refused with a stale pack: ' || pg_temp.try_scan(:'mv', 'dispatched')::text);
insert into r select 'p3', flow.build_job_pack(:'ord', :'prod', 'tester');
select (j->>'pack_id')::uuid as jp3 from r where k = 'p3' \gset
select pg_temp.assert((select j->>'status' = 'ready' from r where k='p3') and (flow.job_pack_mark_sent(:'jp3', 'tester')->>'ok')::bool, 'rebuilt pack sent');
select pg_temp.assert((pg_temp.try_scan(:'mv', 'dispatched')->>'ok')::bool, 'dispatch allowed with a current pack: ' || pg_temp.try_scan(:'mv', 'dispatched')::text);
select pg_temp.assert(not has_function_privilege('authenticated', 'public.flow_build_job_pack(uuid,uuid,text,uuid)', 'execute'), 'browser roles cannot build packs directly');
select pg_temp.assert((select count(*) from flow.v_artwork_versions where order_ref = '#W1') = 6, 'version history visible');
update flow.orders set is_active = false where deco_order_id = 'W1';
\echo artwork tests passed
