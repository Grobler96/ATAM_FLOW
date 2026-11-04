import type { Tone } from '../ui/primitives';
import type { OrderRow } from '../data/types';

export const ORDER_STATUS: Record<string, { label: string; tone: Tone }> = {
  awaiting_stock: { label: 'Awaiting stock', tone: 'high' }, stock_allocated: { label: 'Stock allocated', tone: 'info' }, ready_for_production: { label: 'Ready to produce', tone: 'good' },
  in_production: { label: 'In production', tone: 'info' }, quality_check: { label: 'Quality check', tone: 'info' }, ready_for_dispatch: { label: 'Ready to dispatch', tone: 'good' },
  dispatched: { label: 'Dispatched', tone: 'good' }, blocked: { label: 'Blocked', tone: 'critical' }, on_hold: { label: 'On hold', tone: 'medium' }
};
export const statusLabel = (s: string) => ORDER_STATUS[s]?.label ?? s.replace(/_/g, ' ');
export const PRIORITY: Record<number, { label: string; tone: Tone }> = { 0: { label: 'Normal', tone: '' }, 1: { label: 'High', tone: 'medium' }, 2: { label: 'Rush', tone: 'high' }, 3: { label: 'Critical', tone: 'critical' } };

export function dueLabel(days: number | null): { text: string; tone: Tone } {
  if (days === null || days === undefined) return { text: 'No date', tone: '' };
  if (days < 0) return { text: `${-days}d overdue`, tone: 'critical' };
  if (days === 0) return { text: 'Today', tone: 'high' };
  if (days === 1) return { text: 'Tomorrow', tone: 'medium' };
  return { text: `in ${days}d`, tone: days <= 3 ? 'medium' : '' };
}

export const TP_STATUS_LABEL: Record<string, string> = { ready_to_send: 'Ready to send', picked: 'Picked', packed: 'Packed', dispatched: 'Dispatched', received_by_producer: 'Received by producer', in_production: 'In production at producer',
  production_complete: 'Production complete', awaiting_return: 'Awaiting return', in_transit_back: 'Returning', partially_returned: 'Partly returned', returned: 'Returned', checked: 'Checked', closed: 'Closed', exception: 'Exception', draft: 'Draft', cancelled: 'Cancelled' };
export const CUSTODY_LABEL: Record<string, string> = { at_supplier_incoming: 'Incoming from supplier', in_warehouse: 'In warehouse', allocated_to_order: 'Allocated to order', in_internal_production: 'In internal production', picked_for_producer: 'Picked for producer',
  in_transit_to_producer: 'In transit to producer', at_producer: 'At producer', in_production_at_producer: 'In production at producer', in_transit_back: 'Returning from producer', returned_to_warehouse: 'Returned to warehouse',
  ready_for_dispatch: 'Ready to dispatch', dispatched_to_customer: 'Dispatched to customer', lost_damaged_discrepancy: 'Lost / damaged' };
export const PO_STATUS_LABEL: Record<string, string> = { draft: 'Draft', approved: 'Approved', sent: 'Sent', acknowledged: 'Acknowledged', partially_received: 'Part received', received: 'Received', short_shipped: 'Short-shipped', cancelled: 'Cancelled', closed: 'Closed' };
export const METHOD_LABEL: Record<string, string> = { embroidery: 'Embroidery', dtf: 'DTF', dtg: 'DTG', uv: 'UV', vinyl: 'Vinyl', screen: 'Screen print', transfer: 'Transfer' };

export function stockStatus(o: OrderRow): { label: string; tone: Tone } {
  if (['ready_for_production', 'in_production', 'quality_check', 'ready_for_dispatch', 'dispatched'].includes(o.order_status)) return { label: 'Secured', tone: 'good' };
  if (o.order_status === 'awaiting_stock' || o.order_status === 'stock_allocated') {
    if (o.units_short === 0 && o.units_needed > 0) return { label: 'Allocated', tone: 'good' };
    if (o.units_allocated > 0) return { label: `Partial ${o.pct_allocated}%`, tone: 'medium' };
    return { label: o.units_needed > 0 ? `Short ${o.units_short}` : 'Awaiting', tone: 'high' };
  }
  return { label: '—', tone: '' };
}
export const money = (n: number | null | undefined, dp = 0) => (n == null ? '—' : (n < 0 ? '-£' : '£') + Math.abs(n).toLocaleString('en-GB', { minimumFractionDigits: dp, maximumFractionDigits: dp }));
export const shortDate = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }) : '—');
export const pct = (n: number | null | undefined) => (n == null ? '—' : `${Math.round(n)}%`);
export const plural = (n: number, one: string, many = one + 's') => `${n.toLocaleString('en-GB')} ${n === 1 ? one : many}`;
export const startOfToday = () => { const d = new Date(); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); };
export const within = (iso: string | null | undefined, days: number) => !!iso && Date.parse(iso) < startOfToday() + (days + 1) * 86400000;
