import type { Tone } from '../ui/primitives';

// The holding pen: orders with something wrong in their data are held back until it is fixed in DecoNetwork. The database decides
// who is in the pen (flow.pen_refresh); these are the read models and the plain words for the screen.
export interface PenDefect { code: string; severity: 'critical' | 'high' | 'medium' | 'low' | string; detail: string | null }
export interface PenWaiver { defect: string; reason: string; by: string; at: string }
export interface PenRow {
  case_key: string; order_id: string | null; order_ref: string; deco_order_id: string; customer_name: string | null; due_date: string | null; units: number | null; order_value: number | null; source_status: number | null;
  ship_address: string | null; shipping_method: string | null; defects: PenDefect[]; problem_count: number; severity_rank: number | null; codes: string | null; in_flow: boolean; first_seen_at: string; age_hours: number;
  owner: string | null; note: string | null; note_by: string | null; note_at: string | null; is_overdue: boolean; waived: PenWaiver[]
}
export interface PenLogRow { id: number; at: string; case_key: string; order_ref: string; kind: 'entered' | 'released' | 'assigned' | 'waived' | 'unwaived' | 'changed' | string; actor: string | null; detail: string | null }

// Same wording as flow.pen_defect_label in the database.
export const DEFECT_LABEL: Record<string, string> = {
  no_address: 'No delivery address', no_due_date: 'No due date', no_shipping_method: 'No shipping method', no_lines: 'No order lines or units', no_decoration: 'Decoration process not recognised',
  artwork: 'Artwork not ready', unknown_status: 'Unknown DecoNetwork status', not_synced: 'Not in ATAM_FLOW yet'
};
export const defectLabel = (code: string) => DEFECT_LABEL[code] ?? code.replace(/_/g, ' ');

// Where each problem is normally put right. The order leaves the pen by itself after the next sync.
export const DEFECT_FIX: Record<string, string> = {
  no_address: 'Add the delivery address on the order in DecoNetwork.', no_due_date: 'Set a due date on the order in DecoNetwork.', no_shipping_method: 'Choose a shipping method on the order in DecoNetwork.',
  no_lines: 'Check the order in DecoNetwork: it has no lines, or no units on its lines.', no_decoration: 'Fix the decoration process on the order lines in DecoNetwork.',
  artwork: 'Get the artwork ready: see the Artwork page.', unknown_status: 'DecoNetwork has a status ATAM_FLOW does not know yet. Tell an admin.', not_synced: 'It appears in ATAM_FLOW after the next order sync.'
};
export const defectFix = (code: string) => DEFECT_FIX[code] ?? 'Check the order in DecoNetwork.';

export const severityTone = (s: string): Tone => (s === 'critical' ? 'critical' : s === 'high' ? 'high' : s === 'medium' ? 'medium' : 'low');

export const LOG_LABEL: Record<string, string> = { entered: 'Went into the pen', released: 'Left the pen', assigned: 'Owner or note changed', waived: 'Problem waived', unwaived: 'Waiver removed', changed: 'Problems changed' };
export const logLabel = (kind: string) => LOG_LABEL[kind] ?? kind.replace(/_/g, ' ');

export function penCounts(rows: PenRow[]) { return { total: rows.length, overdue: rows.filter((r) => r.is_overdue).length, notInFlow: rows.filter((r) => !r.in_flow).length, critical: rows.filter((r) => (r.severity_rank ?? 0) >= 4).length }; }

export function waitText(hours: number): string {
  if (!Number.isFinite(hours) || hours < 0) return '—';
  if (hours < 1) return 'under an hour';
  if (hours < 48) return `${Math.round(hours)} h`;
  return `${Math.round(hours / 24)} d`;
}

// Worst problem first, so the chips on a row lead with what matters.
const rank = (s: string) => (s === 'critical' ? 4 : s === 'high' ? 3 : s === 'medium' ? 2 : 1);
export const sortedDefects = (r: Pick<PenRow, 'defects'>): PenDefect[] => [...(r.defects ?? [])].sort((a, b) => rank(b.severity) - rank(a.severity));
export const logFor = (log: PenLogRow[], caseKey: string): PenLogRow[] => log.filter((l) => l.case_key === caseKey).sort((a, b) => b.at.localeCompare(a.at) || b.id - a.id);
export const recentLog = (log: PenLogRow[], n = 12): PenLogRow[] => [...log].sort((a, b) => b.at.localeCompare(a.at) || b.id - a.id).slice(0, n);
export const penCaseFor = (rows: PenRow[], orderId: string | null | undefined): PenRow | null => (orderId ? rows.find((r) => r.order_id === orderId) ?? null : null);
