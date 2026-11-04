'use strict';
// ATAM_FLOW stock allocation engine v1 (transparent weighted heuristic, no I/O).
// buildAllocationPlan(input) -> plan. Embedded verbatim in the n8n Code node (see scripts/engine-literal.mjs).
// Demand: lines of orders DecoNetwork says are awaiting stock / PO. Supply: free on-hand stock (DecoNetwork level, already net of
// orders DecoNetwork has secured) and outstanding purchase-order units. Exact SKU matching only.
// Method: repeatedly pick the order with the best CURRENT score (urgency + how much of it stock can complete), reserve what it can
// get, and update the pools. Deterministic: ties break on due date then order reference.

const DAY = 86400000;

const DEFAULT_WEIGHTS = {
  due_date: { weight: 30, horizon_days: 14 }, overdue_penalty: { weight: 25, per_day: 2, cap: 25 }, customer_vip: { weight: 15 },
  manual_priority: { high: 8, rush: 20, critical: 40 }, order_value: { weight: 10, cap_value: 2000 }, order_age: { weight: 5, cap_days: 30 },
  completable_bonus: { weight: 20 }, completion_pct: { weight: 10 }, fully_coverable_bonus: { weight: 12 }, stock_scarcity: { weight: 8 },
  production_feasibility: { weight: 10 }, complexity_penalty: { weight: 5, per_stitches: 10000 }
};
const DEFAULT_THRESHOLDS = { hold_if_completable_pct_below: 50, hold_for_urgent_within_days: 2, allow_partial: true, min_partial_units: 1,
  overdue_po_assume_days: 3 };

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
const r1 = (x) => Math.round(x * 10) / 10;
const diffDays = (a, b) => Math.round((Date.parse(a + 'T00:00:00Z') - Date.parse(b + 'T00:00:00Z')) / DAY);
const addDays = (d, n) => new Date(Date.parse(d + 'T00:00:00Z') + n * DAY).toISOString().slice(0, 10);
const fmtDate = (d) => new Intl.DateTimeFormat('en-GB', { timeZone: 'UTC', weekday: 'short', day: '2-digit', month: 'short' }).format(new Date(d + 'T00:00:00Z'));
const itemName = (l) => [l.product_name || l.sku, l.colour, l.size].filter(Boolean).join(' ');

function mergeWeights(w) {
  const out = {};
  for (const k in DEFAULT_WEIGHTS) out[k] = Object.assign({}, DEFAULT_WEIGHTS[k], (w && w[k]) || {});
  return out;
}

// ---- order-level (static) score ----
function baseScore(o, ctx) {
  const W = ctx.W, p = {};
  if (o.days != null) {
    if (o.days < 0) p.overdue = W.overdue_penalty.weight + Math.min(W.overdue_penalty.cap, W.overdue_penalty.per_day * -o.days);
    p.due_date = r1(clamp(1 - Math.max(o.days, 0) / W.due_date.horizon_days, 0, 1) * W.due_date.weight);
  }
  if (o.is_vip) p.vip = W.customer_vip.weight;
  if (o.priority >= 1) p.manual_priority = ({ 1: W.manual_priority.high, 2: W.manual_priority.rush, 3: W.manual_priority.critical })[Math.min(o.priority, 3)];
  if (o.order_value > 0) p.order_value = r1(clamp(o.order_value / W.order_value.cap_value, 0, 1) * W.order_value.weight);
  if (o.order_date) p.order_age = r1(clamp(diffDays(ctx.today, o.order_date.slice(0, 10)) / W.order_age.cap_days, 0, 1) * W.order_age.weight);
  const methods = o.methods || [];
  const feasible = methods.length === 0 ? 0.5 : methods.every((m) => ctx.activeMethods.has(m)) ? 1 : 0.5;
  p.production_feasibility = r1(feasible * W.production_feasibility.weight);
  const stitches = Math.max(0, ...o.lines.map((l) => Number(l.stitches_per_piece || 0)));
  if (stitches > 0) p.complexity = -r1(clamp(stitches / W.complexity_penalty.per_stitches, 0, 1) * W.complexity_penalty.weight);
  return p;
}

// ---- pools with an overlay so an order can be evaluated without consuming anything ----
function makeSim(ctx) {
  const ohUsed = new Map(), poUsed = new Map();
  const ohFree = (sku) => Math.max((ctx.onHand.get(sku) || 0) - (ohUsed.get(sku) || 0), 0);
  const poFree = (p) => Math.max(p.outstanding - (poUsed.get(p.po_line_id) || 0), 0);
  return { ohUsed, poUsed, ohFree, poFree };
}

// Cover one order from the pools. reserveOnHand=false still counts on-hand units as available (the order is being held, not served).
function coverOrder(o, ctx, sim) {
  const lines = [];
  for (const l of o.lines) {
    let need = l.need;
    const ohTake = Math.min(need, sim.ohFree(l.sku));
    if (ohTake > 0) { sim.ohUsed.set(l.sku, (sim.ohUsed.get(l.sku) || 0) + ohTake); }
    need -= ohTake;
    const inc = [];
    for (const p of ctx.poBySku.get(l.sku) || []) {
      if (need <= 0) break;
      const t = Math.min(need, sim.poFree(p));
      if (t > 0) { inc.push({ po_line_id: p.po_line_id, po_number: p.po_number, supplier: p.supplier, qty: t, expected_date: p.expected_date, eta: p.eta, overdue: p.overdue });
        sim.poUsed.set(p.po_line_id, (sim.poUsed.get(p.po_line_id) || 0) + t); need -= t; }
    }
    lines.push({ line: l, on_hand: ohTake, incoming: inc, incoming_qty: inc.reduce((t, x) => t + x.qty, 0), short: need });
  }
  const sum = (f) => lines.reduce((t, x) => t + f(x), 0);
  const total = sum((x) => x.line.need);
  return { lines, total, oh: sum((x) => x.on_hand), inc: sum((x) => x.incoming_qty), short: sum((x) => x.short) };
}

function buildAllocationPlan(input) {
  const now = input.now ? Date.parse(input.now) : Date.now();
  const today = input.today || new Date(now).toISOString().slice(0, 10);
  const st = input.settings || {};
  const W = mergeWeights(st.weights), T = Object.assign({}, DEFAULT_THRESHOLDS, st.thresholds || {});
  const activeMethods = new Set(input.active_methods || []);

  // pools (manual allocations are fixed: they reduce supply and the order's remaining need)
  const onHand = new Map((input.stock || []).map((s) => [s.sku, Math.max(Number(s.on_hand) || 0, 0)]));
  const poLines = (input.incoming || []).map((p) => {
    const overdue = p.expected_date ? diffDays(p.expected_date, today) < 0 : false;
    const eta = p.expected_date ? (overdue ? addDays(today, T.overdue_po_assume_days) : p.expected_date) : addDays(today, 7);
    return { po_line_id: p.po_line_id, po_number: p.po_number, supplier: p.supplier, sku: p.sku, outstanding: Math.max(Number(p.outstanding) || 0, 0),
      expected_date: p.expected_date, eta, overdue };
  });
  const manualByLine = new Map();
  for (const f of input.fixed_allocations || []) {
    manualByLine.set(f.order_line_id, (manualByLine.get(f.order_line_id) || 0) + f.qty);
    if (f.source === 'incoming_po') { const p = poLines.find((x) => x.po_line_id === f.po_line_id); if (p) p.outstanding = Math.max(p.outstanding - f.qty, 0); }
    else onHand.set(f.sku, Math.max((onHand.get(f.sku) || 0) - f.qty, 0));
  }
  const poBySku = new Map();
  for (const p of poLines.sort((a, b) => a.eta.localeCompare(b.eta) || String(a.po_line_id).localeCompare(String(b.po_line_id)))) {
    if (!poBySku.has(p.sku)) poBySku.set(p.sku, []); poBySku.get(p.sku).push(p);
  }
  const supply = new Map();
  for (const [sku, n] of onHand) supply.set(sku, n);
  for (const p of poLines) supply.set(p.sku, (supply.get(p.sku) || 0) + p.outstanding);

  const ctx = { W, T, today, activeMethods, onHand, poBySku, supply };
  const orders = (input.orders || []).map((o) => {
    const lines = (o.lines || []).map((l) => ({ ...l, need: Math.max(Number(l.need) - (manualByLine.get(l.id) || 0), 0) })).filter((l) => l.need > 0 && l.sku);
    const days = o.due_date ? diffDays(o.due_date, today) : null;
    const oo = { ...o, lines, days, priority: Number(o.priority || 0), order_value: Number(o.order_value || 0) };
    oo.base = baseScore(oo, ctx);
    return oo;
  }).filter((o) => o.lines.length);

  const commit = makeSim(ctx);                                       // what has been reserved so far
  const results = [], allocations = [], taken = new Map();
  const remaining = orders.slice();
  let rank = 0;
  while (remaining.length) {
    const ev = remaining.map((o) => ({ o, e: evalWithCommit(o, ctx, commit) }))
      .sort((a, b) => b.e.score - a.e.score || (a.o.days ?? 1e9) - (b.o.days ?? 1e9) || String(a.o.order_ref).localeCompare(String(b.o.order_ref)));
    const { o, e } = ev[0];
    remaining.splice(remaining.indexOf(o), 1);
    rank += 1;
    results.push(decide(o, e, rank, ctx, commit, allocations, taken));
  }

  // shortages across all orders (what still has no stock and no PO): the purchasing list
  const short = new Map();
  for (const r of results) for (const l of r.lines) if (l.short > 0) {
    const k = l.sku; const s = short.get(k) || { sku: k, product_name: l.product_name, colour: l.colour, size: l.size, short: 0, orders: [], earliest_due: null };
    s.short += l.short; if (!s.orders.includes(r.order_ref)) s.orders.push(r.order_ref);
    if (r.due_date && (!s.earliest_due || r.due_date < s.earliest_due)) s.earliest_due = r.due_date;
    short.set(k, s);
  }
  const counts = { allocate: 0, partial: 0, hold: 0, blocked: 0 };
  results.forEach((r) => { counts[r.decision] += 1; });
  const sumAlloc = (src) => allocations.filter((a) => a.source === src).reduce((t, a) => t + a.qty, 0);
  return { version: 'alloc-1', generated_at: new Date(now).toISOString(), today, orders: results, allocations,
    shortages: [...short.values()].sort((a, b) => (a.earliest_due || '9').localeCompare(b.earliest_due || '9') || b.short - a.short),
    summary: { orders_considered: results.length, ...counts, units_allocated_on_hand: sumAlloc('on_hand'), units_reserved_from_po: sumAlloc('incoming_po'),
      units_short: [...short.values()].reduce((t, s) => t + s.short, 0), skus_short: short.size,
      orders_late_risk: results.filter((r) => r.late_risk).length, orders_overdue_unserved: results.filter((r) => r.days != null && r.days < 0 && r.decision !== 'allocate').length,
      notes: ['Exact SKU matching only. On-hand stock is the DecoNetwork level (already net of orders DecoNetwork has secured).'] } };
}

// Evaluate an order against the pools as already committed (a throwaway overlay; nothing is consumed)
function evalWithCommit(o, ctx, commit) {
  const sim = makeSim(ctx);
  for (const [k, v] of commit.ohUsed) sim.ohUsed.set(k, v);
  for (const [k, v] of commit.poUsed) sim.poUsed.set(k, v);
  const cov = coverOrder(o, ctx, sim);
  const W = ctx.W, parts = Object.assign({}, o.base);
  parts.completion_pct = r1((cov.total ? cov.oh / cov.total : 0) * W.completion_pct.weight);
  if (cov.total > 0 && cov.oh === cov.total) parts.completable = W.completable_bonus.weight;
  if (cov.total > 0 && cov.short === 0) parts.fully_coverable = W.fully_coverable_bonus.weight;
  let share = 0;
  for (const x of cov.lines) { const supply = Math.max(ctx.supply.get(x.line.sku) || 0, 1); share += Math.min(1, x.line.need / supply) * x.line.need; }
  if (cov.total > 0) parts.scarcity = -r1((share / cov.total) * W.stock_scarcity.weight);
  let total = 0; for (const k in parts) total += parts[k];
  return { cov, parts, score: r1(total) };
}

function decide(o, e, rank, ctx, commit, allocations, taken) {
  const { T } = ctx, cov = e.cov;
  const pctOh = cov.total ? Math.round((100 * cov.oh) / cov.total) : 0;
  const pctAll = cov.total ? Math.round((100 * (cov.oh + cov.inc)) / cov.total) : 0;
  const urgent = o.days != null && o.days <= T.hold_for_urgent_within_days;
  let reserveOh = false, decision;
  if (cov.oh === cov.total && cov.total > 0) { decision = 'allocate'; reserveOh = true; }
  else if (cov.oh > 0 && T.allow_partial && cov.oh >= T.min_partial_units && (pctOh >= T.hold_if_completable_pct_below || urgent)) { decision = 'partial'; reserveOh = true; }
  else if (cov.oh > 0 || cov.inc > 0) decision = 'hold';
  else decision = 'blocked';

  // commit to the pools
  for (const x of cov.lines) {
    if (reserveOh && x.on_hand > 0) {
      commit.ohUsed.set(x.line.sku, (commit.ohUsed.get(x.line.sku) || 0) + x.on_hand);
      allocations.push({ order_id: o.id, order_line_id: x.line.id, sku: x.line.sku, source: 'on_hand', po_line_id: null, qty: x.on_hand });
      pushTaken(taken, x.line.sku, o, x.on_hand, rank);
    }
    for (const i of x.incoming) {
      commit.poUsed.set(i.po_line_id, (commit.poUsed.get(i.po_line_id) || 0) + i.qty);
      allocations.push({ order_id: o.id, order_line_id: x.line.id, sku: x.line.sku, source: 'incoming_po', po_line_id: i.po_line_id, qty: i.qty, po_number: i.po_number, expected_date: i.expected_date });
      pushTaken(taken, x.line.sku, o, i.qty, rank);
    }
  }

  // projected ready date = slowest line (on-hand now, PO by its ETA); null if any line has no source
  const readyDates = [];
  for (const x of cov.lines) {
    if (x.short > 0) continue;
    const etas = x.incoming.map((i) => i.eta);
    readyDates.push(x.incoming.length ? etas.sort().pop() : ctx.today);
  }
  const allCovered = cov.short === 0 && cov.total > 0;
  const ready = allCovered ? readyDates.sort().pop() : null;
  const lateRisk = !!(allCovered && o.due_date && ready > o.due_date);
  const poOverdue = cov.lines.some((x) => x.incoming.some((i) => i.overdue));
  const sig = cov.lines.map((x) => `${x.line.id}:${reserveOh ? x.on_hand : 0}:${x.incoming.map((i) => i.po_line_id + '=' + i.qty).join(',')}`).join(';');

  const dueText = o.days == null ? 'no due date' : o.days < 0 ? `overdue by ${-o.days} day(s)` : o.days === 0 ? 'due today' : o.days === 1 ? 'due tomorrow' : `due ${fmtDate(o.due_date)}`;
  const why = [dueText];
  if (o.priority >= 2) why.push('RUSH priority'); else if (o.priority === 1) why.push('high priority');
  if (o.is_vip) why.push('VIP customer');
  const shortLines = cov.lines.filter((x) => x.short > 0);
  const missing = shortLines.slice(0, 4).map((x) => `${x.short} × ${itemName(x.line)}`).join(', ') + (shortLines.length > 4 ? ` and ${shortLines.length - 4} more line(s)` : '');
  const poText = (() => {
    const all = cov.lines.flatMap((x) => x.incoming);
    if (!all.length) return '';
    const pos = [...new Set(all.map((i) => i.po_number))].slice(0, 3).join(', ');
    const last = all.map((i) => i.expected_date || '').sort().pop();
    return `${cov.inc} unit(s) reserved from PO ${pos}${last ? ` (latest due ${fmtDate(last)})` : ''}${poOverdue ? ', and some of those POs are overdue' : ''}`;
  })();
  const winners = (() => {
    const names = [];
    for (const x of shortLines) for (const t of taken.get(x.line.sku) || []) if (t.order_ref !== o.order_ref && !names.includes(t.order_ref)) names.push(t.order_ref);
    return names.slice(0, 3);
  })();
  let reason;
  if (decision === 'allocate') reason = `Allocated${rank === 1 ? ' first' : ` (#${rank})`}: ${why.join(', ')}, 100% of stock on hand, completes the full order.`;
  else if (decision === 'partial') reason = `Partial: ${cov.oh} of ${cov.total} unit(s) (${pctOh}%) allocated from stock on hand${urgent && pctOh < T.hold_if_completable_pct_below ? ' because the order is urgent' : ''}; ${why.join(', ')}.` +
    `${poText ? ' ' + poText + '.' : ''}${cov.short ? ` Still short: ${missing}.` : ''}`;
  else if (decision === 'hold') reason = `Held: ${pctOh > 0 && pctOh < T.hold_if_completable_pct_below ? `only ${pctOh}% of required stock is on hand (below ${T.hold_if_completable_pct_below}%)` : `${pctAll}% of the order can be covered`}; ${why.join(', ')}.` +
    `${poText ? ' ' + poText + '.' : ''}${cov.short ? ` No stock or PO for: ${missing}.` : ''}${winners.length ? ` Stock went to higher-ranked orders ${winners.join(', ')}.` : ''}`;
  else reason = `Blocked: missing ${missing}; no stock on hand and no purchase order on the way (${why.join(', ')}).${winners.length ? ` Available stock went to higher-ranked orders ${winners.join(', ')}.` : ''}`;
  if (allCovered && decision !== 'allocate') reason += ` Projected ready ${fmtDate(ready)}${lateRisk ? ', AFTER the due date' : o.due_date ? ', in time for the due date' : ''}.`;

  const actions = [];
  if (decision === 'allocate') actions.push({ type: 'release_in_deconetwork', text: `Stock fully allocated: move ${o.order_ref} to Ready for production in DecoNetwork.` });
  if (decision === 'partial') actions.push({ type: 'partial_release', text: `${cov.oh} unit(s) reserved; the rest is not yet covered.` });
  for (const x of shortLines) actions.push({ type: 'raise_po', sku: x.line.sku, qty: x.short, text: `Order ${x.short} × ${itemName(x.line)} (no stock, no PO).` });
  if (lateRisk) actions.push({ type: 'expedite_po', text: `PO stock is projected ready ${fmtDate(ready)}, after the due date ${fmtDate(o.due_date)}: chase the supplier or tell the customer.` });
  if (poOverdue) actions.push({ type: 'chase_supplier', text: 'One or more POs for this order are past their expected date.' });

  return { order_id: o.id, order_ref: o.order_ref, customer: o.customer, due_date: o.due_date, days: o.days, rank, decision, reason, score: e.score,
    score_breakdown: { ...e.parts, sig, pct_on_hand: pctOh, pct_covered: pctAll, incoming_qty: cov.inc, projected_ready: ready, late_risk: lateRisk },
    qty_required: cov.total, qty_allocated_on_hand: reserveOh ? cov.oh : 0, qty_available_not_reserved: reserveOh ? 0 : cov.oh,
    qty_reserved_incoming: cov.inc, qty_short: cov.short, projected_ready_date: ready, late_risk: lateRisk, po_overdue: poOverdue, actions,
    lines: cov.lines.map((x) => ({ order_line_id: x.line.id, sku: x.line.sku, product_name: x.line.product_name, colour: x.line.colour, size: x.line.size,
      need: x.line.need, on_hand: reserveOh ? x.on_hand : 0, on_hand_available: x.on_hand, incoming_qty: x.incoming_qty,
      incoming: x.incoming.map((i) => ({ po_line_id: i.po_line_id, po_number: i.po_number, qty: i.qty, expected_date: i.expected_date })), short: x.short })) };
}
function pushTaken(taken, sku, o, qty, rank) {
  if (!taken.has(sku)) taken.set(sku, []);
  taken.get(sku).push({ order_ref: o.order_ref, qty, rank });
}

if (typeof module !== 'undefined' && module.exports) module.exports = { buildAllocationPlan };
