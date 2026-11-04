// Synthetic data only (no real customers). Shape matches public.ui_exceptions.
const NOW = Date.now();
const iso = (hoursFromNow) => new Date(NOW + hoursFromNow * 3600000).toISOString();
let n = 0;
const mk = (o) => {
  n += 1;
  const age = o.age_hours ?? 5;
  return {
    id: `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`, exc_ref: `EXC-2026-${String(n).padStart(5, '0')}`, type_code: 'stock_shortage', type_label: 'Stock shortage with no cover', category: 'stock',
    severity: 'medium', severity_rank: 3, status: 'open', blocks: [], is_blocking: false, description: 'SKU-X is short of 3 unit(s) (0 on hand, 0 on order); earliest due 2026-11-11',
    detected_by: 'automation', detected_at: iso(-age), owner: null, owner_role: 'manager', needs_owner: true, response_deadline: iso(20), is_overdue: false, age_hours: age,
    age_bucket: age < 24 ? '< 1 day' : age < 72 ? '1-3 days' : age < 168 ? '3-7 days' : '> 7 days', escalation_level: 0, customer_impact: null, financial_impact: null, financial_breakdown: {},
    recommended_action: 'Raise a purchase order, or use an approved alternative, or tell the customer.', root_cause: null,
    order_refs: [], skus: [], po_refs: [], movement_refs: [], producers: [], communications: 0, ...o
  };
};
const sev = (s) => ({ critical: 1, high: 2, medium: 3, low: 4 })[s];

export const rows = [
  mk({ type_code: 'order_at_risk', type_label: 'Order at risk of missing dispatch', category: 'production', severity: 'critical', severity_rank: sev('critical'), is_overdue: true, response_deadline: iso(-5), age_hours: 30,
       description: 'Order #700101 (Acme Safety Ltd) is at risk: already past its due date; stock is projected to arrive after the due date', order_refs: ['#700101'], financial_impact: 2450,
       customer_impact: 'Already 3 day(s) past the promised dispatch date', escalation_level: 1, owner_role: 'admin' }),
  mk({ type_code: 'producer_no_receipt', type_label: 'Producer has not confirmed receipt', category: 'producer', severity: 'critical', severity_rank: sev('critical'), status: 'awaiting_producer', response_deadline: iso(2),
       description: 'Stitchworks has not confirmed receipt of 240 unit(s) dispatched on 2026-11-01 (TP-2026-00007)', order_refs: ['#700102', '#700103', '#700104', '#700105'], movement_refs: ['TP-2026-00007'], producers: ['Stitchworks'],
       financial_impact: 1180, financial_breakdown: { stock_exposed: 1180 }, owner: 'sam@atam.test', needs_owner: false, communications: 1, age_hours: 78 }),
  mk({ type_code: 'supplier_shortage', type_label: 'Supplier shortage', category: 'stock', severity: 'critical', severity_rank: sev('critical'), is_blocking: true, blocks: ['completion', 'dispatch'], status: 'awaiting_supplier',
       description: 'Shortage: 6 x POLO-NVY-M on PO AF-PO-1042 (Ralawise)', order_refs: ['#700106'], skus: ['POLO-NVY-M'], po_refs: ['AF-PO-1042'], owner_role: 'warehouse', financial_impact: 30 }),
  mk({ type_code: 'artwork_blocked', type_label: 'Artwork not ready', category: 'artwork', severity: 'high', severity_rank: sev('high'), is_blocking: true, blocks: ['production', 'dispatch', 'completion'],
       description: 'Order #700107: 2 artwork problem(s) (missing_artwork). First: dtf: dtf needs 1 artwork area(s) but 0 found', order_refs: ['#700107'], financial_impact: 640, owner_role: 'production' }),
  mk({ type_code: 'artwork_blocked', type_label: 'Artwork not ready', category: 'artwork', severity: 'high', severity_rank: sev('high'), is_blocking: true, blocks: ['production', 'dispatch', 'completion'],
       description: 'Order #700108: 1 artwork problem(s) (not_approved). First: Left chest: approval status is pending', order_refs: ['#700108'], financial_impact: 310, owner: 'jo@atam.test', needs_owner: false, owner_role: 'production', age_hours: 100 }),
  mk({ type_code: 'po_late', type_label: 'Purchase order late', category: 'purchasing', severity: 'high', severity_rank: sev('high'), is_overdue: true, response_deadline: iso(-30), age_hours: 200,
       description: 'PO 876499 from Ralawise is 54 day(s) late; 2 unit(s) outstanding, 0 promised to orders', po_refs: ['876499'], owner_role: 'warehouse' }),
  mk({ type_code: 'stock_shortage', severity: 'high', severity_rank: sev('high'), description: '1180.BKLM.3XL is short of 1 unit(s) (0 on hand, 1 on order); earliest due 2026-11-04', skus: ['1180.BKLM.3XL'], order_refs: ['#700109'], financial_impact: 12 }),
  mk({ type_code: 'movement_no_tracking', type_label: 'Dispatched without tracking', category: 'logistics', severity: 'medium', severity_rank: sev('medium'), description: 'Movement TP-2026-00005 dispatched on 2026-10-30 has no tracking reference', movement_refs: ['TP-2026-00005'], owner_role: 'warehouse', age_hours: 120 }),
  mk({ type_code: 'sync_stale', type_label: 'Integration has not run', category: 'integration', severity: 'high', severity_rank: sev('high'), description: 'sync_stock has not succeeded for 420 minutes (allowed 400)', owner_role: 'admin', customer_impact: 'Dashboard data may be out of date' }),
  mk({ type_code: 'integrity_order', type_label: 'Order is missing key information', category: 'data', severity: 'medium', severity_rank: sev('medium'), description: '72 active order(s) have no due date, so their priority, risk and schedule cannot be worked out', order_refs: ['#700110', '#700111', '#700112', '#700113', '#700114', '#700115'], age_hours: 200 }),
  mk({ type_code: 'order_hold_unexplained', type_label: 'Orders on hold with no recorded reason', category: 'order', severity: 'low', severity_rank: sev('low'), description: '76 order(s) are on hold with no recorded reason or owner for the hold', age_hours: 260 }),
  mk({ type_code: 'po_unacknowledged', type_label: 'Purchase order not acknowledged', category: 'purchasing', severity: 'medium', severity_rank: sev('medium'), description: 'PO AF-PO-1044 sent to Portwest on 02 Nov 09:10 has not been acknowledged', po_refs: ['AF-PO-1044'], owner: 'sam@atam.test', needs_owner: false, owner_role: 'warehouse' }),
  mk({ type_code: 'producer_discrepancy', type_label: 'Producer discrepancy', category: 'producer', severity: 'high', severity_rank: sev('high'), status: 'awaiting_producer', is_blocking: false,
       description: 'Shortage: 12 x TEE-BLK-L with Stitchworks (TP-2026-00006)', skus: ['TEE-BLK-L'], producers: ['Stitchworks'], movement_refs: ['TP-2026-00006'], order_refs: ['#700116'], financial_impact: 54 })
];
export const history = [
  { exception_id: '', at: iso(-30), actor: 'detector:orders_at_risk', action: 'detected', from_status: null, to_status: 'open', note: 'Order #700101 is at risk' },
  { exception_id: '', at: iso(-6), actor: 'system', action: 'escalated', from_status: null, to_status: null, note: 'no response by the deadline: escalated to level 1, now with manager, new deadline in 12 h' }
];
