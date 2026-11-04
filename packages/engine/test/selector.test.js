'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildSelection } = require('../selector.js');

const TODAY = '2026-11-09';
const line = (id, sku, qty, o = {}) => Object.assign({ id, sku, qty, need_buy: qty, on_hand_qty: 0, stitches: 5000, areas: 1, methods: ['embroidery'] }, o);
const supplier = (id, cost, o = {}) => Object.assign({ id, name: 'Sup' + id, lead_time_days: 3, delivery_cost: 5, on_time_rate: 95, offers: { P1: { unit_cost: cost, min_qty: 1, stock_available: 1000 } } }, o);
const producer = (id, price, o = {}) => Object.assign({ id, name: 'Prod' + id, capable_methods: ['embroidery'], turnaround_days: 3, cost_out: 8, cost_back: 8, on_time_rate: 92,
  rates: { embroidery: { basis: 'per_1000_stitches', unit_price: price, setup_fee: 10, min_job_charge: 30 } } }, o);
const internal = (o = {}) => Object.assign({ enabled: true, methods: ['embroidery'], queue_days: 2, units_per_day: 100, rates: { embroidery: { basis: 'per_1000_stitches', unit_price: 1.0, setup_fee: 10, min_job_charge: 0 } } }, o);
const base = (o = {}) => Object.assign({ today: TODAY, order: { id: 'o1', order_ref: '#1', due_date: '2026-11-30', revenue: 400, methods: ['embroidery'], lines: [line('l1', 'P1', 20)] },
  suppliers: [supplier('A', 5)], producers: [producer('X', 0.8)], internal: internal() }, o);
const find = (r, supId, routeId) => r.options.find((o) => (o.suppliers.some((s) => s.id === supId) || supId == null) && o.route.id === routeId && !o.route.supplier_direct_to_producer);

test('costs add up: blanks + delivery + decoration (+ transport for producers)', () => {
  const r = buildSelection(base());
  const inh = find(r, 'A', 'internal');
  assert.equal(inh.costs.blanks, 100);
  assert.equal(inh.costs.supplier_delivery, 5);
  assert.equal(inh.costs.decoration, 110);            // 20 x 5 x 1.00 + 10 setup
  assert.equal(inh.costs.total, 215);
  assert.equal(inh.profit, 185);
  assert.equal(inh.margin_pct, 46.3);
  assert.equal(inh.cost_per_unit, 10.75);
  const px = find(r, 'A', 'X');
  assert.equal(px.costs.decoration, 90);              // 20 x 5 x 0.80 + 10 setup
  assert.equal(px.costs.transport_to_producer + px.costs.transport_back, 16);
  assert.equal(px.costs.total, 211);
});

test('recommends the best complete, on-time option and explains why in plain English', () => {
  const r = buildSelection(base());
  assert.ok(r.recommended_key);
  const rec = r.options.find((o) => o.key === r.recommended_key);
  assert.ok(rec.labels.includes('Recommended'));
  assert.match(r.explanation, /^Recommended: SupA \+ /);
  assert.match(r.explanation, /profit £\d/);
  assert.match(r.explanation, /Runner-up/);
  assert.equal(r.summary.options, r.options.length);
});

test('a producer that cannot meet the due date is flagged late and not recommended', () => {
  const r = buildSelection(base({ order: { id: 'o1', order_ref: '#1', due_date: '2026-11-17', revenue: 400, methods: ['embroidery'], lines: [line('l1', 'P1', 20)] },
    producers: [producer('SLOW', 0.2, { turnaround_days: 10 })] }));
  const slow = find(r, 'A', 'SLOW');
  assert.equal(slow.late, true);
  assert.ok(slow.risk.flags.some((f) => f.code === 'late'));
  assert.equal(r.options.find((o) => o.key === r.recommended_key).route.id, 'internal');
  assert.match(r.explanation, /cheapest option is SupA \+ ProdSLOW/);
});

test('missing rates make an option incomplete and it is never recommended', () => {
  const p = producer('NR', 0.5); delete p.rates.embroidery;
  const r = buildSelection(base({ producers: [p] }));
  assert.equal(find(r, 'A', 'NR').incomplete, true);
  assert.notEqual(r.options.find((o) => o.key === r.recommended_key).route.id, 'NR');
  const none = buildSelection(base({ producers: [p], internal: { enabled: false } }));
  assert.equal(none.recommended_key, null);
  assert.match(none.explanation, /missing costs/);
});

test('suppliers and producers that cannot do the job are rejected with a reason', () => {
  const r = buildSelection(base({ suppliers: [supplier('A', 5), { id: 'B', name: 'SupB', offers: {} }], producers: [producer('DTF', 1, { capable_methods: ['dtf'] })] }));
  assert.ok(r.rejected.some((x) => x.what === 'SupB' && /does not list 1 of the 1 SKUs/.test(x.reason)));
  assert.ok(r.rejected.some((x) => x.what === 'ProdDTF' && /cannot do embroidery/.test(x.reason)));
  assert.ok(r.options.every((o) => o.route.id !== 'DTF'));
});

test('what-if: changing a supplier cost or the quantity recalculates everything', () => {
  const input = base({ suppliers: [supplier('A', 5), supplier('B', 4, { delivery_cost: 5 })] });
  const r1 = buildSelection(input);
  assert.equal(find(r1, 'B', 'internal').costs.blanks, 80);
  const r2 = buildSelection(Object.assign({}, input, { overrides: { sku_costs: { P1: 9 } } }));
  assert.equal(find(r2, 'B', 'internal').costs.blanks, 180);
  const r3 = buildSelection(Object.assign({}, input, { overrides: { qty_multiplier: 2 } }));
  assert.equal(find(r3, 'A', 'internal').costs.blanks, 200);
  assert.equal(r3.units, 40);
  const r4 = buildSelection(Object.assign({}, input, { overrides: { supplier_cost_adjust_pct: 10 } }));
  assert.equal(find(r4, 'A', 'internal').costs.blanks, 110);
});

test('forcing a choice selects it and says it differs from the recommendation', () => {
  const input = base({ suppliers: [supplier('A', 5), supplier('B', 4)], overrides: { force: { supplier_id: 'A', route_id: 'X' } } });
  const r = buildSelection(input);
  assert.equal(r.selected_key, find(r, 'A', 'X').key);
  assert.equal(r.selected_differs_from_recommended, r.selected_key !== r.recommended_key);
});

test('a split across two suppliers appears only when it is cheaper than any single supplier', () => {
  const a = supplier('A', 5, { offers: { P1: { unit_cost: 5, stock_available: 100 }, P2: { unit_cost: 20, stock_available: 100 } }, delivery_cost: 5 });
  const b = supplier('B', 5, { offers: { P1: { unit_cost: 9, stock_available: 100 }, P2: { unit_cost: 12, stock_available: 100 } }, delivery_cost: 5 });
  const order = { id: 'o2', order_ref: '#2', due_date: '2026-11-30', revenue: 900, methods: ['embroidery'], lines: [line('l1', 'P1', 20), line('l2', 'P2', 20)] };
  const r = buildSelection(base({ order, suppliers: [a, b] }));
  const split = r.options.find((o) => o.supplier_plan.startsWith('Split'));
  assert.ok(split, 'split offered');
  assert.equal(split.costs.blanks, 340);               // 20 x 5 (A) + 20 x 12 (B)
  assert.equal(split.costs.supplier_delivery, 10);
  const same = buildSelection(base({ order, suppliers: [a, Object.assign({}, b, { offers: { P1: { unit_cost: 9 }, P2: { unit_cost: 25 } } })] }));
  assert.ok(!same.options.some((o) => o.supplier_plan.startsWith('Split')), 'no split when one supplier is cheapest for everything');
});

test('supplier delivering straight to a producer saves the transport leg and a day but is flagged', () => {
  const r = buildSelection(base({ suppliers: [supplier('A', 5, { can_deliver_to_producer: true })] }));
  const direct = r.options.find((o) => o.route.id === 'X' && o.route.supplier_direct_to_producer);
  const via = find(r, 'A', 'X');
  assert.ok(direct && via);
  assert.equal(direct.costs.transport_to_producer, 0);
  assert.ok(direct.timeline.total_days < via.timeline.total_days);
  assert.ok(direct.risk.flags.some((f) => f.code === 'direct_to_producer'));
});

test('low margin is flagged and penalised; stock already held means nothing to buy', () => {
  const low = buildSelection(base({ order: { id: 'o1', order_ref: '#1', due_date: '2026-11-30', revenue: 230, methods: ['embroidery'], lines: [line('l1', 'P1', 20)] } }));
  const o = find(low, 'A', 'internal');
  assert.ok(o.risk.flags.some((f) => f.code === 'low_margin'));
  assert.equal(o.score_parts.penalty, -20);
  const held = buildSelection(base({ order: { id: 'o3', order_ref: '#3', due_date: '2026-11-30', revenue: 400, methods: ['embroidery'], lines: [line('l1', 'P1', 20, { need_buy: 0, on_hand_qty: 20 })] } }));
  assert.ok(held.options.every((x) => x.supplier_plan === 'Stock already held' && x.timeline.supplier_days === 0));
  assert.equal(held.options.find((x) => x.route.id === 'internal').costs.stock_on_hand_value, 100);
});

test('supplier stock shortfall adds restock time and risk; minimum charge applies to small jobs', () => {
  const r = buildSelection(base({ suppliers: [supplier('A', 5, { offers: { P1: { unit_cost: 5, stock_available: 5 } } })],
    order: { id: 'o4', order_ref: '#4', due_date: '2026-11-30', revenue: 100, methods: ['embroidery'], lines: [line('l1', 'P1', 8, { stitches: 1000 })] } }));
  const px = find(r, 'A', 'X');
  assert.equal(px.timeline.supplier_days, 10);          // 3 lead + 7 restock
  assert.ok(px.risk.flags.some((f) => f.code === 'supplier_stock'));
  assert.equal(px.costs.decoration, 30);                // 8 x 1 x 0.8 + 10 = 16.4, minimum 30 applies
  assert.equal(px.costs.decoration_parts[0].minimum_applied, true);
});

test('deterministic and VAT-aware', () => {
  const a = JSON.stringify(buildSelection(base())), b = JSON.stringify(buildSelection(base()));
  assert.equal(a, b);
  const vat = buildSelection(base({ config: { thresholds: { revenue_includes_vat: true } } }));
  assert.equal(vat.revenue, 333.33);
});

test('an order with no decoration method or no value is never recommended (it would look free)', () => {
  const noM = buildSelection(base({ order: { id: 'o5', order_ref: '#5', due_date: '2026-11-30', revenue: 400, methods: [], lines: [line('l1', 'P1', 20, { methods: [] })] } }));
  assert.equal(noM.recommended_key, null);
  assert.ok(noM.options.every((o) => o.incomplete && o.risk.flags.some((f) => f.code === 'no_decoration_method')));
  const noV = buildSelection(base({ order: { id: 'o6', order_ref: '#6', due_date: '2026-11-30', revenue: 0, methods: ['embroidery'], lines: [line('l1', 'P1', 20)] } }));
  assert.equal(noV.recommended_key, null);
  assert.ok(noV.options[0].risk.flags.some((f) => f.code === 'no_revenue'));
});
