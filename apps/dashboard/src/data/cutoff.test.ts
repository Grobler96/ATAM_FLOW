import { describe, expect, it } from 'vitest';
import { cutOffAt, cutOffMessage, fetchAllPages, needsCountCheck, pageRanges, pagingKey, viewLabel } from './cutoff';

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

describe('page ranges', () => {
  it('asks for every row, a page at a time, never past our limit', () => {
    expect(pageRanges(1611, 5000)).toEqual([[0, 999], [1000, 1610]]); expect(pageRanges(1000, 5000)).toEqual([[0, 999]]); expect(pageRanges(2500, 5000)).toEqual([[0, 999], [1000, 1999], [2000, 2499]]);
    expect(pageRanges(7000, 2000)).toEqual([[0, 999], [1000, 1999]]); expect(pageRanges(0, 5000)).toEqual([]);
  });
});

describe('paging key', () => {
  it('uses a column that is different on every row, in order of preference', () => {
    expect(pagingKey({ id: 1, sku: 'a' })).toBe('id'); expect(pagingKey({ sku: 'a', qty: 2 })).toBe('sku'); expect(pagingKey({ drive_file_id: 'x', name: 'n' })).toBe('drive_file_id');
    expect(pagingKey({ detail: 'x' })).toBeNull(); expect(pagingKey(null)).toBeNull();
  });
});

describe('fetching a list page by page', () => {
  const table = Array.from({ length: 1611 }, (_, i) => ({ id: i + 1 }));
  const capped = async (from: number, to: number) => table.slice(from, Math.min(to, from + 999) + 1); // a server that never returns more than 1,000 rows
  it('gets every row of a list the server would cut off', async () => {
    const all = await fetchAllPages(capped, 1611, 5000); expect(all).toHaveLength(1611); expect((all as { id: number }[])[1610].id).toBe(1611); expect(new Set((all as { id: number }[]).map((r) => r.id)).size).toBe(1611);
  });
  it('stops at our own limit, and gives up (null) when the pages do not add up', async () => {
    expect(await fetchAllPages(capped, 1611, 1200)).toHaveLength(1200);
    expect(await fetchAllPages(async () => [], 1611, 5000)).toBeNull();
  });
});
