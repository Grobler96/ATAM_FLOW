import type { OrderLineRow, PoLineRow, PoRow } from '../data/types';

// Why an order that was picked for a purchase order has nothing left to buy, in plain words, one sentence per item.
// The usual reason is that its stock is already covered: reserved from the shelf, or reserved from a purchase order that is already on its way
// (often one raised in DecoNetwork, which Flow brings in). Saying so stops people hunting for a PO that Flow did not make.
type Line = Pick<OrderLineRow, 'sku' | 'colour' | 'size' | 'qty_required' | 'qty_produced' | 'qty_allocated_on_hand' | 'qty_allocated_incoming'>;
type PoLine = Pick<PoLineRow, 'po_id' | 'sku' | 'qty_outstanding'>;
type Po = Pick<PoRow, 'po_id' | 'po_ref' | 'origin' | 'supplier' | 'expected_date' | 'delivery_status'>;

const DONE = new Set(['received', 'cancelled', 'closed']);
const day = (iso: string | null | undefined): string => (iso ? new Date(iso).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) : '');
const what = (l: Line): string => `${l.qty_required} × ${l.sku ?? 'item'}${[l.colour, l.size].filter(Boolean).length ? ` (${[l.colour, l.size].filter(Boolean).join(', ')})` : ''}`;

export function incomingPos(sku: string | null, poLines: readonly PoLine[], pos: readonly Po[]): Po[] {
  if (!sku) return [];
  const byId = new Map(pos.map((p) => [p.po_id, p])); const out: Po[] = []; const seen = new Set<string>();
  for (const pl of poLines) {
    if (pl.sku !== sku || !(pl.qty_outstanding > 0) || seen.has(pl.po_id)) continue;
    const p = byId.get(pl.po_id); if (!p || DONE.has(String(p.delivery_status ?? ''))) continue;
    seen.add(pl.po_id); out.push(p);
  }
  return out.sort((a, b) => (a.expected_date ?? '9').localeCompare(b.expected_date ?? '9'));
}

export function poLabel(p: Po): string {
  return `purchase order ${p.po_ref}${p.origin === 'deconetwork' ? ' (raised in DecoNetwork)' : ''}${p.supplier ? ` from ${p.supplier}` : ''}${p.expected_date ? `, due ${day(p.expected_date)}` : ''}`;
}

export function whyNothingToBuy(lines: readonly Line[], poLines: readonly PoLine[], pos: readonly Po[]): string[] {
  const out: string[] = [];
  for (const l of lines) {
    const need = l.qty_required - l.qty_produced; if (need <= 0) { if (l.qty_required > 0) out.push(`${what(l)}: already made.`); continue; }
    const bits: string[] = [];
    if (l.qty_allocated_on_hand > 0) bits.push(`${l.qty_allocated_on_hand} reserved from the stock on the shelf`);
    if (l.qty_allocated_incoming > 0) { const p = incomingPos(l.sku, poLines, pos).slice(0, 2); bits.push(p.length ? `${l.qty_allocated_incoming} reserved from ${p.map(poLabel).join(' and ')}` : `${l.qty_allocated_incoming} reserved from a purchase order that is already on its way`); }
    out.push(`${what(l)}: ${bits.length ? bits.join(' and ') + '.' : 'already covered.'}`);
  }
  return out;
}
