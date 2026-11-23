import type { OrderProfitRow } from '../data/types';
import { money } from './domain';

// "Margin over stock cost": what the order's lines sell for (DecoNetwork's price, ex VAT) less what the stock costs from the preferred supplier.
// It is before decoration, delivery and overheads, and only counts lines that have both a sale price and a catalogue cost.
export function marginWords(p: OrderProfitRow | undefined | null): string {
  if (!p) return 'Not worked out yet';
  if (p.margin === null || p.costed_lines === 0) return 'No lines have a sale price and a catalogue cost yet';
  return `${money(p.margin, 2)}${p.margin_pct === null ? '' : ` (${p.margin_pct}%)`}`;
}
export function marginDetail(p: OrderProfitRow | undefined | null): string | null {
  if (!p || p.margin === null) return null;
  const bits = [`Sells for ${money(p.sell_value, 2)}, stock costs ${money(p.stock_cost, 2)}`, `${p.costed_lines} of ${p.lines} lines counted`];
  if (p.missing_cost_lines) bits.push(`${p.missing_cost_lines} stock line${p.missing_cost_lines === 1 ? '' : 's'} with no catalogue cost`);
  if (p.unpriced_sale_lines) bits.push(`${p.unpriced_sale_lines} line${p.unpriced_sale_lines === 1 ? '' : 's'} with no sale price`);
  return bits.join(' · ');
}
export const marginTone = (p: OrderProfitRow | undefined | null): 'good' | 'high' | 'critical' | '' => (!p || p.margin === null ? '' : p.margin < 0 ? 'critical' : p.complete ? 'good' : 'high');

export const PRICE_STALE_DAYS = 90;
export const priceAgeWords = (days: number | null | undefined): string => (days === null || days === undefined ? 'No prices loaded yet' : days === 0 ? 'Prices loaded today' : `Prices last loaded ${days} day${days === 1 ? '' : 's'} ago`);
export const priceIsStale = (days: number | null | undefined): boolean => days !== null && days !== undefined && days >= PRICE_STALE_DAYS;
