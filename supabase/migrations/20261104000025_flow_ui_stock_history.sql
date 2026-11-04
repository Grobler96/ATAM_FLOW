create or replace view public.ui_stock_movements with (security_invoker = true) as
  select m.id, m.at, s.sku, m.movement_type, m.qty, m.ref_type, m.ref_id, m.note from flow.stock_movements m join flow.stock_items s on s.id = m.stock_item_id;
revoke all on public.ui_stock_movements from public, anon;
grant select on public.ui_stock_movements to authenticated;
