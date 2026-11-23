import { describe, expect, it } from 'vitest';
import { marginDetail, marginTone, marginWords, priceAgeWords, priceIsStale } from './profit';
import type { OrderProfitRow } from '../data/types';

const row = (o: Partial<OrderProfitRow> = {}): OrderProfitRow => ({ order_id: 'o', order_ref: '#1', sell_value: 190, stock_cost: 110, margin: 80, margin_pct: 42.1, lines: 4, costed_lines: 2, missing_cost_lines: 1, unpriced_sale_lines: 0, complete: false, ...o });
describe('margin over stock cost', () => {
  it('says the amount and the percentage', () => { expect(marginWords(row())).toBe('£80.00 (42.1%)'); });
  it('says plainly when nothing can be worked out', () => { expect(marginWords(undefined)).toBe('Not worked out yet'); expect(marginWords(row({ margin: null, costed_lines: 0 }))).toMatch(/No lines/); });
  it('lists what is missing', () => { expect(marginDetail(row())).toBe('Sells for £190.00, stock costs £110.00 · 2 of 4 lines counted · 1 stock line with no catalogue cost'); expect(marginDetail(row({ missing_cost_lines: 0, unpriced_sale_lines: 2, costed_lines: 4 }))).toContain('2 lines with no sale price'); expect(marginDetail(null)).toBeNull(); });
  it('colours a loss red, a complete margin green, an incomplete one amber', () => { expect(marginTone(row({ margin: -5 }))).toBe('critical'); expect(marginTone(row({ complete: true }))).toBe('good'); expect(marginTone(row())).toBe('high'); expect(marginTone(undefined)).toBe(''); });
});
describe('price age', () => {
  it('words', () => { expect(priceAgeWords(null)).toBe('No prices loaded yet'); expect(priceAgeWords(0)).toBe('Prices loaded today'); expect(priceAgeWords(1)).toBe('Prices last loaded 1 day ago'); expect(priceAgeWords(120)).toBe('Prices last loaded 120 days ago'); });
  it('is stale from 90 days', () => { expect(priceIsStale(89)).toBe(false); expect(priceIsStale(90)).toBe(true); expect(priceIsStale(null)).toBe(false); });
});
