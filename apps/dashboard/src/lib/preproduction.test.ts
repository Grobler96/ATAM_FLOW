import { describe, expect, it } from 'vitest';
import { canCheckEmbroidery, embroideryCheckedWords, isEmbroideryChecked, artworkTotals, dtfStatusWords, fileWords, hasFile, isReady, itemsFor, lightDetail, lightScore, lightWords, lightsText, ordersWithDtf, preprodCounts, preprodFor, type DtfItemRow, type PreprodRow } from './preproduction';

const row = (o: Partial<PreprodRow> = {}): PreprodRow => ({ order_id: 'o1', order_ref: '#1', customer_name: 'A', due_date: null, order_status: 'awaiting_stock', scope: 'unclassified', total_units: 4, decoration_methods: ['dtf'], prints: 'red', prints_items: 2, prints_units: 6, prints_done: 0, embroidery: 'none', embroidery_areas: 0, embroidery_approved: 0, embroidery_stored: 0, stock: 'red', ...o });
const item = (o: Partial<DtfItemRow> = {}): DtfItemRow => ({ id: 'i1', order_id: 'o1', order_ref: '#1', customer_name: 'A', due_date: '2026-11-30T00:00:00Z', scope: 'third_party', deco_line_id: 'L1', product_name: 'Polo', area: 'Back', qty: 3, status: 'required', artwork_id: null, thumbnail_url: null, file_format: null, storage_status: null, approval_status: null, content_hash: null, updated_at: '', ...o });
const filed = (o: Partial<DtfItemRow> = {}) => item({ artwork_id: 'a1', storage_status: 'stored', file_format: 'png', content_hash: 'h1', thumbnail_url: 'https://x/t.png', ...o });

describe('lights in plain words', () => {
  it('says what each light means', () => {
    expect(lightWords('prints', 'red')).toBe('Prints required'); expect(lightWords('prints', 'amber')).toBe('Prints in progress'); expect(lightWords('prints', 'green')).toBe('Prints done');
    expect(lightWords('embroidery', 'green')).toBe('Embroidery ready'); expect(lightWords('stock', 'amber')).toBe('Stock partly allocated'); expect(lightWords('prints', 'none')).toBe('No DTF on this order');
  });
  it('explains a light with the counts, in the right grammar', () => {
    expect(lightDetail('prints', row({ prints_done: 1, prints_items: 3, prints_units: 1 }))).toBe('1 of 3 DTF placements done · 1 garment carries a DTF print.');
    expect(lightDetail('prints', row({ prints_done: 0, prints_items: 1, prints_units: 6 }))).toBe('0 of 1 DTF placement done · 6 garments carry a DTF print.');
    expect(lightDetail('prints', row({ prints: 'red', prints_items: 0 }))).toMatch(/not been read from DecoNetwork yet/); expect(lightDetail('prints', row({ prints: 'none' }))).toBe('This order has no DTF prints.');
    expect(lightDetail('embroidery', row({ embroidery: 'amber', embroidery_areas: 2, embroidery_approved: 1, embroidery_stored: 2 }))).toBe('1 of 2 embroidery areas approved · 2 stored and readable.');
    expect(lightDetail('embroidery', row({ embroidery: 'red', embroidery_areas: 0 }))).toMatch(/No embroidery artwork is recorded/); expect(lightDetail('stock', row({ stock: 'green' }))).toBe('All the stock for this order is secured or fully allocated.');
  });
  it('writes the three lights as one sentence for export and screen readers', () => {
    expect(lightsText(row({ prints: 'amber', embroidery: 'none', stock: 'green' }))).toBe('Prints: Prints in progress; Embroidery: not needed; Stock: Stock secured');
  });
});

describe('ready and counts', () => {
  it('is ready only when everything that applies is green', () => {
    expect(isReady(row({ prints: 'green', embroidery: 'none', stock: 'green' }))).toBe(true); expect(isReady(row({ prints: 'none', embroidery: 'green', stock: 'green' }))).toBe(true);
    expect(isReady(row({ prints: 'amber', embroidery: 'green', stock: 'green' }))).toBe(false); expect(isReady(row())).toBe(false);
  });
  it('counts what still needs doing', () => {
    const c = preprodCounts([row({ prints: 'green', embroidery: 'none', stock: 'green' }), row({ order_id: 'o2', prints: 'red', stock: 'amber' }), row({ order_id: 'o3', prints: 'none', embroidery: 'red', stock: 'green' })]);
    expect(c).toEqual({ total: 3, ready: 1, prints: 1, embroidery: 1, stock: 1 });
  });
  it('puts the worst orders first', () => { expect(lightScore(row({ prints: 'red', stock: 'red' }))).toBe(6); expect(lightScore(row({ prints: 'amber', stock: 'green' }))).toBe(2); expect(lightScore(row({ prints: 'none', stock: 'green' }))).toBe(0); });
  it('finds the row for one order', () => { expect(preprodFor([row({ order_id: 'a' }), row({ order_id: 'b' })], 'b')?.order_id).toBe('b'); expect(preprodFor([], 'a')).toBeNull(); expect(preprodFor([row()], undefined)).toBeNull(); });
});

describe('DTF placements', () => {
  it('knows when the real file is there', () => {
    expect(hasFile(filed())).toBe(true); expect(hasFile(item())).toBe(false); expect(hasFile(item({ artwork_id: 'a1', storage_status: 'failed' }))).toBe(false); expect(hasFile(item({ artwork_id: 'a1', storage_status: 'manual' }))).toBe(true);
    expect(fileWords(filed())).toBe('File ready (PNG)'); expect(fileWords(item())).toBe('No file yet'); expect(fileWords(item({ artwork_id: 'a1', storage_status: 'pending_download' }))).toBe('File not stored yet');
  });
  it('words for each status', () => { expect(dtfStatusWords('required')).toBe('Prints required'); expect(dtfStatusWords('in_progress')).toBe('Prints in progress'); expect(dtfStatusWords('done')).toBe('Prints done'); expect(dtfStatusWords('odd_one')).toBe('odd one'); });
  it('lists one order\'s placements in a steady order', () => { expect(itemsFor([item({ id: 'a', area: 'Back' }), item({ id: 'b', order_id: 'o2' }), item({ id: 'c', area: 'Front' })], 'o1').map((i) => i.id)).toEqual(['a', 'c']); expect(itemsFor([item()], null)).toEqual([]); });
  it('summarises an order: placements, garments, progress and missing files', () => {
    const rows = ordersWithDtf([filed({ id: '1', status: 'done', qty: 3 }), item({ id: '2', area: 'Front', qty: 2, status: 'in_progress' }), item({ id: '3', order_id: 'o2', order_ref: '#2', due_date: '2026-11-25T00:00:00Z', qty: 4 })]);
    expect(rows.map((r) => r.order_ref)).toEqual(['#2', '#1']);
    expect(rows[1]).toMatchObject({ placements: 2, units: 5, done: 1, started: 1, missingFiles: 1, status: 'in_progress' }); expect(rows[0]).toMatchObject({ status: 'required', missingFiles: 1 });
    expect(ordersWithDtf([filed({ status: 'done' })])[0].status).toBe('done');
  });
  it('totals the same design across orders, and keeps files we do not have apart', () => {
    const t = artworkTotals([filed({ id: '1', order_id: 'o1', qty: 3 }), filed({ id: '2', order_id: 'o2', order_ref: '#2', qty: 4, area: 'Chest', status: 'done' }), item({ id: '3', order_id: 'o3', order_ref: '#3', qty: 9, area: 'Back' }), item({ id: '4', order_id: 'o3', order_ref: '#3', qty: 1, area: 'Front' })]);
    expect(t).toHaveLength(3);
    const shared = t.find((x) => x.key === 'h:h1')!; expect(shared).toMatchObject({ qty: 7, orders: 2, placements: 2, outstanding: 3, hasFile: true, thumbnail_url: 'https://x/t.png' });
    const unfiled = t.filter((x) => x.key.startsWith('n:')); expect(unfiled.map((x) => x.label)).toEqual(['#3 · Back', '#3 · Front']); expect(unfiled.every((x) => !x.hasFile)).toBe(true);
    expect(t[0].qty).toBe(9);   // most still to make comes first
  });
  it('a done design has nothing outstanding', () => { expect(artworkTotals([filed({ status: 'done', qty: 5 })])[0]).toMatchObject({ qty: 5, outstanding: 0 }); });
});

describe('embroidery checked by a person', () => {
  it('knows whether an order has been checked', () => { expect(isEmbroideryChecked(row())).toBe(false); expect(isEmbroideryChecked(row({ embroidery_checked_at: '2026-11-21T10:00:00Z' }))).toBe(true); });
  it('says when, without showing who as an id', () => { expect(embroideryCheckedWords(row({ embroidery_checked_at: '2026-11-21T10:00:00Z', embroidery_checked_by: 'dashboard:3f2a' }))).toBe('Checked by a person on 21 Nov 2026.'); expect(embroideryCheckedWords(row())).toBe(''); });
  it('puts the check into the embroidery detail line', () => {
    const r = row({ embroidery: 'green', embroidery_areas: 0, embroidery_checked_at: '2026-11-21T10:00:00Z' });
    expect(lightDetail('embroidery', r)).toBe('Checked by a person on 21 Nov 2026. No embroidery artwork is recorded for this order yet.');
    expect(lightDetail('embroidery', row({ embroidery: 'red', embroidery_areas: 0 }))).toBe('No embroidery artwork is recorded for this order yet.');
  });
  it('only planners can check, and only orders that use embroidery', () => {
    expect(canCheckEmbroidery({ embroidery: 'red' }, 'production')).toBe(true); expect(canCheckEmbroidery({ embroidery: 'amber' }, 'manager')).toBe(true); expect(canCheckEmbroidery({ embroidery: 'green' }, 'admin')).toBe(true);
    expect(canCheckEmbroidery({ embroidery: 'none' }, 'admin')).toBe(false); expect(canCheckEmbroidery({ embroidery: 'red' }, 'warehouse')).toBe(false); expect(canCheckEmbroidery({ embroidery: 'red' }, 'viewer')).toBe(false); expect(canCheckEmbroidery({ embroidery: 'red' }, null)).toBe(false);
  });
});
