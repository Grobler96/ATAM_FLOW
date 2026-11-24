import { describe, expect, it } from 'vitest';
import type { OrderLineRow } from '../data/types';
import type { QueueRow } from './dispatch';
import type { ArtworkFileRow } from './proofs';
import { buildWorksheet, worksheetHtml } from './worksheet';

const order = { order_ref: '#636924', customer_name: 'CPI Corporate Solutions', due_date: '2026-12-04T12:45:00Z' };
const ln = (o: Partial<OrderLineRow>): OrderLineRow => ({ id: 'l' + Math.random(), order_id: 'o1', sku: 'SKU', product_name: 'Vintage loose tee', colour: 'Magnet', size: 'Medium', qty_required: 1, qty_produced: 0, qty_shipped: 0, decoration_methods: [], decoration_placement: null, stitches_per_piece: null, qty_allocated_on_hand: 0, qty_allocated_incoming: 0, qty_shortage: 0, deco_line_id: '3739277986', ...o });
const art = (o: Partial<ArtworkFileRow>): ArtworkFileRow => ({ id: 'a' + Math.random(), order_id: 'o1', order_ref: '#636924', customer_name: null, due_date: null, deco_line_id: '3739277986', area: 'Back', process: 'dtf', version: 1, is_current: true, source: 'deconetwork', approval_status: 'pending', storage_status: 'stored', storage_path: 'p', file_format: 'png', stitch_count: null, width_mm: null, height_mm: null, placement: null, readable: null, has_deconetwork_proof: false, proof_url: null, thumbnail_url: null, note: null, created_by: null, created_at: '', stored_at: null, ...o });
const dq = { customer_po: 'PO-9', shipping_method: 'Tracked Courier Delivery', ship_to: 'Daniel Spooner\nCPI\nLeeds\nLS25 6PD', is_collection: false } as unknown as QueueRow;

describe('buildWorksheet', () => {
  it('groups the sizes of one garment under its item number, in size order, with a total', () => {
    const w = buildWorksheet(order, dq, [ln({ size: 'Large', qty_required: 3 }), ln({ size: 'Small', qty_required: 2 }), ln({ size: 'Medium', qty_required: 1 }), ln({ size: 'Medium', qty_required: 4 }), ln({ deco_line_id: '999', product_name: 'Hoodie', size: 'XL' })], []);
    expect(w.garments.map((g) => g.key)).toEqual(['3739277986', '999']);
    expect(w.garments[0].sizes).toEqual([{ size: 'Small', qty: 2 }, { size: 'Medium', qty: 5 }, { size: 'Large', qty: 3 }]); expect(w.garments[0].total).toBe(10); expect(w.units).toBe(11);
  });
  it('puts each current design on its garment and the rest on the order, ignoring old versions', () => {
    const w = buildWorksheet(order, dq, [ln({})], [art({ area: 'Left chest', process: 'embroidery', file_format: 'dst', stitch_count: 1258, width_mm: 50.5, height_mm: 11.4, placement: 'Left chest' }), art({ area: 'Back' }), art({ is_current: false, area: 'Old' }), art({ deco_line_id: null, area: 'Whole order' })]);
    expect(w.garments[0].designs.map((d) => d.area)).toEqual(['Back', 'Left chest']); expect(w.orderDesigns.map((d) => d.area)).toEqual(['Whole order']);
    const e = w.garments[0].designs[1]; expect(e.size).toBe('5.05 x 1.14 cm'); expect(e.stitches).toBe(1258); expect(e.format).toBe('DST');
  });
  it('says what is missing instead of guessing it', () => {
    const w = buildWorksheet(order, dq, [ln({})], [art({ area: 'Left chest', process: 'embroidery' }), art({ area: 'Back' })]);
    const t = w.gaps.join(' | '); expect(t).toMatch(/2 of 2 designs have no size/); expect(t).toMatch(/no position/); expect(t).toMatch(/no stitch count/); expect(t).toMatch(/no picture/); expect(t).toMatch(/Garment pictures/);
    expect(buildWorksheet(order, dq, [ln({})], []).gaps[0]).toMatch(/No designs are held/);
  });
  it('keeps the delivery details, or says a customer collects', () => {
    expect(buildWorksheet(order, dq, [ln({})], []).address).toEqual(['Daniel Spooner', 'CPI', 'Leeds', 'LS25 6PD']);
    expect(buildWorksheet(order, { ...dq, is_collection: true } as QueueRow, [ln({})], []).collection).toBe(true);
    expect(buildWorksheet(order, null, [ln({})], []).address).toEqual([]);
  });
});
describe('worksheetHtml', () => {
  it('prints the order, the item number, the sizes and the designs, and escapes what it is given', () => {
    const w = buildWorksheet({ ...order, customer_name: '<b>Evil</b> & Co' }, dq, [ln({})], [art({ area: 'Back', thumbnail_url: 'javascript:alert(1)' }), art({ area: 'Chest', thumbnail_url: 'https://example.test/a.png' })]);
    const h = worksheetHtml(w, new Date('2026-11-24T10:00:00Z'));
    expect(h).toContain('PRODUCTION ORDER #: 636924'); expect(h).toContain('ITEM: 3739277986'); expect(h).toContain('Tracked Courier Delivery'); expect(h).toContain('04 Dec 2026'); expect(h).toContain('LS25 6PD');
    expect(h).toContain('&lt;b&gt;Evil&lt;/b&gt; &amp; Co'); expect(h).not.toContain('<b>Evil</b>'); expect(h).toContain('https://example.test/a.png'); expect(h).not.toContain('javascript:alert'); expect(h).toContain('Not held in Flow');
  });
  it('credits no one but the system', () => { expect(worksheetHtml(buildWorksheet(order, dq, [ln({})], [])).toLowerCase()).not.toMatch(new RegExp(['cla', 'ude'].join('') + '|' + ['anthro', 'pic'].join(''))); });
});
