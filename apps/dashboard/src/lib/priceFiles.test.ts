import { describe, expect, it } from 'vitest';
import { matchInternal, parseOrn, parsePenCarrie, parsePriceFile, parseRalawise, type FileRow, type Grid } from './priceFiles';

const ralHead: Grid = [
  [null, null, null], [null, 'Current Date', 'Future Date'], [null, 'Product Details', null, null, null, null, null, 'Current Prices', null, null, 'Future Prices'],
  [null, 'Brand', null, null, null, 'Product', 'Description', 'CTN', 'PCK', 'SIN', 'CTN', 'PCK', 'SIN'],
];
const ral = (...rows: Grid): Grid => [...ralHead, ...rows];
const rrow = (code: string, desc: string, now: number, future: number): Grid[number] => [null, 'B&C', null, null, null, code, desc, now, now, now, future, future, future];

describe('parseRalawise', () => {
  const known = new Set(['GD001PIST3XL', 'JH501NFNAXL', 'NOPRICE1', 'ABSENT1']);
  it('keeps only known items and uses the future carton price and the description', () => {
    const r = parseRalawise(ral(rrow('GD001PIST3XL', '  3XL  PISTACHIO GD001 SOFTSTYLE  ', 2.5, 2.68), rrow('JH501NFNAXL', 'XL FRENCH NAVY JH501', 7, 7.73), rrow('ZZ999BLACL', 'unknown to Flow', 1, 1)), 'Ralawise', known);
    expect(r.problems).toEqual([]);
    expect(r.rows).toEqual([
      { supplier: 'Ralawise', item_code: 'GD001PIST3XL', cost: '2.68', title: '3XL PISTACHIO GD001 SOFTSTYLE' },
      { supplier: 'Ralawise', item_code: 'JH501NFNAXL', cost: '7.73', title: 'XL FRENCH NAVY JH501' },
    ]);
    expect(r.fileRows).toBe(3); expect(r.unpriced).toEqual(['ABSENT1', 'NOPRICE1']);
  });
  it('leaves out known items with no usable price and says so', () => {
    const r = parseRalawise(ral(rrow('NOPRICE1', 'x', 0, 0), rrow('GD001PIST3XL', 'y', 1, 2)), 'Ralawise', known);
    expect(r.rows.map((x) => x.item_code)).toEqual(['GD001PIST3XL']); expect(r.notes.join(' ')).toMatch(/1 known items had no usable price/);
  });
  it('falls back to the only price block when there is no future block', () => {
    const g: Grid = [['Product', 'Description', 'CTN'], ['GD001PIST3XL', 'a', 3.1]];
    const r = parseRalawise(g, 'Ralawise', known); expect(r.rows[0].cost).toBe('3.1'); expect(r.notes.join(' ')).toMatch(/one price block/);
  });
  it('refuses a file that is not a Ralawise price file', () => { expect(parseRalawise([['a', 'b']], 'Ralawise', known).problems[0]).toMatch(/does not look like a Ralawise/); });
  it('says when nothing in the file is known', () => { expect(parseRalawise(ral(rrow('ZZ1', 'x', 1, 1)), 'Ralawise', known).problems[0]).toMatch(/None of the items/); });
});

describe('parseOrn', () => {
  const grid: Grid = [['Code', 'Product', 'BA26'], [1150, 'Eagle Polo', 7.5], ['1005R', 'Waxbill', 4.35], ['2100N', 'Kneepad Trouser', 20], [1000, 'Plover', 2.45]];
  const known = new Set(['1150.NV.L', '1150.NV.XL', '1150.BK.L', '2100N.BK.S.42', '2126', '9999.NV.L', 'GD001PIST3XL']);
  it('applies each style price to every known item code in that style', () => {
    const r = parseOrn(grid, 'ORN Workwear', known);
    expect(r.problems).toEqual([]);
    expect(r.rows).toEqual([
      { supplier: 'ORN Workwear', item_code: '1150.BK.L', cost: '7.5', title: 'Eagle Polo' },
      { supplier: 'ORN Workwear', item_code: '1150.NV.L', cost: '7.5', title: 'Eagle Polo' },
      { supplier: 'ORN Workwear', item_code: '1150.NV.XL', cost: '7.5', title: 'Eagle Polo' },
      { supplier: 'ORN Workwear', item_code: '2100N.BK.S.42', cost: '20', title: 'Kneepad Trouser' },
    ]);
    expect(r.unpriced).toEqual(['9999.NV.L']); // dotted, but its style is not in the file. 2126 and GD001... are not ORN-style codes.
  });
  it('refuses a file that is not an ORN price file', () => { expect(parseOrn([['x', 'y', 'z']], 'ORN Workwear', known).problems[0]).toMatch(/does not look like an ORN/); });
  it('says when no style matches', () => { expect(parseOrn(grid, 'ORN Workwear', new Set(['7777.NV.L'])).problems[0]).toMatch(/None of the ORN item codes/); });
});

describe('parsePriceFile', () => {
  it('picks the layout', () => { expect(parsePriceFile('orn', [['Code', 'Product', 'P'], [1, 'x', 2]], 'S', new Set(['1.A.B'])).rows).toHaveLength(1); });
  it('refuses more than 20,000 lines', () => {
    const known = new Set<string>(); const rows: Grid = [['Code', 'Product', 'P'], [1, 'x', 2]];
    for (let i = 0; i < 20001; i++) known.add(`1.A.${i}`);
    expect(parsePriceFile('orn', rows, 'S', known).problems[0]).toMatch(/20,000/);
  });
});

describe('parsePenCarrie', () => {
  const head = ['mystat', 'prodcode', 'supprodcode', 'style', 'colour', 'longcolour', 'size', 'position', 'brand', 'price_ctn', 'price_pck', 'price_sngl', 'vatcode', 'PenCarrieEAN', 'commoditycode', 'styledescprint'];
  const row = (own: string, brand: string, p: number | null, desc = 'Premier Shirt'): Grid[number] => ['-', own, brand, 's', 'c', 'Black', '4XL', 1, 'Premier', p, p, p, '1', '', '', desc];
  const grid: Grid = [head, row('PR694 BLK 4XL', 'PR694BLAC4XL', 13.45), row('520M BLK XL', '0R520M036XL', 42.75, 'Russell Trousers'), row('NOPRICE', 'NP1', null), row('ZZ9', 'ZZ9X', 1)];
  const known = new Set(['PR694BLAC4XL', '520M BLK XL', 'NOPRICE', 'ABSENT', 'GD001PIST3XL']);
  it('matches on either the PenCarrie code or the brand code and uses the single price', () => {
    const r = parsePenCarrie(grid, 'PenCarrie', known);
    expect(r.problems).toEqual([]);
    expect(r.rows).toEqual([
      { supplier: 'PenCarrie', item_code: 'PR694BLAC4XL', cost: '13.45', title: 'Premier Shirt Black 4XL' },
      { supplier: 'PenCarrie', item_code: '520M BLK XL', cost: '42.75', title: 'Russell Trousers Black 4XL' },
    ]);
    expect(r.fileRows).toBe(4); expect(r.unpriced).toEqual(['ABSENT', 'GD001PIST3XL', 'NOPRICE']); expect(r.notes.join(' ')).toMatch(/1 known items had no usable price/);
  });
  it('refuses a file that is not a PenCarrie price file and works through parsePriceFile', () => {
    expect(parsePenCarrie([['a', 'b']], 'PenCarrie', known).problems[0]).toMatch(/does not look like a PenCarrie/);
    expect(parsePriceFile('pencarrie', grid, 'PenCarrie', known).rows).toHaveLength(2);
  });
});

describe('matching DecoNetwork-numbered items to Ralawise codes', () => {
  const R = (code: string, desc: string, cost = '1'): FileRow => ({ code, desc, cost });
  const rows = [R('WM118NATUXS', 'XS NATURAL WM118 DRAWCORD BAG', '0.67'), R('WM118NATUS', 'SML NATURAL WM118 DRAWCORD BAG', '0.72'), R('WM118BLACXS', 'XS BLACK WM118 DRAWCORD BAG'),
    R('JC232FNAVM', 'MED FRENCH NAVY JC232 ACTIVE RECYLE'), R('JC232FNAVXL', 'XL FRENCH NAVY JC232 ACTIVE RECYLE'), R('JC232FNAV2XL', '2XL FRENCH NAVY JC232 ACTIVE RECYLE'),
    R('KK188BLAC14.5', '14.5 BLACK KK188 L/S OXFORD SHIRT'), R('KK188BLAC16.0', '16 BLACK KK188 L/S OXFORD SHIRT'),
    R('ST179NYNYXL', 'XL NAVY/NAVY ST179/XB-4 MATRIX JKT'), R('RE22XFORASM', 'SML/MED FLU.ORANGE R22X SAFETY TROUSER'), R('RE22XFORALXL', 'LGE/XL FLU.ORANGE R22X SAFETY TROUSER'),
    R('PR137NAVY', 'NAVY PR137 CALIBRE POCKET APRON'), R('PR137RED', 'RED PR137 CALIBRE POCKET APRON', '6.89'), R('RG332NAVY32', '32 NAVY RG332 SHORTS'), R('RG33NAVY32', '32 NAVY RG33 OTHER SHORTS')];
  const L = (product_code: string, colour: string, size: string) => ({ sku: '1_1', product_code, colour, size, supplier: 'Ralawise' });
  it('matches style, colour and size to exactly one row', () => {
    expect(matchInternal(L('WM118', 'Natural', 'XS'), rows)?.code).toBe('WM118NATUXS');
    expect(matchInternal(L('JC232', 'French Navy', 'X Large'), rows)?.code).toBe('JC232FNAVXL');
    expect(matchInternal(L('JC232', 'French Navy', '2X Large'), rows)?.code).toBe('JC232FNAV2XL');
    expect(matchInternal(L('KK188', 'Black', '14.5'), rows)?.code).toBe('KK188BLAC14.5');
    expect(matchInternal(L('KK188', 'Black', '16'), rows)?.code).toBe('KK188BLAC16.0');
    expect(matchInternal(L('ST179', 'Navy/Navy', 'X Large'), rows)?.code).toBe('ST179NYNYXL');
    expect(matchInternal(L('RE22X', 'Fluorescent Orange', 'LXL'), rows)?.code).toBe('RE22XFORALXL');
    expect(matchInternal(L('PR137', 'Red', 'ONE SIZE'), rows)?.code).toBe('PR137RED');
  });
  it('leaves an item alone when nothing, or more than one row, fits', () => {
    expect(matchInternal(L('WM118', 'Natural', 'Medium'), rows)).toBeNull(); // no such size
    expect(matchInternal(L('WM118', 'Sky', 'XS'), rows)).toBeNull(); // colour wording differs
    expect(matchInternal(L('ZZ999', 'Black', 'XS'), rows)).toBeNull();
    expect(matchInternal(L('WM118', 'Natural', 'XS'), [...rows, R('WM118NATUXS', 'XS NATURAL WM118 DRAWCORD BAG (COPY)')])).toBeNull(); // two rows fit: never guess
    expect(matchInternal(L('', 'Natural', 'XS'), rows)).toBeNull();
  });
  it('does not treat a longer style as the same style', () => {
    expect(matchInternal(L('RG33', 'Navy', '32'), rows)?.code).toBe('RG33NAVY32');
    expect(matchInternal(L('RG332', 'Navy', '32'), rows)?.code).toBe('RG332NAVY32');
  });
  it('stores the supplier code and the file price when a price file is read', () => {
    const g: Grid = [['Product', 'Description', 'CTN'], ['WM118NATUXS', 'XS NATURAL WM118 DRAWCORD BAG', 0.67], ['WM118NATUS', 'SML NATURAL WM118 DRAWCORD BAG', 0.72], ['WM118BLACXS', 'XS BLACK WM118 DRAWCORD BAG', 0.7]];
    const lines = [{ sku: '264928361_194082258', product_code: 'WM118', colour: 'Natural', size: 'XS', supplier: 'Ralawise' }, { sku: '264928361_999', product_code: 'WM118', colour: 'Sky', size: 'XS', supplier: 'Ralawise' }, { sku: '270_1', product_code: 'WM118', colour: 'Natural', size: 'XS', supplier: 'Portwest Clothing Ltd' }];
    const r = parseRalawise(g, 'Ralawise', new Set(['264928361_194082258', '264928361_999', '270_1']), lines);
    expect(r.rows).toEqual([{ supplier: 'Ralawise', item_code: '264928361_194082258', cost: '0.67', supplier_sku: 'WM118NATUXS', title: 'XS NATURAL WM118 DRAWCORD BAG' }]);
    expect(r.unpriced).toEqual(['264928361_999', '270_1']); expect(r.notes.join(' ')).toMatch(/1 of 2 items carrying a DecoNetwork number were matched/);
  });
});
