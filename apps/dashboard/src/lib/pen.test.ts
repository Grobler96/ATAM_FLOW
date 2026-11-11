import { describe, expect, it } from 'vitest';
import { defectFix, defectLabel, logFor, logLabel, penCaseFor, penCounts, recentLog, severityTone, sortedDefects, waitText, type PenLogRow, type PenRow } from './pen';

const row = (o: Partial<PenRow>): PenRow => ({ case_key: 'o:1', order_id: '1', order_ref: '#700101', deco_order_id: '700101', customer_name: 'Acme', due_date: '2026-11-12T00:00:00Z', units: 10, order_value: 200, source_status: 1, ship_address: null, shipping_method: null,
  defects: [], problem_count: 0, severity_rank: 1, codes: null, in_flow: true, first_seen_at: '2026-11-09T09:00:00Z', age_hours: 5, owner: null, note: null, note_by: null, note_at: null, is_overdue: false, waived: [], ...o });
const ev = (o: Partial<PenLogRow>): PenLogRow => ({ id: 1, at: '2026-11-09T09:00:00Z', case_key: 'o:1', order_ref: '#700101', kind: 'entered', actor: null, detail: null, ...o });

describe('holding pen words', () => {
  it('uses the database wording for every problem and survives a new one', () => {
    expect(defectLabel('no_address')).toBe('No delivery address'); expect(defectLabel('not_synced')).toBe('Not in ATAM_FLOW yet'); expect(defectLabel('brand_new_problem')).toBe('brand new problem');
    expect(defectFix('no_due_date')).toContain('due date'); expect(defectFix('brand_new_problem')).toBe('Check the order in DecoNetwork.');
  });
  it('colours by severity', () => { expect(severityTone('critical')).toBe('critical'); expect(severityTone('high')).toBe('high'); expect(severityTone('medium')).toBe('medium'); expect(severityTone('anything else')).toBe('low'); });
  it('labels what happened', () => { expect(logLabel('released')).toBe('Left the pen'); expect(logLabel('some_new_kind')).toBe('some new kind'); });
  it('says how long an order has waited', () => { expect(waitText(0.2)).toBe('under an hour'); expect(waitText(5.4)).toBe('5 h'); expect(waitText(47)).toBe('47 h'); expect(waitText(72)).toBe('3 d'); expect(waitText(-1)).toBe('—'); expect(waitText(NaN)).toBe('—'); });
});

describe('holding pen data', () => {
  it('counts what needs looking at', () => {
    const c = penCounts([row({}), row({ case_key: 's:2', in_flow: false, is_overdue: true, severity_rank: 4 }), row({ case_key: 'o:3', is_overdue: true })]);
    expect(c).toEqual({ total: 3, overdue: 2, notInFlow: 1, critical: 1 });
    expect(penCounts([])).toEqual({ total: 0, overdue: 0, notInFlow: 0, critical: 0 });
  });
  it('puts the worst problem first without changing the data', () => {
    const r = row({ defects: [{ code: 'no_due_date', severity: 'medium', detail: null }, { code: 'no_address', severity: 'critical', detail: null }, { code: 'artwork', severity: 'low', detail: null }] });
    expect(sortedDefects(r).map((d) => d.code)).toEqual(['no_address', 'no_due_date', 'artwork']); expect(r.defects[0].code).toBe('no_due_date');
  });
  it('finds a case by order and history by case, newest first', () => {
    expect(penCaseFor([row({}), row({ case_key: 'o:2', order_id: '2' })], '2')?.case_key).toBe('o:2'); expect(penCaseFor([row({})], null)).toBeNull(); expect(penCaseFor([row({})], 'nope')).toBeNull();
    const log = [ev({ id: 1, at: '2026-11-09T09:00:00Z' }), ev({ id: 2, at: '2026-11-09T10:00:00Z', kind: 'released' }), ev({ id: 3, case_key: 'o:9' })];
    expect(logFor(log, 'o:1').map((l) => l.id)).toEqual([2, 1]); expect(recentLog(log, 2).map((l) => l.id)).toEqual([2, 3]);
  });
});
