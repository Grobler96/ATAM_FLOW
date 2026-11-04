-- POs to chase: open purchase orders past their expected date, with the orders waiting on them.
-- Long-overdue POs are often goods that arrived but were never booked in, so the first step is to check, then chase.
create or replace view flow.v_overdue_pos with (security_invoker = true) as
select p.id as po_id, p.po_number, p.supplier, p.expected_date::date as expected_date,
       (current_date - p.expected_date::date) as days_overdue,
       case when current_date - p.expected_date::date > 30 then 'over a month late: probably received but not booked in, or lost'
            when current_date - p.expected_date::date > 14 then '2-4 weeks late: chase the supplier'
            else 'recently late' end as suggestion,
       (select count(*) from flow.po_lines x where x.po_id = p.id and x.qty_outstanding > 0)::int as lines,
       (select coalesce(sum(x.qty_outstanding), 0) from flow.po_lines x where x.po_id = p.id)::int as units_outstanding,
       (select coalesce(sum(al.qty), 0) from flow.allocations al join flow.po_lines x on x.id = al.po_line_id
         where x.po_id = p.id and al.status = 'active')::int as units_promised_to_orders,
       (select array_agg(distinct o.order_ref order by o.order_ref) from flow.allocations al join flow.po_lines x on x.id = al.po_line_id
         join flow.orders o on o.id = al.order_id where x.po_id = p.id and al.status = 'active') as orders_waiting
from flow.purchase_orders p
where p.is_active and p.expected_date::date < current_date
  and exists (select 1 from flow.po_lines x where x.po_id = p.id and x.qty_outstanding > 0);
grant select on flow.v_overdue_pos to authenticated;
