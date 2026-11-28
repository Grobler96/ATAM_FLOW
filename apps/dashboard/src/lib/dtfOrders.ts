import { artworkTotals, hasFile, type ArtworkTotal, type DtfItemRow } from './preproduction';

// The in-house DTF order to Super Print. DTFs are bought from Super Print: for an in-house order we order them and apply them here; for a third-party
// order the third party orders their own, so those placements never go on this order. The database decides (flow.dtf_plan); this mirrors its rules so the
// dialog can show what will and will not be ordered before anything is created. Nothing is sent: the email waits for a person's approval.
export interface DtfBatchRow {
  id: string; batch_ref: string; status: 'draft' | 'ordered' | 'received' | 'cancelled' | string; supplier_name: string; supplier_has_email: boolean; note: string | null; created_by: string | null;
  created_at: string; ordered_at: string | null; received_at: string | null; comm_ref: string | null; comm_status: string | null; comm_id?: string | null; delivery?: string | null; placements: number; prints: number; received: number
}

// How fast the prints are wanted. Next day adds one bold line to the email to Super Print (the database writes it).
export const DELIVERY_OPTIONS = [{ value: 'standard', label: 'Standard delivery' }, { value: 'next_day_pre12', label: 'Next day, before 12 (Pre 12)' }] as const;
export const deliveryWords = (d: string | null | undefined): string | null => (d === 'next_day_pre12' ? 'Next day before 12' : null);
// The email can be approved from the DTF page once it has a recipient and is waiting for a person
export const canApproveHere = (b: Pick<DtfBatchRow, 'status' | 'comm_status' | 'supplier_has_email' | 'comm_id'>): boolean => b.status === 'draft' && !!b.comm_id && b.supplier_has_email && ['pending_review', 'failed'].includes(b.comm_status ?? '');

export const SKIP_THIRD_PARTY = 'Third-party order: the decorator orders their own DTFs';
export const SKIP_ON_ORDER = 'Already on a DTF order';
export const SKIP_STARTED = 'Prints already ordered or done';
export const SKIP_NO_GARMENTS = 'No garments';
export const SKIP_NO_FILE = 'No file yet';

export function skipReason(i: DtfItemRow): string | null {
  if (i.scope === 'third_party') return SKIP_THIRD_PARTY;
  if (i.batch_id) return SKIP_ON_ORDER;
  if (i.status !== 'required') return SKIP_STARTED;
  if (!(i.qty > 0)) return SKIP_NO_GARMENTS;
  if (!hasFile(i)) return SKIP_NO_FILE;
  return null;
}

export interface BuildPlan { included: DtfItemRow[]; skipped: { reason: string; items: DtfItemRow[] }[]; designs: ArtworkTotal[]; prints: number; orders: number }
export function planBuild(items: DtfItemRow[], orderIds: string[]): BuildPlan {
  const want = new Set(orderIds); const included: DtfItemRow[] = []; const by = new Map<string, DtfItemRow[]>();
  for (const i of items) {
    if (!want.has(i.order_id)) continue;
    const why = skipReason(i);
    if (!why) included.push(i); else by.set(why, [...(by.get(why) ?? []), i]);
  }
  const order = [SKIP_NO_FILE, SKIP_THIRD_PARTY, SKIP_ON_ORDER, SKIP_STARTED, SKIP_NO_GARMENTS];
  const skipped = [...by.entries()].sort((a, b) => order.indexOf(a[0]) - order.indexOf(b[0])).map(([reason, its]) => ({ reason, items: its }));
  return { included, skipped, designs: artworkTotals(included), prints: included.reduce((n, i) => n + i.qty, 0), orders: new Set(included.map((i) => i.order_id)).size };
}
export const refsOf = (items: DtfItemRow[], max = 6): string => { const r = [...new Set(items.map((i) => i.order_ref))]; return r.slice(0, max).join(', ') + (r.length > max ? ` and ${r.length - max} more` : ''); };

// Where a DTF order has got to, in plain words.
export function batchWords(b: Pick<DtfBatchRow, 'status' | 'comm_status' | 'supplier_has_email' | 'supplier_name'>): string {
  if (b.status === 'received') return 'Received';
  if (b.status === 'cancelled') return 'Cancelled';
  if (b.status === 'ordered') return 'Ordered: waiting for the prints';
  if (!b.supplier_has_email || b.comm_status === 'draft') return `Waiting: ${b.supplier_name} has no email address yet`;
  if (b.comm_status === 'approved') return 'Approved: waiting to be sent';
  if (b.comm_status === 'failed') return 'The email failed to send';
  return 'The email is waiting for approval';
}
export const batchTone = (b: Pick<DtfBatchRow, 'status'>): 'good' | 'medium' | 'critical' | '' => (b.status === 'received' ? 'good' : b.status === 'ordered' ? 'medium' : b.status === 'cancelled' ? '' : 'critical');
// Prints on a DTF order that have not arrived yet
export const outstanding = (items: DtfItemRow[], batchId: string): DtfItemRow[] => items.filter((i) => i.batch_id === batchId && i.status !== 'done');
export const batchItems = (items: DtfItemRow[], batchId: string): DtfItemRow[] => items.filter((i) => i.batch_id === batchId).sort((a, b) => a.order_ref.localeCompare(b.order_ref) || a.area.localeCompare(b.area));
export const canBuildRole = (role: string | null | undefined): boolean => role === 'admin' || role === 'manager' || role === 'production';
export const canReceiveRole = (role: string | null | undefined): boolean => canBuildRole(role) || role === 'warehouse';
