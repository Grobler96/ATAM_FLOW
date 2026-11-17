import type { BuyLineRow } from '../data/types';

// Works out which purchase orders a set of customer orders needs: one per supplier and delivery place.
// A line goes to the supplier set in the product catalogue; a line with none goes to `fallbackSupplier` (chosen by the person), or is left "unassigned".
// Third-party orders default to being delivered straight to their decorator; everything else to our warehouse.
export interface PlanOrderInfo { orderId: string; thirdParty: boolean; producerId: string | null; producerName: string | null }
export interface PlanGroup { key: string; supplierId: string | null; supplier: string | null; deliverTo: 'warehouse' | 'producer'; producerId: string | null; producerName: string | null; lines: PlanLine[]; orderIds: string[]; skus: string[]; units: number; cost: number; missingCost: number }
export interface PlanLine { sku: string; product: string | null; colour: string | null; size: string | null; qty: number; unitCost: number | null; orders: string[] }

export function planPos(lines: BuyLineRow[], orders: Map<string, PlanOrderInfo>, fallbackSupplier?: { id: string; name: string } | null): { groups: PlanGroup[]; unassigned: BuyLineRow[] } {
  const groups = new Map<string, PlanGroup>(); const unassigned: BuyLineRow[] = [];
  for (const l of lines) {
    const info = orders.get(l.order_id);
    const sup = l.supplier_id ? { id: l.supplier_id, name: l.supplier } : fallbackSupplier ? { id: fallbackSupplier.id, name: fallbackSupplier.name } : null;
    if (!sup) { unassigned.push(l); continue; }
    const direct = !!info?.thirdParty && !!info.producerId;
    const key = `${sup.id}|${direct ? info!.producerId : 'warehouse'}`;
    let g = groups.get(key);
    if (!g) { g = { key, supplierId: sup.id, supplier: sup.name, deliverTo: direct ? 'producer' : 'warehouse', producerId: direct ? info!.producerId : null, producerName: direct ? info!.producerName : null, lines: [], orderIds: [], skus: [], units: 0, cost: 0, missingCost: 0 }; groups.set(key, g); }
    let pl = g.lines.find((x) => x.sku === l.sku && x.colour === l.colour && x.size === l.size);
    if (!pl) { pl = { sku: l.sku, product: l.product_name, colour: l.colour, size: l.size, qty: 0, unitCost: l.unit_cost, orders: [] }; g.lines.push(pl); }
    pl.qty += l.qty_needed; if (!pl.orders.includes(l.order_ref)) pl.orders.push(l.order_ref);
    if (!g.orderIds.includes(l.order_id)) g.orderIds.push(l.order_id);
    if (!g.skus.includes(l.sku)) g.skus.push(l.sku);
  }
  for (const g of groups.values()) {
    g.lines.sort((a, b) => a.sku.localeCompare(b.sku));
    g.units = g.lines.reduce((t, x) => t + x.qty, 0);
    g.cost = g.lines.reduce((t, x) => t + (x.unitCost ?? 0) * x.qty, 0);
    g.missingCost = g.lines.filter((x) => x.unitCost === null).length;
  }
  return { groups: [...groups.values()].sort((a, b) => (a.supplier ?? '').localeCompare(b.supplier ?? '') || a.deliverTo.localeCompare(b.deliverTo)), unassigned };
}
