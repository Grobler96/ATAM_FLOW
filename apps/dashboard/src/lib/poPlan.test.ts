import { describe, expect, it } from 'vitest';
import { planPos, type PlanOrderInfo } from './poPlan';
import type { BuyLineRow } from '../data/types';

const L = (o: string, ref: string, sku: string, q: number, sup: string | null, cost: number | null, size = 'M'): BuyLineRow => ({ order_id: o, order_ref: ref, order_line_id: o + sku + size, sku, product_name: sku, colour: 'Navy', size, qty_needed: q, supplier_id: sup, supplier: sup ? sup.toUpperCase() : null, unit_cost: cost });
const orders = new Map<string, PlanOrderInfo>([['o1', { orderId: 'o1', thirdParty: true, producerId: 'dps', producerName: 'DPS' }], ['o2', { orderId: 'o2', thirdParty: false, producerId: null, producerName: null }]]);

describe('planPos', () => {
  it('splits one order across the suppliers in the catalogue', () => {
    const { groups } = planPos([L('o1', '#1', 'A', 10, 'ralawise', 4), L('o1', '#1', 'B', 5, 'portwest', 10)], orders);
    expect(groups.map((g) => g.supplier)).toEqual(['PORTWEST', 'RALAWISE']);
  });
  it('merges the same item from two orders going to the same place', () => {
    const { groups } = planPos([L('o1', '#1', 'A', 10, 'r', 4), L('o1', '#3', 'A', 5, 'r', 4)], orders);
    expect(groups).toHaveLength(1); expect(groups[0].lines[0].qty).toBe(15); expect(groups[0].lines[0].orders).toEqual(['#1', '#3']);
  });
  it('delivers third-party orders to the decorator and in-house orders to the warehouse, as separate POs', () => {
    const { groups } = planPos([L('o1', '#1', 'A', 10, 'r', 4), L('o2', '#2', 'A', 5, 'r', 4)], orders);
    expect(groups).toHaveLength(2);
    expect(groups.find((g) => g.deliverTo === 'producer')?.producerName).toBe('DPS');
    expect(groups.find((g) => g.deliverTo === 'warehouse')?.orderIds).toEqual(['o2']);
  });
  it('leaves items with no catalogue supplier unassigned unless a supplier is chosen', () => {
    const lines = [L('o2', '#2', 'Z', 3, null, null)];
    expect(planPos(lines, orders).unassigned).toHaveLength(1);
    const p = planPos(lines, orders, { id: 'x', name: 'X' });
    expect(p.unassigned).toHaveLength(0); expect(p.groups[0].missingCost).toBe(1);
  });
  it('totals units and cost', () => {
    const { groups } = planPos([L('o2', '#2', 'A', 10, 'r', 2.5), L('o2', '#2', 'A', 4, 'r', 2.5, 'L')], orders);
    expect(groups[0].units).toBe(14); expect(groups[0].cost).toBe(35);
  });
});
