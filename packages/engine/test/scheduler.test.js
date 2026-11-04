'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildPlan, zonedToUtc, buildWindows, place } = require('../scheduler.js');

const NOW = '2026-11-09T08:00:00Z';                       // Monday 08:00 London (GMT)
const shifts = [1, 2, 3, 4, 5].map((d) => ({ machine_id: null, weekday: d, start_time: '08:00:00', end_time: '17:00:00' }));
const base = (over = {}) => Object.assign({
  now: NOW, settings: {},
  machines: [{ id: 'm-emb', code: 'EMB-1', method_code: 'embroidery', is_active: true },
             { id: 'm-dtf', code: 'DTF-1', method_code: 'dtf', is_active: true }],
  shifts,
  methods: [{ code: 'embroidery', name: 'Embroidery', setup_minutes: 15 }, { code: 'dtf', name: 'DTF', setup_minutes: 10 }],
  changeover: [{ method_code: 'embroidery', change_type: 'design', minutes: 15 }, { method_code: 'embroidery', change_type: 'thread_colour', minutes: 8 }],
  orders: [], steps: [], overrides: [], fixed_steps: []
}, over);
const order = (id, o = {}) => Object.assign({ id, order_ref: '#' + id, customer_name: 'Cust ' + id, due_date: '2026-11-20T00:00:00Z', priority: 0, is_vip: false, order_status: 'awaiting_stock', alloc_state: 'none' }, o);
const step = (order_id, method_code, run_min, o = {}) => Object.assign({ order_id, method_code, units: 10, run_min, colours: ['Navy'], garment_types: ['Polos'] }, o);
const seq = (plan, method) => plan.steps.filter((s) => s.machine_id && (!method || s.method_code === method)).sort((a, b) => a.sequence_position - b.sequence_position).map((s) => s.order_id);

test('London wall time converts correctly across DST', () => {
  assert.equal(zonedToUtc(2026, 6, 1, 8, 0, 'Europe/London'), Date.UTC(2026, 5, 1, 7, 0));   // BST
  assert.equal(zonedToUtc(2026, 11, 9, 8, 0, 'Europe/London'), Date.UTC(2026, 10, 9, 8, 0)); // GMT
});

test('work pauses overnight and over the weekend', () => {
  const wins = buildWindows([{ weekday: 1, sm: 480, em: 1020 }, { weekday: 2, sm: 480, em: 1020 }, { weekday: 3, sm: 480, em: 1020 }, { weekday: 4, sm: 480, em: 1020 }, { weekday: 5, sm: 480, em: 1020 }],
    Date.parse('2026-11-06T08:00:00Z'), 'Europe/London', 14);                                  // Friday
  const r = place(wins, Date.parse('2026-11-06T15:00:00Z'), 600);                              // 10 working hours from Fri 15:00
  assert.equal(new Date(r.end).toISOString(), '2026-11-09T16:00:00.000Z');                    // Fri 2h + Mon 8h
});

test('overdue and sooner-due work is sequenced first', () => {
  const plan = buildPlan(base({
    orders: [order('late', { due_date: '2026-11-18T00:00:00Z' }), order('over', { due_date: '2026-11-06T00:00:00Z' }), order('mid', { due_date: '2026-11-12T00:00:00Z' })],
    steps: [step('late', 'embroidery', 60), step('over', 'embroidery', 60), step('mid', 'embroidery', 60)] }));
  assert.deepEqual(seq(plan), ['over', 'mid', 'late']);
  assert.match(plan.steps.find((s) => s.order_id === 'over').reason, /overdue by/);
});

test('rush and VIP outrank an otherwise identical order', () => {
  const plan = buildPlan(base({
    orders: [order('a'), order('b', { priority: 2 }), order('c', { is_vip: true })],
    steps: [step('a', 'embroidery', 60), step('b', 'embroidery', 60), step('c', 'embroidery', 60)] }));
  assert.deepEqual(seq(plan), ['b', 'c', 'a']);
});

test('multi-process orders run in physical order (DTF before embroidery)', () => {
  const plan = buildPlan(base({ orders: [order('x')], steps: [step('x', 'embroidery', 120), step('x', 'dtf', 60)] }));
  const dtf = plan.steps.find((s) => s.method_code === 'dtf'), emb = plan.steps.find((s) => s.method_code === 'embroidery');
  assert.equal(dtf.step_no, 1); assert.equal(emb.step_no, 2);
  assert.ok(Date.parse(emb.planned_start) >= Date.parse(dtf.planned_end));
  assert.match(emb.reason, /after the previous process step/);
});

test('a method with no active machine blocks the step and everything after it', () => {
  const plan = buildPlan(base({ orders: [order('x')], steps: [step('x', 'vinyl', 30), step('x', 'embroidery', 60)] }));
  assert.equal(plan.summary.steps_blocked, 2);
  assert.match(plan.blocked.find((b) => b.method_code === 'vinyl').reason, /no active machine/);
  assert.match(plan.blocked.find((b) => b.method_code === 'embroidery').reason, /waiting on blocked/);
  assert.equal(plan.orders[0].production_stage, 'blocked');
});

test('on-hold orders are reported, not scheduled', () => {
  const plan = buildPlan(base({ orders: [order('h', { order_status: 'on_hold' })], steps: [step('h', 'embroidery', 60)] }));
  assert.equal(plan.summary.steps_scheduled, 0);
  assert.equal(plan.blocked[0].reason, 'order is on hold');
});

test('stock gate can hold work until allocation is full', () => {
  const input = base({ settings: { options: { stock_gate: 'require_allocation' } },
    orders: [order('a', { alloc_state: 'full' }), order('b', { alloc_state: 'none' })], steps: [step('a', 'embroidery', 60), step('b', 'embroidery', 60)] });
  const plan = buildPlan(input);
  assert.deepEqual(seq(plan), ['a']);
  assert.match(plan.blocked[0].reason, /stock/);
});

test('related jobs are kept together to avoid changeovers', () => {
  const plan = buildPlan(base({
    orders: [order('o1', { customer_name: 'X' }), order('o2', { customer_name: 'Y' }), order('o3', { customer_name: 'X' })],
    steps: [step('o1', 'embroidery', 60), step('o2', 'embroidery', 60), step('o3', 'embroidery', 60)] }));
  assert.deepEqual(seq(plan), ['o1', 'o3', 'o2']);
  const o3 = plan.steps.find((s) => s.order_id === 'o3');
  assert.equal(o3.setup_minutes, 0);
  assert.match(o3.reason, /no changeover/);
});

test('manual pin wins, and the system recommendation is kept alongside it', () => {
  const input = base({
    orders: [order('a', { due_date: '2026-11-10T00:00:00Z' }), order('b', { due_date: '2026-11-30T00:00:00Z' })],
    steps: [step('a', 'embroidery', 60), step('b', 'embroidery', 60)],
    overrides: [{ order_id: 'b', method_code: null, pin_rank: 1, note: 'customer collecting', set_by: 'Daniel' }] });
  const plan = buildPlan(input);
  assert.deepEqual(seq(plan), ['b', 'a']);
  const b = plan.steps.find((s) => s.order_id === 'b');
  assert.equal(b.sequence_position, 1); assert.equal(b.recommended_position, 2);
  assert.match(b.reason, /PINNED by Daniel: customer collecting/);
});

test('predicted-late work and the bottleneck are flagged', () => {
  const orders = [], steps = [];
  for (let i = 0; i < 6; i++) { orders.push(order('big' + i, { due_date: '2026-11-10T00:00:00Z', customer_name: 'C' + i })); steps.push(step('big' + i, 'embroidery', 480)); }
  const plan = buildPlan(base({ orders, steps }));
  assert.ok(plan.summary.steps_late >= 4);
  assert.equal(plan.bottleneck.method, 'embroidery');
  assert.ok(plan.batches.some((b) => b.is_bottleneck));
  assert.ok(plan.orders.filter((o) => o.is_late).every((o) => o.risk_score >= 90));
  assert.ok(plan.orders.filter((o) => !o.is_late).every((o) => o.risk_score < 90));
});

test('plans are deterministic and batch codes are stable', () => {
  const input = base({ orders: [order('a'), order('b'), order('c')], steps: [step('a', 'embroidery', 90), step('b', 'embroidery', 90), step('c', 'dtf', 45)] });
  assert.deepEqual(buildPlan(input), buildPlan(JSON.parse(JSON.stringify(input))));
  assert.match(buildPlan(input).batches[0].batch_code, /^B20261109-(EMB|DTF)-1-1$/);
});

test('jobs already complete or in progress are not rescheduled', () => {
  const plan = buildPlan(base({ orders: [order('a')], steps: [step('a', 'dtf', 30), step('a', 'embroidery', 60)],
    fixed_steps: [{ order_id: 'a', method_code: 'dtf', status: 'complete' }] }));
  assert.equal(plan.steps.length, 1);
  assert.equal(plan.steps[0].method_code, 'embroidery');
  assert.equal(plan.steps[0].status, 'ready');            // nothing left in front of it
});

test('already-overdue work alone does not declare a bottleneck', () => {
  const plan = buildPlan(base({ orders: [order('o', { due_date: '2026-11-02T00:00:00Z' })], steps: [step('o', 'embroidery', 60)] }));
  assert.equal(plan.bottleneck, null);
  assert.equal(plan.summary.steps_late, 1);               // still reported as late
});

test('DecoNetwork holds (stock, PO, artwork, on hold) block scheduling with a specific reason', () => {
  const plan = buildPlan(base({
    orders: [order('ok', { stock_secured: true }), order('stk', { hold_reason: 'awaiting stock (DecoNetwork status)' }),
             order('art', { hold_reason: 'awaiting artwork (DecoNetwork status)' })],
    steps: [step('ok', 'embroidery', 60), step('stk', 'embroidery', 60), step('art', 'embroidery', 60)] }));
  assert.deepEqual(seq(plan), ['ok']);
  assert.deepEqual(plan.blocked.map((b) => b.reason).sort(), ['awaiting artwork (DecoNetwork status)', 'awaiting stock (DecoNetwork status)']);
});

test('orders whose garments are already secured by DecoNetwork get the stock-ready bonus', () => {
  const plan = buildPlan(base({ orders: [order('a', { stock_secured: true }), order('b')], steps: [step('a', 'embroidery', 60), step('b', 'embroidery', 60)] }));
  assert.equal(plan.steps.find((s) => s.order_id === 'a').score_breakdown.stock_ready, 15);
  assert.equal(plan.steps.find((s) => s.order_id === 'b').score_breakdown.stock_ready, undefined);
});
