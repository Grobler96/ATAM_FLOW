import { describe, expect, it } from 'vitest';
import { parseSkuList } from './stocktake';

describe('parseSkuList', () => {
  it('splits on spaces, commas, semicolons and new lines, upper-cases and removes repeats', () => {
    expect(parseSkuList('polo-nvy-m, TEE-BLK-L\nTEE-BLK-L;  hoodie-grey-xl ')).toEqual(['POLO-NVY-M', 'TEE-BLK-L', 'HOODIE-GREY-XL']);
  });
  it('copes with nothing', () => { expect(parseSkuList('')).toEqual([]); expect(parseSkuList(' , ; ')).toEqual([]); });
});
