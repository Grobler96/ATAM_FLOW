import { describe, expect, it } from 'vitest';
import { DEFAULT_RULES, approvalCheck, invoiceFormError, invoiceSentence, invoiceTolerance, isMismatch, matchInfo, needsDecision, reasonOk, rulesFrom } from './purchasing';
import type { PoInvoiceRow } from '../data/types';

const inv = (o: Partial<PoInvoiceRow>): PoInvoiceRow => ({ id: 'i1', po_id: 'p1', po_ref: 'AF-PO-1001', supplier: 'Ralawise', invoice_ref: 'INV-9', invoice_date: '2026-11-09', net_total: 100, vat_total: 20, note: null, resolution: null, resolution_reason: null, resolved_by: null, resolved_at: null, created_by: 'dashboard:u1', created_at: '2026-11-09T10:00:00Z',
  ordered_value: 120, received_value: 100, delivery_cost: 0, expected_net: 100, units_ordered: 24, units_received: 20, variance: 0, match_status: 'matched', ...o });

describe('purchasing rules', () => {
  it('uses the database defaults when nothing is stored', () => {
    expect(rulesFrom([])).toEqual(DEFAULT_RULES);
    expect(rulesFrom([{ key: 'purchasing.rules', value: null }])).toEqual(DEFAULT_RULES);
    expect(rulesFrom([{ key: 'other', value: { approve_over_value: 1 } }])).toEqual(DEFAULT_RULES);
  });
  it('merges stored values over the defaults, accepting numeric strings like the database does', () => {
    const r = rulesFrom([{ key: 'purchasing.rules', value: { approve_over_value: '750', chase_enabled: true, invoice_tolerance_pct: 'nonsense' } }]);
    expect(r.approve_over_value).toBe(750); expect(r.chase_enabled).toBe(true); expect(r.invoice_tolerance_pct).toBe(DEFAULT_RULES.invoice_tolerance_pct); expect(r.no_self_approval).toBe(true);
  });
});

describe('approval check', () => {
  it('lets a manager approve up to the limit but not over it', () => {
    expect(approvalCheck(DEFAULT_RULES, 500, 'manager').blocked).toBe(false);
    const over = approvalCheck(DEFAULT_RULES, 500.01, 'manager');
    expect(over.overLimit).toBe(true); expect(over.blocked).toBe(true); expect(over.message).toContain('needs an admin');
  });
  it('lets an admin approve any value', () => {
    const a = approvalCheck(DEFAULT_RULES, 9000, 'admin');
    expect(a.overLimit).toBe(true); expect(a.blocked).toBe(false); expect(a.message).toBeNull();
  });
  it('treats a PO with no total as nothing to approve over', () => { expect(approvalCheck(DEFAULT_RULES, null, 'manager').blocked).toBe(false); });
});

describe('invoice matching', () => {
  it('uses whichever is larger: the pound tolerance or the percentage', () => {
    expect(invoiceTolerance(DEFAULT_RULES, 100)).toBe(5);
    expect(invoiceTolerance(DEFAULT_RULES, 1000)).toBe(20);
  });
  it('only asks for a decision on an unresolved mismatch', () => {
    expect(needsDecision(inv({ match_status: 'over_billed', variance: 30 }))).toBe(true);
    expect(needsDecision(inv({ match_status: 'under_billed', variance: -30 }))).toBe(true);
    expect(needsDecision(inv({ match_status: 'over_billed', variance: 30, resolution: 'disputed' }))).toBe(false);
    expect(needsDecision(inv({ match_status: 'matched' }))).toBe(false);
    expect(needsDecision(inv({ match_status: 'awaiting_goods' }))).toBe(false);
    expect(isMismatch(inv({ match_status: 'matched' }))).toBe(false);
  });
  it('explains each result in plain words', () => {
    expect(invoiceSentence(inv({}))).toBe('Matches what was received (invoiced £100.00, expected £100.00 for the 20 units received).');
    expect(invoiceSentence(inv({ net_total: 130, variance: 30, match_status: 'over_billed', delivery_cost: 6 }))).toBe('£30.00 more than expected (invoiced £130.00, expected £100.00 for the 20 units received plus delivery).');
    expect(invoiceSentence(inv({ net_total: 70, variance: -30, match_status: 'under_billed' }))).toContain('£30.00 less than expected');
    expect(invoiceSentence(inv({ match_status: 'awaiting_goods', units_received: 0 }))).toContain('cannot be checked');
  });
  it('labels every status and survives one it has not heard of', () => {
    expect(matchInfo('matched').label).toBe('Matches'); expect(matchInfo('over_billed').tone).toBe('high'); expect(matchInfo('new_status').label).toBe('new status');
  });
  it('checks the record-invoice form', () => {
    expect(invoiceFormError('', '10', '')).toBe('Enter the invoice number.');
    expect(invoiceFormError('A1', '', '')).toContain('invoice total');
    expect(invoiceFormError('A1', '-1', '')).toContain('invoice total');
    expect(invoiceFormError('A1', 'abc', '')).toContain('invoice total');
    expect(invoiceFormError('A1', '10', 'x')).toContain('VAT');
    expect(invoiceFormError('A1', '0', '')).toBeNull();
    expect(invoiceFormError(' A1 ', '10.5', '2.1')).toBeNull();
  });
  it('wants a real reason (three characters, like the database)', () => { expect(reasonOk('  ')).toBe(false); expect(reasonOk('ok')).toBe(false); expect(reasonOk('ok!')).toBe(true); });
});
