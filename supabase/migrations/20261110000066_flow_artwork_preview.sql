-- Artwork preview pictures from DecoNetwork.
-- The staff artwork view gains one column, thumbnail_url: DecoNetwork's public preview picture of the decorated view. It is only a preview; it is not the
-- production file and it carries no access key. The links to the real files (production, editable, source) are deliberately NOT in this view, and the
-- sync does not store them: they carry an account key and DecoNetwork refuses to serve them to this system anyway.
create or replace view public.ui_artwork_files with (security_invoker = true) as
select a.id, a.order_id, o.order_ref, o.customer_name, o.due_date, a.deco_line_id, a.area, a.process, a.version, a.is_current, a.source, a.approval_status, a.storage_status, a.storage_path,
       a.file_format, a.stitch_count, a.width_mm, a.height_mm, a.placement, a.readable, (a.proof_url is not null) as has_deconetwork_proof, a.proof_url, a.note, a.created_by, a.created_at, a.stored_at,
       a.thumbnail_url
from flow.artwork_files a join flow.orders o on o.id = a.order_id;
