import { describe, expect, it } from 'vitest';
import { applyFilters, ageCounts, DEFAULT_FILTERS, kpis, toCsv, viewCounts } from './filters';
import { ageText, deadlineText, gbp, relativeTime } from './format';
import type { ExceptionRow } from '../types';

const row = (o: Partial<ExceptionRow>): ExceptionRow => ({
  id: o.exc_ref ?? 'x', exc_ref: 'EXC-1', type_code: 'stock_shortage', type_label: 'Stock shortage', category: 'stock', severity: 'medium', severity_rank: 3, status: 'open', blocks: [], is_blocking: false,
  description: 'desc', detected_by: 'automation', detected_at: '2026-11-04T10:00:00Z', owner: null, owner_role: 'manager', needs_owner: true, response_deadline: '2026-11-05T10:00:00Z', is_overdue: false,
  age_hours: 5, age_bucket: '< 1 day', escalation_level: 0, customer_impact: null, financial_impact: null, financial_breakdown: null, recommended_action: null, root_cause: null,
  order_refs: [], skus: [], po_refs: [], movement_refs: [], producers: [], communications: 0, ...o
});

const data = [
  row({ exc_ref: 'EXC-1', severity: 'medium', severity_rank: 3, financial_impact: 100, skus: ['POLO-NVY-M'] }),
  row({ exc_ref: 'EXC-2', severity: 'critical', severity_rank: 1, type_code: 'order_at_risk', category: 'production', is_overdue: true, order_refs: ['#636220'], financial_impact: 2500, owner: 'sam@atam.test', needs_owner: false }),
  row({ exc_ref: 'EXC-3', severity: 'high', severity_rank: 2, type_code: 'artwork_blocked', category: 'artwork', is_blocking: true, blocks: ['completion'], age_hours: 80, age_bucket: '3-7 days' }),
  row({ exc_ref: 'EXC-4', severity: 'critical', severity_rank: 1, type_code: 'producer_no_receipt', category: 'producer', response_deadline: '2026-11-04T12:00:00Z', financial_impact: 1180 })
];

describe('filters', () => {
  it('sorts critical first, overdue before not, then by deadline', () => {
    expect(applyFilters(data, DEFAULT_FILTERS, null).map((e) => e.exc_ref)).toEqual(['EXC-2', 'EXC-4', 'EXC-3', 'EXC-1']);
  });
  it('named views pick the right rows', () => {
    expect(applyFilters(data, { ...DEFAULT_FILTERS, view: 'orders' }, null).map((e) => e.exc_ref)).toEqual(['EXC-2']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, view: 'producers' }, null).map((e) => e.exc_ref)).toEqual(['EXC-4']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, view: 'artwork' }, null).map((e) => e.exc_ref)).toEqual(['EXC-3']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, view: 'machines' }, null)).toEqual([]);
  });
  it('toggles and search combine', () => {
    expect(applyFilters(data, { ...DEFAULT_FILTERS, overdueOnly: true }, null).map((e) => e.exc_ref)).toEqual(['EXC-2']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, blockingOnly: true }, null).map((e) => e.exc_ref)).toEqual(['EXC-3']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, unownedOnly: true }, null)).toHaveLength(3);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, mineOnly: true }, 'SAM@atam.test').map((e) => e.exc_ref)).toEqual(['EXC-2']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, search: 'polo nvy' }, null).map((e) => e.exc_ref)).toEqual(['EXC-1']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, search: '636220' }, null).map((e) => e.exc_ref)).toEqual(['EXC-2']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, age: '3-7 days' }, null).map((e) => e.exc_ref)).toEqual(['EXC-3']);
  });
  it('sorts by money and by age', () => {
    expect(applyFilters(data, { ...DEFAULT_FILTERS, sort: 'money' }, null).map((e) => e.exc_ref)).toEqual(['EXC-2', 'EXC-4', 'EXC-1', 'EXC-3']);
    expect(applyFilters(data, { ...DEFAULT_FILTERS, sort: 'oldest' }, null)[0].exc_ref).toBe('EXC-3');
  });
  it('counts and KPIs', () => {
    const c = viewCounts(data);
    expect(c.all).toBe(4); expect(c.critical).toBe(2); expect(c.machines).toBe(0);
    expect(ageCounts(data)['3-7 days']).toBe(1);
    expect(kpis(data)).toEqual({ open: 4, critical: 2, high: 1, overdue: 1, blocking: 1, unowned: 3, atStake: 3780 });
  });
  it('csv escapes commas, quotes and lists', () => {
    const csv = toCsv([row({ exc_ref: 'EXC-9', description: 'He said "hi", twice', order_refs: ['#1', '#2'] })]);
    const lines = csv.split('\n');
    expect(lines[0].startsWith('Reference,Severity')).toBe(true);
    expect(lines[1]).toContain('"He said ""hi"", twice"');
    expect(lines[1]).toContain('#1; #2');
  });
});

describe('format', () => {
  const now = Date.parse('2026-11-04T12:00:00Z');
  it('money', () => { expect(gbp(1180)).toBe('£1,180'); expect(gbp(null)).toBe('—'); expect(gbp(-50)).toBe('-£50'); });
  it('relative time', () => {
    expect(relativeTime('2026-11-04T14:00:00Z', now)).toBe('in 2 h');
    expect(relativeTime('2026-11-04T11:30:00Z', now)).toBe('30 min ago');
    expect(relativeTime('2026-11-01T12:00:00Z', now)).toBe('3 days ago');
    expect(deadlineText('2026-11-04T09:00:00Z', true, now)).toBe('Overdue by 3 h');
    expect(deadlineText('2026-11-05T12:00:00Z', false, now)).toBe('Respond in 24 h');
  });
  it('age', () => { expect(ageText(0.2)).toBe('just now'); expect(ageText(30)).toBe('30 h old'); expect(ageText(100)).toBe('4 days old'); });
});
