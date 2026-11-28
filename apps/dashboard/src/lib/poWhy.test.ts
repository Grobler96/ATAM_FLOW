import { describe, expect, it } from 'vitest';
import { incomingPos, poLabel, whyNothingToBuy } from './poWhy';

const line = (o: Partial<Parameters<typeof whyNothingToBuy>[0][number]> = {}) => ({ sku: 'GD001BLACL', colour: 'Black', size: 'Large', qty_required: 1, qty_produced: 0, qty_allocated_on_hand: 0, qty_allocated_incoming: 0, ...o });
const po = (o: Partial<Parameters<typeof poLabel>[0]> = {}) => ({ po_id: 'p1', po_ref: '877092', origin: 'deconetwork', supplier: 'Ralawise', expected_date: '2026-12-01T00:00:00Z', delivery_status: 'expected', ...o });
const pl = (o = {}) => ({ po_id: 'p1', sku: 'GD001BLACL', qty_outstanding: 1, ...o });

describe('whyNothingToBuy', () => {
  it('names the DecoNetwork purchase order an item is reserved from', () => {
    expect(whyNothingToBuy([line({ qty_allocated_incoming: 1 })], [pl()], [po()])).toEqual(['1 × GD001BLACL (Black, Large): 1 reserved from purchase order 877092 (raised in DecoNetwork) from Ralawise, due 1 Dec.']);
  });
  it('says so when the stock is on the shelf', () => { expect(whyNothingToBuy([line({ qty_required: 3, qty_allocated_on_hand: 3 })], [], [])).toEqual(['3 × GD001BLACL (Black, Large): 3 reserved from the stock on the shelf.']); });
  it('can combine shelf and incoming, and an Atam Flow PO has no DecoNetwork note', () => {
    expect(whyNothingToBuy([line({ qty_required: 4, qty_allocated_on_hand: 1, qty_allocated_incoming: 3 })], [pl({ qty_outstanding: 3 })], [po({ origin: 'atam_flow', po_ref: 'AF-PO-1003' })])).toEqual(['4 × GD001BLACL (Black, Large): 1 reserved from the stock on the shelf and 3 reserved from purchase order AF-PO-1003 from Ralawise, due 1 Dec.']);
  });
  it('still explains when the purchase order cannot be found, and says already made when produced', () => {
    expect(whyNothingToBuy([line({ qty_allocated_incoming: 1 })], [], [])[0]).toMatch(/reserved from a purchase order that is already on its way/);
    expect(whyNothingToBuy([line({ qty_produced: 1 })], [], [])).toEqual(['1 × GD001BLACL (Black, Large): already made.']);
    expect(whyNothingToBuy([line()], [], [])[0]).toMatch(/already covered/);
  });
});
describe('incomingPos', () => {
  it('lists open purchase orders with units outstanding for the item, soonest first, and skips finished ones', () => {
    const pos = [po({ po_id: 'a', po_ref: 'A', expected_date: '2026-12-09T00:00:00Z' }), po({ po_id: 'b', po_ref: 'B', expected_date: '2026-12-02T00:00:00Z' }), po({ po_id: 'c', po_ref: 'C', delivery_status: 'received' })];
    const lines = [pl({ po_id: 'a' }), pl({ po_id: 'b' }), pl({ po_id: 'c' }), pl({ po_id: 'a', sku: 'OTHER' }), pl({ po_id: 'b', qty_outstanding: 0 })];
    expect(incomingPos('GD001BLACL', lines, pos).map((p) => p.po_ref)).toEqual(['B', 'A']); expect(incomingPos(null, lines, pos)).toEqual([]);
  });
});
