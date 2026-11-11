import type { Tone } from '../ui/primitives';
import type { Role } from '../types';
import type { PoInvoiceRow } from '../data/types';
import { money } from './domain';

// The purchasing rules live in the database (flow_settings 'purchasing.rules'). These are the same placeholder defaults the
// database uses when a value is missing, so the screens never show less than the database enforces.
export interface PurchasingRules { approve_over_value: number; no_self_approval: boolean; invoice_tolerance_pct: number; invoice_tolerance_value: number; chase_enabled: boolean; chase_min_days_late: number; chase_repeat_days: number }
export const DEFAULT_RULES: PurchasingRules = { approve_over_value: 500, no_self_approval: true, invoice_tolerance_pct: 2, invoice_tolerance_value: 5, chase_enabled: false, chase_min_days_late: 2, chase_repeat_days: 3 };

export function rulesFrom(rows: { key: string; value: unknown }[]): PurchasingRules {
  const stored = rows.find((r) => r.key === 'purchasing.rules')?.value;
  if (!stored || typeof stored !== 'object') return DEFAULT_RULES;
  const s = stored as Record<string, unknown>;
  // the database casts these with ::numeric / ::boolean, so a number or a numeric string both count
  const num = (k: keyof PurchasingRules, d: number) => { const v = s[k]; const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN; return Number.isFinite(n) ? n : d; };
  const bool = (k: keyof PurchasingRules, d: boolean) => { const v = s[k]; return typeof v === 'boolean' ? v : v === 'true' ? true : v === 'false' ? false : d; };
  return {
    approve_over_value: num('approve_over_value', DEFAULT_RULES.approve_over_value), no_self_approval: bool('no_self_approval', DEFAULT_RULES.no_self_approval),
    invoice_tolerance_pct: num('invoice_tolerance_pct', DEFAULT_RULES.invoice_tolerance_pct), invoice_tolerance_value: num('invoice_tolerance_value', DEFAULT_RULES.invoice_tolerance_value),
    chase_enabled: bool('chase_enabled', DEFAULT_RULES.chase_enabled), chase_min_days_late: num('chase_min_days_late', DEFAULT_RULES.chase_min_days_late), chase_repeat_days: num('chase_repeat_days', DEFAULT_RULES.chase_repeat_days)
  };
}

// Mirrors flow.po_approve_checked: anything over the limit needs an admin. (Whether the person created the PO is only known
// to the database, so the dialog asks it and shows its answer rather than guessing.)
export function approvalCheck(rules: PurchasingRules, total: number | null | undefined, role: Role | null): { overLimit: boolean; blocked: boolean; message: string | null } {
  const value = total ?? 0;
  const overLimit = value > rules.approve_over_value;
  const blocked = overLimit && role !== 'admin';
  return { overLimit, blocked, message: blocked ? `This PO is worth ${money(value, 2)}. Anything over ${money(rules.approve_over_value, 2)} needs an admin to approve it.` : null };
}

// Mirrors flow.v_po_invoice_match: how far an invoice may differ from what was received (percent or pounds, whichever is larger).
export const invoiceTolerance = (rules: PurchasingRules, expectedNet: number) => Math.max(rules.invoice_tolerance_value, (expectedNet * rules.invoice_tolerance_pct) / 100);

export const MATCH: Record<string, { label: string; tone: Tone }> = {
  matched: { label: 'Matches', tone: 'good' }, over_billed: { label: 'Billed too much', tone: 'high' }, under_billed: { label: 'Billed too little', tone: 'medium' }, awaiting_goods: { label: 'Waiting for goods', tone: 'info' }
};
export const matchInfo = (status: string) => MATCH[status] ?? { label: status.replace(/_/g, ' '), tone: '' as Tone };

export const isMismatch = (i: Pick<PoInvoiceRow, 'match_status'>) => i.match_status === 'over_billed' || i.match_status === 'under_billed';
// A mismatch somebody still has to decide on (the same condition the exception detector uses).
export const needsDecision = (i: Pick<PoInvoiceRow, 'match_status' | 'resolution'>) => isMismatch(i) && !i.resolution;

export function invoiceSentence(i: PoInvoiceRow): string {
  if (i.match_status === 'awaiting_goods') return 'No goods have been booked in against this PO yet, so the invoice cannot be checked.';
  const have = `invoiced ${money(i.net_total, 2)}, expected ${money(i.expected_net, 2)} for the ${i.units_received.toLocaleString('en-GB')} units received${i.delivery_cost ? ' plus delivery' : ''}`;
  if (i.match_status === 'matched') return `Matches what was received (${have}).`;
  return `${money(Math.abs(i.variance), 2)} ${i.variance > 0 ? 'more' : 'less'} than expected (${have}).`;
}

export const RESOLUTION_LABEL: Record<string, string> = { accepted: 'Difference accepted', disputed: 'Disputed with the supplier' };

export type ResolveAction = 'accept' | 'dispute' | 'reopen';
export const RESOLVE_TEXT: Record<ResolveAction, { title: string; button: string; help: string }> = {
  accept: { title: 'Accept the difference', button: 'Accept difference', help: 'Only a manager or admin can accept an invoice that does not match. Say why it is fine to pay it as billed.' },
  dispute: { title: 'Dispute with the supplier', button: 'Mark as disputed', help: 'Use this when you are asking the supplier for a credit note or a corrected invoice. It stays flagged until it is accepted.' },
  reopen: { title: 'Reopen this invoice', button: 'Reopen', help: 'Puts it back in the list of invoices that need a decision.' }
};

export function invoiceFormError(ref: string, net: string, vat: string): string | null {
  if (!ref.trim()) return 'Enter the invoice number.';
  if (net.trim() === '' || !Number.isFinite(Number(net)) || Number(net) < 0) return 'Enter the invoice total before VAT (zero or more).';
  if (vat.trim() !== '' && (!Number.isFinite(Number(vat)) || Number(vat) < 0)) return 'VAT must be a number, or left empty.';
  return null;
}
export const reasonOk = (reason: string) => reason.trim().length >= 3;
