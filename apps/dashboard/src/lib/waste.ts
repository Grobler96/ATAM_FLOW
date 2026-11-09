import { opsAction } from './orderChanges';

export interface WasteRow {
  id: string; waste_ref: string; occurred_at: string; stage: string; cause_code: string; cause_label: string; party: string; qty: number; sku: string | null; product_name: string | null;
  unit_cost: number; value: number; recovered_value: number; net_loss: number; no_cost: boolean; order_ref: string | null; producer_id: string | null; producer_name: string | null;
  machine_name: string | null; operator_name: string | null; source: string; status: 'suggested' | 'pending_approval' | 'approved' | 'rejected'; reason: string;
  recorded_by: string | null; approved_by: string | null; decided_at: string | null; decision_note: string | null; replacement_requested: boolean; claim_ref: string | null; recovery_note: string | null; created_at: string;
}
export interface WasteRate { producer_id: string; code: string; name: string; units_sent: number; waste_units: number; waste_value: number; recovered: number; rate_pct: number | null; target_pct: number; over_target: boolean }
export interface WasteCause { code: string; label: string; default_party: string }

export const STAGES: [string, string][] = [['warehouse', 'Warehouse'], ['in_house', 'In-house production'], ['decorator', 'At a decorator'], ['qc', 'Quality check'], ['courier', 'Courier']];
export const PARTIES: [string, string][] = [['us', 'Us'], ['decorator', 'Decorator'], ['supplier', 'Supplier'], ['courier', 'Courier'], ['artwork', 'Artwork'], ['customer', 'Customer']];
export const label = (list: [string, string][], k: string) => list.find(([id]) => id === k)?.[1] ?? k;
export const STATUS_LABEL: Record<WasteRow['status'], string> = { suggested: 'Suggested', pending_approval: 'Needs approval', approved: 'Approved', rejected: 'Rejected' };
export const SOURCE_LABEL: Record<string, string> = { manual: 'Entered by hand', qc: 'Quality scrap', receipt: 'Damaged at check-in', courier: 'Courier claim' };

export const wasteAction = (action: string, params: Record<string, unknown>) => opsAction(action, params);

export interface Bucket { key: string; units: number; value: number; recovered: number; records: number }
// Approved waste only, grouped by any field. Biggest value first.
export function groupWaste(rows: WasteRow[], by: (r: WasteRow) => string): Bucket[] {
  const m = new Map<string, Bucket>();
  for (const r of rows) {
    if (r.status !== 'approved') continue;
    const k = by(r) || 'Not recorded'; const b = m.get(k) ?? { key: k, units: 0, value: 0, recovered: 0, records: 0 };
    b.units += r.qty; b.value += Number(r.value); b.recovered += Number(r.recovered_value); b.records += 1; m.set(k, b);
  }
  return [...m.values()].sort((a, b) => b.value - a.value);
}
// Monday of the week, as yyyy-mm-dd.
export function weekStart(iso: string): string {
  const d = new Date(iso); const day = (d.getUTCDay() + 6) % 7; d.setUTCDate(d.getUTCDate() - day); return d.toISOString().slice(0, 10);
}
export function weekly(rows: WasteRow[], weeks = 8, now = Date.now()): Bucket[] {
  const out: Bucket[] = []; const g = new Map(groupWaste(rows, (r) => weekStart(r.occurred_at)).map((b) => [b.key, b]));
  for (let i = weeks - 1; i >= 0; i--) { const k = weekStart(new Date(now - i * 7 * 86400000).toISOString()); out.push(g.get(k) ?? { key: k, units: 0, value: 0, recovered: 0, records: 0 }); }
  return out;
}
