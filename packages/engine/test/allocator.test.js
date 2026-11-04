'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildAllocationPlan } = require('../allocator.js');

const TODAY = '2026-11-09';
const NOW = '2026-11-09T09:00:00Z';
const line = (id, sku, need, o = {}) => Object.assign({ id, sku, need, product_name: 'Hoodie', colour: 'Black', size: 'L' }, o);
const order = (id, lines, o = {}) => Object.assign({ id, order_ref: '#' + id, customer: 'Cust ' + id, due_date: '2026-11-20', order_date: '2026-11-01', priority: 0, is_vip: false,
  order_value: 0, methods: ['embroidery'], lines }, o);
const base = (o = {}) => Object.assign({ now: NOW, today: TODAY, settings: {}, active_methods: ['embroidery', 'dtf'], stock: [], incoming: [], orders: [], fixed_allocations: [] }, o);
const po = (id, sku, outstanding, expected, n = 'PO' + id) => ({ po_line_id: id, po_number: n, supplier: 'Ralawise', sku, outstanding, expected_date: expected });
const get = (plan, id) => plan.orders.find((x) => x.order_id === id);
const totalOnHand = (plan, sku) => plan.allocations.filter((a) => a.sku === sku && a.source === 'on_hand').reduce((t, a) => t + a.qty, 0);

test('the more urgent order gets scarce stock; the other is told where it went', () => {
  const plan = buildAllocationPlan(base({
    stock: [{ sku: 'H-BLK-L', on_hand: 10 }],
    orders: [order('late', [line('l1', 'H-BLK-L', 10)], { due_date: '2026-11-18' }), order('over', [line('l2', 'H-BLK-L', 10)], { due_date: '2026-11-05' })] }));
  assert.equal(get(plan, 'over').decision, 'allocate');
  assert.equal(get(plan, 'over').rank, 1);
  assert.match(get(plan, 'over').reason, /Allocated first: overdue by 4 day\(s\), 100% of stock on hand, completes the full order/);
  assert.equal(get(plan, 'late').decision, 'blocked');
  assert.match(get(plan, 'late').reason, /Blocked: missing 10 × Hoodie Black L; no stock on hand and no purchase order/);
  assert.match(get(plan, 'late').reason, /went to higher-ranked orders #over/);
});

test('stock is never allocated twice', () => {
  const orders = []; for (let i = 0; i < 6; i++) orders.push(order('o' + i, [line('x' + i, 'S', 4)], { due_date: '2026-11-1' + i }));
  const plan = buildAllocationPlan(base({ stock: [{ sku: 'S', on_hand: 15 }], orders }));
  assert.ok(totalOnHand(plan, 'S') <= 15);
  assert.equal(totalOnHand(plan, 'S'), 15);
});

test('an order stock can complete is served before one it cannot', () => {
  const plan = buildAllocationPlan(base({
    stock: [{ sku: 'S', on_hand: 50 }],
    orders: [order('big', [line('b', 'S', 80)]), order('fits', [line('f', 'S', 50)])] }));
  assert.equal(get(plan, 'fits').decision, 'allocate');
  assert.equal(get(plan, 'fits').rank, 1);
  assert.notEqual(get(plan, 'big').decision, 'allocate');
});

test('partial allocation above the threshold; hold below it unless the order is urgent', () => {
  const stock = [{ sku: 'S', on_hand: 60 }];
  const above = buildAllocationPlan(base({ stock, orders: [order('a', [line('a1', 'S', 100)])] }));
  assert.equal(get(above, 'a').decision, 'partial');
  assert.equal(get(above, 'a').qty_allocated_on_hand, 60);
  assert.match(get(above, 'a').reason, /Partial: 60 of 100 unit\(s\) \(60%\)/);

  const below = buildAllocationPlan(base({ stock: [{ sku: 'S', on_hand: 30 }], orders: [order('b', [line('b1', 'S', 100)])] }));
  assert.equal(get(below, 'b').decision, 'hold');
  assert.equal(get(below, 'b').qty_allocated_on_hand, 0);
  assert.equal(get(below, 'b').qty_available_not_reserved, 30);
  assert.match(get(below, 'b').reason, /Held: only 30% of required stock is on hand \(below 50%\)/);

  const urgent = buildAllocationPlan(base({ stock: [{ sku: 'S', on_hand: 30 }], orders: [order('c', [line('c1', 'S', 100)], { due_date: '2026-11-10' })] }));
  assert.equal(get(urgent, 'c').decision, 'partial');
  assert.match(get(urgent, 'c').reason, /because the order is urgent/);
});

test('incoming PO units are reserved in priority order, with projected ready date and late risk', () => {
  const plan = buildAllocationPlan(base({
    incoming: [po('p1', 'S', 10, '2026-11-12', '876882')],
    orders: [order('first', [line('a', 'S', 6)], { due_date: '2026-11-14' }), order('second', [line('b', 'S', 6)], { due_date: '2026-11-25' })] }));
  assert.equal(get(plan, 'first').decision, 'hold');
  assert.equal(get(plan, 'first').qty_reserved_incoming, 6);
  assert.equal(get(plan, 'first').projected_ready_date, '2026-11-12');
  assert.equal(get(plan, 'first').late_risk, false);
  assert.match(get(plan, 'first').reason, /6 unit\(s\) reserved from PO 876882 \(latest due Thu 12 Nov\)\. Projected ready Thu 12 Nov, in time for the due date/);
  assert.equal(get(plan, 'second').qty_reserved_incoming, 4);                       // only 4 left on the PO
  assert.equal(get(plan, 'second').qty_short, 2);
  assert.ok(plan.allocations.filter((a) => a.source === 'incoming_po').reduce((t, a) => t + a.qty, 0) <= 10);

  const late = buildAllocationPlan(base({ incoming: [po('p2', 'S', 5, '2026-11-18')], orders: [order('l', [line('a', 'S', 5)], { due_date: '2026-11-15' })] }));
  assert.equal(get(late, 'l').late_risk, true);
  assert.match(get(late, 'l').reason, /AFTER the due date/);
  assert.ok(get(late, 'l').actions.some((a) => a.type === 'expedite_po'));
});

test('purchase orders past their expected date are treated as late, not trusted', () => {
  const plan = buildAllocationPlan(base({ incoming: [po('p', 'S', 5, '2026-11-02')], orders: [order('o', [line('a', 'S', 5)], { due_date: '2026-11-11' })] }));
  assert.equal(get(plan, 'o').po_overdue, true);
  assert.equal(get(plan, 'o').projected_ready_date, '2026-11-12');                  // today + 3 assumed days
  assert.equal(get(plan, 'o').late_risk, true);
  assert.match(get(plan, 'o').reason, /some of those POs are overdue/);
  assert.ok(get(plan, 'o').actions.some((a) => a.type === 'chase_supplier'));
});

test('lines with no stock and no PO are listed for purchasing and stop the order being ready', () => {
  const plan = buildAllocationPlan(base({
    stock: [{ sku: 'A', on_hand: 5 }], incoming: [po('p', 'B', 3, '2026-11-12')],
    orders: [order('o', [line('l1', 'A', 5), line('l2', 'B', 3), line('l3', 'C', 7, { product_name: 'Polo', colour: 'Navy', size: 'M' })])] }));
  const o = get(plan, 'o');
  assert.equal(o.qty_short, 7);
  assert.equal(o.projected_ready_date, null);
  assert.match(o.reason, /No stock or PO for: 7 × Polo Navy M/);
  assert.deepEqual(plan.shortages.map((s) => [s.sku, s.short]), [['C', 7]]);
  assert.ok(o.actions.some((a) => a.type === 'raise_po' && a.sku === 'C' && a.qty === 7));
});

test('exact SKU only: a different colour or size is never used', () => {
  const plan = buildAllocationPlan(base({ stock: [{ sku: 'H-BLK-M', on_hand: 100 }], orders: [order('o', [line('a', 'H-BLK-L', 5)])] }));
  assert.equal(get(plan, 'o').decision, 'blocked');
  assert.equal(plan.allocations.length, 0);
});

test('manual allocations are respected: they reduce supply and the order need', () => {
  const plan = buildAllocationPlan(base({
    stock: [{ sku: 'S', on_hand: 12 }],
    fixed_allocations: [{ order_line_id: 'm1', sku: 'S', source: 'on_hand', po_line_id: null, qty: 8 }],
    orders: [order('manual', [line('m1', 'S', 8)]), order('other', [line('o1', 'S', 5)])] }));
  assert.equal(get(plan, 'manual'), undefined);                                     // fully covered by hand: nothing for the engine to do
  assert.equal(totalOnHand(plan, 'S'), 4);                                          // only 4 left for the other order
  assert.equal(get(plan, 'other').qty_short, 1);
});

test('rush and VIP orders outrank otherwise identical ones', () => {
  const plan = buildAllocationPlan(base({
    stock: [{ sku: 'S', on_hand: 5 }],
    orders: [order('plain', [line('a', 'S', 5)]), order('rush', [line('b', 'S', 5)], { priority: 2 }), order('vip', [line('c', 'S', 5)], { is_vip: true })] }));
  assert.equal(get(plan, 'rush').rank, 1);
  assert.equal(get(plan, 'vip').rank, 2);
  assert.equal(get(plan, 'plain').decision, 'blocked');
});

test('every score contributor is reported', () => {
  const plan = buildAllocationPlan(base({ stock: [{ sku: 'S', on_hand: 5 }], orders: [order('o', [line('a', 'S', 5)], { priority: 1, is_vip: true, order_value: 1000 })] }));
  const b = get(plan, 'o').score_breakdown;
  for (const k of ['due_date', 'vip', 'manual_priority', 'order_value', 'order_age', 'production_feasibility', 'completion_pct', 'completable', 'fully_coverable']) assert.ok(k in b, k);
  assert.equal(b.pct_on_hand, 100);
});

test('plans are deterministic', () => {
  const input = base({ stock: [{ sku: 'S', on_hand: 7 }], incoming: [po('p', 'S', 6, '2026-11-13')],
    orders: [order('a', [line('a1', 'S', 5)]), order('b', [line('b1', 'S', 5)]), order('c', [line('c1', 'S', 5)])] });
  assert.deepEqual(buildAllocationPlan(input), buildAllocationPlan(JSON.parse(JSON.stringify(input))));
});

test('large order lists run quickly', () => {
  const orders = []; for (let i = 0; i < 150; i++) orders.push(order('o' + i, [line('a' + i, 'S' + (i % 20), 3), line('b' + i, 'S' + ((i + 7) % 20), 2)], { due_date: '2026-11-' + String(10 + (i % 15)) }));
  const stock = []; for (let i = 0; i < 20; i++) stock.push({ sku: 'S' + i, on_hand: 20 });
  const t = Date.now();
  const plan = buildAllocationPlan(base({ stock, orders }));
  assert.ok(Date.now() - t < 3000, 'took too long');
  for (let i = 0; i < 20; i++) assert.ok(totalOnHand(plan, 'S' + i) <= 20);
});
