import { describe, expect, it } from 'vitest';
import { parseOrn, parsePriceFile, parseRalawise, type Grid } from './priceFiles';

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
