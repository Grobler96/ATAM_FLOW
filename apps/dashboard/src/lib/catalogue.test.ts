import { describe, expect, it } from 'vitest';
import { parseCatalogue, parseCsv } from './catalogue';

describe('parseCatalogue', () => {
  it('reads supplier, item code and cost', () => {
    const p = parseCatalogue('Supplier,Item code,Cost\nRalawise,JH001,4.25\nPortwest,JH001,£4.60\n');
    expect(p.problems).toEqual([]); expect(p.rows).toEqual([{ supplier: 'Ralawise', item_code: 'JH001', cost: '4.25' }, { supplier: 'Portwest', item_code: 'JH001', cost: '4.60' }]);
  });
  it('accepts other header names, a BOM, Windows line endings and quoted commas', () => {
    const p = parseCatalogue('﻿Vendor,SKU,Unit cost,Preferred\r\n"Ralawise, UK","A,1","1,234.50",yes\r\n');
    expect(p.rows).toEqual([{ supplier: 'Ralawise, UK', item_code: 'A,1', cost: '1234.50', preferred: 'yes' }]);
  });
  it('reads semicolon separated files (some Excel setups)', () => { expect(parseCsv('a;b;c\n1;2;3')).toEqual([['a', 'b', 'c'], ['1', '2', '3']]); });
  it('says which column is missing', () => { expect(parseCatalogue('Supplier,Code\nA,B').problems).toEqual(['There is no "Cost" column.']); });
  it('skips blank lines', () => { expect(parseCatalogue('Supplier,Item code,Cost\n\nA,B,1\n\n').rows).toHaveLength(1); });
  it('needs a product row', () => { expect(parseCatalogue('Supplier,Item code,Cost').problems).toHaveLength(1); });
});
