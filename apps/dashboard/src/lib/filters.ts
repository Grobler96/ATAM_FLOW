import type { ExceptionRow } from '../types';

export interface ViewDef { id: string; label: string; hint?: string; match: (e: ExceptionRow) => boolean }

const types = (...t: string[]) => (e: ExceptionRow) => t.includes(e.type_code);
const cats = (...c: string[]) => (e: ExceptionRow) => c.includes(e.category);

// The groups the team asked to see. Machine downtime and quality have no detectors yet, so they show 0 rather than being hidden.
export const VIEWS: ViewDef[] = [
  { id: 'all', label: 'All open', match: () => true },
  { id: 'critical', label: 'Critical', match: (e) => e.severity === 'critical' },
  { id: 'orders', label: 'Orders at risk', hint: 'Orders that may miss dispatch', match: types('order_at_risk', 'completed_with_open_exception') },
  { id: 'stock', label: 'Stock shortages', hint: 'Short stock and late purchase orders', match: types('stock_shortage', 'supplier_shortage', 'po_late', 'po_unacknowledged') },
  { id: 'producers', label: 'Producer delays', match: cats('producer') },
  { id: 'machines', label: 'Machine downtime', hint: 'Not tracked yet', match: cats('machine') },
  { id: 'artwork', label: 'Missing artwork', match: types('artwork_blocked') },
  { id: 'quality', label: 'Quality failures', hint: 'Not tracked yet', match: cats('quality') },
  { id: 'courier', label: 'Courier issues', match: cats('logistics') },
  { id: 'discrepancies', label: 'Unresolved discrepancies', match: types('supplier_shortage', 'supplier_damage', 'supplier_incorrect', 'supplier_overage', 'supplier_other', 'producer_discrepancy', 'integrity_custody') },
  { id: 'data', label: 'Data & systems', match: (e) => ['integration', 'data'].includes(e.category) || e.type_code === 'order_hold_unexplained' }
];

export const AGE_BUCKETS = ['< 1 day', '1-3 days', '3-7 days', '> 7 days'] as const;

export type SortKey = 'priority' | 'oldest' | 'money' | 'deadline';
export const SORTS: { id: SortKey; label: string }[] = [
  { id: 'priority', label: 'Critical first' }, { id: 'deadline', label: 'Deadline soonest' }, { id: 'oldest', label: 'Oldest first' }, { id: 'money', label: 'Biggest £ first' }
];

export interface Filters { view: string; age: string | null; search: string; overdueOnly: boolean; blockingOnly: boolean; unownedOnly: boolean; mineOnly: boolean; sort: SortKey }
export const DEFAULT_FILTERS: Filters = { view: 'all', age: null, search: '', overdueOnly: false, blockingOnly: false, unownedOnly: false, mineOnly: false, sort: 'priority' };

function haystack(e: ExceptionRow): string {
  return [e.exc_ref, e.type_label, e.description, e.owner ?? '', ...e.order_refs, ...e.skus, ...e.po_refs, ...e.movement_refs, ...e.producers].join(' ').toLowerCase();
}

export function applyFilters(rows: ExceptionRow[], f: Filters, me: string | null): ExceptionRow[] {
  const view = VIEWS.find((v) => v.id === f.view) ?? VIEWS[0];
  const q = f.search.trim().toLowerCase();
  const out = rows.filter((e) =>
    view.match(e) &&
    (!f.age || e.age_bucket === f.age) &&
    (!f.overdueOnly || e.is_overdue) && (!f.blockingOnly || e.is_blocking) && (!f.unownedOnly || e.needs_owner) &&
    (!f.mineOnly || (!!me && e.owner?.toLowerCase() === me.toLowerCase())) &&
    (!q || q.split(/\s+/).every((w) => haystack(e).includes(w))));
  return out.sort(comparator(f.sort));
}

export function comparator(sort: SortKey): (a: ExceptionRow, b: ExceptionRow) => number {
  const tie = (a: ExceptionRow, b: ExceptionRow) => a.exc_ref.localeCompare(b.exc_ref);
  switch (sort) {
    case 'oldest': return (a, b) => b.age_hours - a.age_hours || tie(a, b);
    case 'money': return (a, b) => (b.financial_impact ?? -1) - (a.financial_impact ?? -1) || tie(a, b);
    case 'deadline': return (a, b) => Date.parse(a.response_deadline) - Date.parse(b.response_deadline) || tie(a, b);
    default: return (a, b) => a.severity_rank - b.severity_rank || Number(b.is_overdue) - Number(a.is_overdue) || Date.parse(a.response_deadline) - Date.parse(b.response_deadline) || tie(a, b);
  }
}

export function viewCounts(rows: ExceptionRow[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const v of VIEWS) out[v.id] = rows.filter(v.match).length;
  return out;
}
export function ageCounts(rows: ExceptionRow[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const b of AGE_BUCKETS) out[b] = rows.filter((e) => e.age_bucket === b).length;
  return out;
}

export interface Kpis { open: number; critical: number; high: number; overdue: number; blocking: number; unowned: number; atStake: number }
export function kpis(rows: ExceptionRow[]): Kpis {
  return {
    open: rows.length, critical: rows.filter((e) => e.severity === 'critical').length, high: rows.filter((e) => e.severity === 'high').length,
    overdue: rows.filter((e) => e.is_overdue).length, blocking: rows.filter((e) => e.is_blocking).length, unowned: rows.filter((e) => e.needs_owner).length,
    atStake: rows.reduce((t, e) => t + (e.financial_impact ?? 0), 0)
  };
}

const csvCell = (v: unknown) => { const s = v == null ? '' : Array.isArray(v) ? v.join('; ') : String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
export function toCsv(rows: ExceptionRow[]): string {
  const cols: [string, (e: ExceptionRow) => unknown][] = [
    ['Reference', (e) => e.exc_ref], ['Severity', (e) => e.severity], ['Status', (e) => e.status], ['Type', (e) => e.type_label], ['Description', (e) => e.description],
    ['Orders', (e) => e.order_refs], ['SKUs', (e) => e.skus], ['POs', (e) => e.po_refs], ['Owner', (e) => e.owner ?? ('role: ' + (e.owner_role ?? ''))], ['Deadline', (e) => e.response_deadline],
    ['Overdue', (e) => (e.is_overdue ? 'yes' : 'no')], ['Blocks', (e) => e.blocks], ['Age (hours)', (e) => e.age_hours], ['Escalation level', (e) => e.escalation_level],
    ['Financial impact', (e) => e.financial_impact], ['Customer impact', (e) => e.customer_impact], ['Recommended action', (e) => e.recommended_action]
  ];
  return [cols.map((c) => csvCell(c[0])).join(','), ...rows.map((e) => cols.map((c) => csvCell(c[1](e))).join(','))].join('\n');
}
