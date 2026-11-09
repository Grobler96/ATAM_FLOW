import { describe, expect, it } from 'vitest';
import { groupWaste, weekStart, weekly, type WasteRow } from './waste';

const row = (o: Partial<WasteRow>): WasteRow => ({ id: 'x', waste_ref: 'W', occurred_at: '2026-11-04T10:00:00Z', stage: 'warehouse', cause_code: 'stain_or_mark', cause_label: 'Stain', party: 'us', qty: 1, sku: null, product_name: null, unit_cost: 5, value: 5, recovered_value: 0, net_loss: 5, no_cost: false, order_ref: null, producer_id: null, producer_name: null, machine_name: null, operator_name: null, source: 'manual', status: 'approved', reason: 'r', recorded_by: null, approved_by: null, decided_at: null, decision_note: null, replacement_requested: false, claim_ref: null, recovery_note: null, created_at: '2026-11-04T10:00:00Z', ...o });

describe('waste grouping', () => {
  it('counts approved records only and puts the biggest cost first', () => {
    const g = groupWaste([row({ cause_label: 'A', qty: 2, value: 10 }), row({ cause_label: 'B', qty: 1, value: 50 }), row({ cause_label: 'B', status: 'pending_approval', value: 999 }), row({ cause_label: 'A', status: 'rejected', value: 999 })], (r) => r.cause_label);
    expect(g.map((b) => [b.key, b.units, b.value])).toEqual([['B', 1, 50], ['A', 2, 10]]);
  });
  it('finds the Monday of a week', () => { expect(weekStart('2026-11-08T12:00:00Z')).toBe('2026-11-02'); expect(weekStart('2026-11-02T00:10:00Z')).toBe('2026-11-02'); });
  it('fills weeks with no waste', () => {
    const w = weekly([row({ occurred_at: '2026-11-04T10:00:00Z', value: 20, qty: 4 })], 3, Date.parse('2026-11-08T12:00:00Z'));
    expect(w.map((b) => b.key)).toEqual(['2026-10-19', '2026-10-26', '2026-11-02']); expect(w.map((b) => b.value)).toEqual([0, 0, 20]);
  });
});
