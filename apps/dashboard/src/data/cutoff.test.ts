import { describe, expect, it } from 'vitest';
import { cutOffAt, cutOffMessage, needsCountCheck, viewLabel } from './cutoff';

describe('cut-off lists', () => {
  it('is cut off when it reaches its limit', () => {
    expect(cutOffAt(5000, 5000, null)).toBe(5000); expect(cutOffAt(2000, 2000, null)).toBe(2000);
    expect(cutOffAt(4999, 5000, null)).toBeNull(); expect(cutOffAt(0, 5000, null)).toBeNull();
  });
  it('is cut off when the server returned fewer rows than exist', () => {
    expect(cutOffAt(1000, 5000, 1450)).toBe(1000); expect(cutOffAt(1000, 5000, 1000)).toBeNull(); expect(cutOffAt(1000, 5000, null)).toBeNull();
  });
  it('only asks for a count when a server-side cap is plausible', () => {
    expect(needsCountCheck(999, 5000)).toBe(false); expect(needsCountCheck(1000, 5000)).toBe(true); expect(needsCountCheck(3000, 5000)).toBe(true); expect(needsCountCheck(5000, 5000)).toBe(false); expect(needsCountCheck(2000, 2000)).toBe(false);
  });
  it('names a list in plain words', () => { expect(viewLabel('ui_purchase_orders')).toBe('Purchase orders'); expect(viewLabel('ui_orders')).toBe('Orders'); expect(viewLabel('plain')).toBe('Plain'); expect(viewLabel('ui_')).toBe('ui_'); });
  it('says nothing when nothing is cut off, and names each list once, biggest first', () => {
    expect(cutOffMessage([])).toBeNull();
    expect(cutOffMessage([{ view: 'ui_orders', shown: 5000 }])).toBe('A list loaded here is cut off: Orders (first 5,000 rows). Rows beyond that are not shown, so counts and totals here may be too low. Narrow the list with filters, or ask an admin.');
    const m = cutOffMessage([{ view: 'ui_stock_movements', shown: 2000 }, { view: 'ui_orders', shown: 5000 }, { view: 'ui_orders', shown: 5000 }]);
    expect(m).toContain('Some lists loaded here are cut off: Orders (first 5,000 rows), Stock movements (first 2,000 rows).');
  });
});
