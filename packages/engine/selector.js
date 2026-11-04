'use strict';
// ATAM_FLOW supplier and producer selection engine v1 (pure function, no I/O, runs in n8n and in the browser).
// Compares every supplier x production route for one order on landed cost, margin, speed and risk, and explains the recommendation in plain English.
// Anything missing from the input (a cost, a rate) is reported, never guessed: an option with unknown costs is marked incomplete and is not recommended.

const DAY = 86400000;
const DEFAULT_CONFIG = {
  weights: { margin: 50, speed: 25, risk: 25 },
  thresholds: {
    target_margin_pct: 40, min_margin_pct: 15, below_min_margin_penalty: 20,
    due_buffer_days: 2, restock_days: 7, transit_days_each_way: 1, goods_in_days: 1,
    comfortable_slack_days: 7, default_stitches: 5000, default_reliability_pct: 85,
    revenue_includes_vat: false, vat_rate: 0.2, value_on_hand_at: 'replacement'
  },
  risk: { late: 40, tight: 15, tight_slack_days: 2, stock_shortfall: 15, moq_unmet: 10, min_order_unmet: 8, over_capacity: 15, direct_to_producer: 5, unknown_reliability: 5, reliability_weight: 0.3 }
};

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
const r2 = (x) => Math.round(x * 100) / 100;
const r1 = (x) => Math.round(x * 10) / 10;
const diffDays = (a, b) => Math.round((Date.parse(a + 'T00:00:00Z') - Date.parse(b + 'T00:00:00Z')) / DAY);
const addDays = (d, n) => new Date(Date.parse(d + 'T00:00:00Z') + n * DAY).toISOString().slice(0, 10);
const gbp = (x) => (x < 0 ? '-£' : '£') + Math.abs(x).toLocaleString('en-GB', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const num = (x, d = 0) => (x == null || x === '' || isNaN(Number(x)) ? d : Number(x));
const merge = (base, extra) => { const o = {}; for (const k in base) o[k] = Object.assign({}, base[k], (extra && extra[k]) || {}); return o; };

// ---- decoration cost for a set of lines under one rate card ---------------------------------------------------------------
function decorationCost(order, rates, methods, cfg) {
  const parts = []; let total = 0, missing = [];
  for (const m of methods) {
    const lines = order.lines.filter((l) => (l.methods || order.methods || []).includes(m));
    const units = lines.reduce((t, l) => t + l.qty, 0);
    const rate = rates && rates[m];
    if (!rate || rate.unit_price == null) { missing.push(m); continue; }
    let cost = 0;
    if (rate.basis === 'per_1000_stitches') cost = lines.reduce((t, l) => t + l.qty * (num(l.stitches, cfg.thresholds.default_stitches) / 1000) * rate.unit_price, 0);
    else cost = lines.reduce((t, l) => t + l.qty * Math.max(num(l.areas, 1), 1) * rate.unit_price, 0);
    const designs = Math.max(num(order.designs && order.designs[m], 1), 1);
    cost += num(rate.setup_fee) * designs;
    const min = num(rate.min_job_charge);
    const charged = Math.max(cost, units > 0 ? min : 0);
    parts.push({ method: m, units, cost: r2(charged), minimum_applied: charged > cost });
    total += charged;
  }
  return { total: r2(total), parts, missing };
}

// ---- supplier plans ---------------------------------------------------------------------------------------------------------
function supplierDelivery(s, subtotal) {
  return s.free_delivery_over != null && subtotal >= s.free_delivery_over ? 0 : num(s.delivery_cost);
}
function planFor(order, suppliers, picks, cfg, o) {
  // picks: Map<lineId, supplier>; returns a plan object with per-supplier subtotals
  const bySup = new Map(); let blanks = 0, missingCost = 0; const flags = []; let leadDays = 0;
  for (const l of order.lines) {
    if (l.buy <= 0) continue;
    const s = picks.get(l.id); const off = s.offers[l.sku];
    const cost = o.sku_costs && o.sku_costs[l.sku] != null ? Number(o.sku_costs[l.sku]) : off.unit_cost;
    const adj = cost == null ? null : cost * (1 + num(o.supplier_cost_adjust_pct) / 100);
    const e = bySup.get(s.id) || { supplier: s, subtotal: 0, lines: 0, moq_unmet: false, shortfall: false };
    if (adj == null) missingCost += 1; else { e.subtotal += adj * l.buy; blanks += adj * l.buy; }
    e.lines += 1;
    if (off.min_qty && l.buy < off.min_qty) e.moq_unmet = true;
    if (off.stock_available != null && off.stock_available < l.buy) e.shortfall = true;
    leadDays = Math.max(leadDays, num(off.lead_time_days, num(s.lead_time_days, 3)) + (off.stock_available != null && off.stock_available < l.buy ? cfg.thresholds.restock_days : 0));
    bySup.set(s.id, e);
  }
  let delivery = 0;
  for (const e of bySup.values()) {
    e.delivery = supplierDelivery(e.supplier, e.subtotal); delivery += e.delivery;
    if (e.supplier.min_order_value != null && e.subtotal < e.supplier.min_order_value) { e.min_unmet = true; }
  }
  return { suppliers: [...bySup.values()], blanks: r2(blanks), delivery: r2(delivery), lead_days: leadDays, missing_cost_lines: missingCost, flags };
}

function replacementValue(order, suppliers, o) {
  let v = 0, missing = 0;
  for (const l of order.lines) {
    if (l.on_hand_qty <= 0) continue;
    const costs = suppliers.map((s) => s.offers[l.sku] && s.offers[l.sku].unit_cost).filter((c) => c != null);
    const c = o.sku_costs && o.sku_costs[l.sku] != null ? Number(o.sku_costs[l.sku]) : (costs.length ? Math.min(...costs) : null);
    if (c == null) missing += 1; else v += c * l.on_hand_qty;
  }
  return { value: r2(v), missing };
}

// ---- main ---------------------------------------------------------------------------------------------------------------------
function buildSelection(input) {
  const cfg = { weights: Object.assign({}, DEFAULT_CONFIG.weights, (input.config && input.config.weights) || {}),
    thresholds: Object.assign({}, DEFAULT_CONFIG.thresholds, (input.config && input.config.thresholds) || {}),
    risk: Object.assign({}, DEFAULT_CONFIG.risk, (input.config && input.config.risk) || {}) };
  const ov = input.overrides || {};
  const today = input.today || new Date().toISOString().slice(0, 10);
  const mult = ov.qty_multiplier != null ? Number(ov.qty_multiplier) : 1;
  const order = Object.assign({}, input.order);
  order.lines = (order.lines || []).map((l) => {
    const qty = Math.round(num(l.qty) * mult), onHand = Math.min(Math.round(num(l.on_hand_qty) * mult), qty);
    return Object.assign({}, l, { qty, on_hand_qty: onHand, buy: l.need_buy != null ? Math.round(num(l.need_buy) * mult) : qty - onHand });
  }).filter((l) => l.qty > 0);
  const units = order.lines.reduce((t, l) => t + l.qty, 0);
  const methods = [...new Set(order.lines.flatMap((l) => l.methods || order.methods || []))];
  const rejected = [], options = [];
  const revenueRaw = num(ov.revenue != null ? ov.revenue : order.revenue);
  const revenue = r2(cfg.thresholds.revenue_includes_vat ? revenueRaw / (1 + cfg.thresholds.vat_rate) : revenueRaw);
  const suppliers = (input.suppliers || []).filter((s) => s.is_active !== false);
  const buyLines = order.lines.filter((l) => l.buy > 0);

  // 1. supplier plans
  const plans = [];
  if (!buyLines.length) plans.push({ key: 'stock', label: 'Stock already held', plan: { suppliers: [], blanks: 0, delivery: 0, lead_days: 0, missing_cost_lines: 0 }, direct_ok: false });
  else {
    for (const s of suppliers) {
      const lacking = buyLines.filter((l) => !s.offers[l.sku]);
      if (lacking.length) { rejected.push({ what: s.name, reason: 'does not list ' + lacking.length + ' of the ' + buyLines.length + ' SKUs needed (e.g. ' + lacking[0].sku + ')' }); continue; }
      const picks = new Map(buyLines.map((l) => [l.id, s]));
      plans.push({ key: 's:' + s.id, label: s.name, plan: planFor(order, suppliers, picks, cfg, ov), direct_ok: !!s.can_deliver_to_producer });
    }
    // split plan: cheapest listed supplier for each SKU (only if it uses 2+ suppliers and beats every single-source plan on blanks + delivery)
    const picks = new Map(); let ok = true;
    for (const l of buyLines) {
      const cands = suppliers.filter((s) => s.offers[l.sku] && s.offers[l.sku].unit_cost != null);
      if (!cands.length) { ok = false; break; }
      cands.sort((a, b) => a.offers[l.sku].unit_cost - b.offers[l.sku].unit_cost || String(a.id).localeCompare(String(b.id)));
      picks.set(l.id, cands[0]);
    }
    if (ok && new Set([...picks.values()].map((s) => s.id)).size > 1) {
      const sp = planFor(order, suppliers, picks, cfg, ov);
      const best = plans.length ? Math.min(...plans.map((p) => p.plan.blanks + p.plan.delivery)) : Infinity;
      if (sp.blanks + sp.delivery < best) plans.push({ key: 'split:' + sp.suppliers.map((e) => e.supplier.id).sort().join('+'), label: 'Split: ' + sp.suppliers.map((e) => e.supplier.name).join(' + '), plan: sp, direct_ok: false });
    }
  }
  if (!plans.length) rejected.push({ what: 'All suppliers', reason: 'no supplier can cover the SKUs this order needs to buy' });

  // 2. routes
  const routes = [];
  const internal = input.internal || {};
  if (internal.enabled !== false) {
    const unsupported = methods.filter((m) => internal.methods && !internal.methods.includes(m));
    if (unsupported.length) rejected.push({ what: 'In-house', reason: 'not set up for ' + unsupported.join(', ') });
    else routes.push({ type: 'internal', id: 'internal', name: 'In-house' });
  }
  for (const p of input.producers || []) {
    if (p.is_active === false) continue;
    const cant = methods.filter((m) => !(p.capable_methods || []).includes(m));
    if (cant.length) { rejected.push({ what: p.name, reason: 'cannot do ' + cant.join(', ') }); continue; }
    routes.push({ type: 'producer', id: p.id, name: p.name, producer: p });
  }
  if (!routes.length) rejected.push({ what: 'All production routes', reason: 'nobody can do ' + (methods.join(', ') || 'the required decoration') });

  // 3. combine
  const repl = cfg.thresholds.value_on_hand_at === 'replacement' ? replacementValue(order, suppliers, ov) : { value: 0, missing: 0 };
  const t = cfg.thresholds, R = cfg.risk;
  const due = order.due_date || null;
  for (const pl of plans) for (const rt of routes) for (const direct of rt.type === 'producer' && pl.direct_ok && buyLines.length ? [false, true] : [false]) {
    const p = rt.producer;
    const rates = rt.type === 'internal' ? merge(internal.rates || {}, ov.rates && ov.rates.internal) : merge(p.rates || {}, ov.rates && ov.rates[p.id]);
    const dec = decorationCost(order, rates, methods, cfg);
    const out = rt.type === 'producer' && !direct ? num(p.cost_out) : 0;
    const back = rt.type === 'producer' && !order.prefer_direct_dispatch ? num(p.cost_back) : 0;
    const blanksCost = pl.plan.blanks + repl.value;
    const total = r2(blanksCost + pl.plan.delivery + dec.total + out + back);
    const noMethod = methods.length === 0, noRevenue = !(revenue > 0);
    const incomplete = pl.plan.missing_cost_lines > 0 || repl.missing > 0 || dec.missing.length > 0 || noMethod || noRevenue;
    const profit = r2(revenue - total), margin = revenue > 0 ? r1((profit / revenue) * 100) : null;

    const supplierDays = buyLines.length ? pl.plan.lead_days : 0;
    let prodDays, transitDays = 0;
    if (rt.type === 'internal') prodDays = num(internal.queue_days, 1) + Math.ceil(units / Math.max(num(internal.units_per_day, 150), 1));
    else { prodDays = num(p.turnaround_days, 3); transitDays = t.transit_days_each_way * ((direct ? 0 : 1) + (order.prefer_direct_dispatch ? 0 : 1)); }
    const goodsIn = buyLines.length && !direct ? t.goods_in_days : 0;
    const totalDays = Math.ceil(supplierDays + goodsIn + transitDays + prodDays);
    const ready = addDays(today, totalDays);
    const slack = due ? diffDays(due, ready) - t.due_buffer_days : null;

    const flags = []; let risk = 0;
    if (slack != null && slack < 0) { risk += R.late; flags.push({ code: 'late', text: 'would be ready ' + Math.abs(slack) + ' day(s) after the dispatch deadline' }); }
    else if (slack != null && slack < R.tight_slack_days) { risk += R.tight; flags.push({ code: 'tight', text: 'only ' + slack + ' day(s) spare' }); }
    for (const e of pl.plan.suppliers) {
      if (e.shortfall) { risk += R.stock_shortfall; flags.push({ code: 'supplier_stock', text: e.supplier.name + ' may not have enough stock (assumed +' + t.restock_days + ' days to restock)' }); }
      if (e.moq_unmet) { risk += R.moq_unmet; flags.push({ code: 'moq', text: e.supplier.name + ': below minimum order quantity on a line' }); }
      if (e.min_unmet) { risk += R.min_order_unmet; flags.push({ code: 'min_order', text: e.supplier.name + ': order is below their minimum order value' }); }
      const rel = e.supplier.on_time_rate; risk += rel == null ? R.unknown_reliability : (100 - rel) * R.reliability_weight;
      if (rel == null) flags.push({ code: 'unknown_supplier_reliability', text: e.supplier.name + ': no delivery record yet' });
    }
    if (rt.type === 'producer') {
      const rel = p.on_time_rate; risk += rel == null ? R.unknown_reliability : (100 - rel) * R.reliability_weight;
      if (rel == null) flags.push({ code: 'unknown_producer_reliability', text: p.name + ': no performance record yet' });
      if (p.weekly_capacity_units && num(p.open_units) + units > p.weekly_capacity_units) { risk += R.over_capacity; flags.push({ code: 'over_capacity', text: p.name + ' would be over its weekly capacity' }); }
      if (direct) { risk += R.direct_to_producer; flags.push({ code: 'direct_to_producer', text: 'goods go straight to the producer, so we cannot check them in first' }); }
    } else if (internal.weekly_capacity_units && num(internal.open_units) + units > internal.weekly_capacity_units) {
      risk += R.over_capacity; flags.push({ code: 'over_capacity', text: 'in-house production would be over its weekly capacity' });
    }
    if (margin != null && margin < t.min_margin_pct) flags.push({ code: 'low_margin', text: 'margin ' + margin + '% is below the ' + t.min_margin_pct + '% minimum' });
    if (noMethod) flags.push({ code: 'no_decoration_method', text: 'the order has no decoration method recorded, so decoration cannot be priced' });
    if (noRevenue) flags.push({ code: 'no_revenue', text: 'the order has no value, so margin cannot be worked out' });
    if (incomplete) flags.push({ code: 'incomplete', text: 'some costs are missing' + (dec.missing.length ? ' (no rate for ' + dec.missing.join(', ') + ')' : '') + (pl.plan.missing_cost_lines ? ' (' + pl.plan.missing_cost_lines + ' blank cost(s) unknown)' : '') });
    risk = r1(clamp(risk, 0, 100));

    const mScore = margin == null ? 0 : clamp((margin - t.min_margin_pct) / Math.max(t.target_margin_pct - t.min_margin_pct, 1), 0, 1);
    const sScore = slack == null ? 0.5 : slack < 0 ? 0 : clamp(slack / t.comfortable_slack_days, 0, 1);
    const parts = { margin: r1(mScore * cfg.weights.margin), speed: r1(sScore * cfg.weights.speed), risk: r1((1 - risk / 100) * cfg.weights.risk) };
    const penalty = margin != null && margin < t.min_margin_pct ? t.below_min_margin_penalty : 0;
    const score = r1(parts.margin + parts.speed + parts.risk - penalty);

    options.push({
      key: pl.key + '|' + rt.type + ':' + rt.id + (direct ? '|direct' : ''),
      supplier_plan: pl.label, suppliers: pl.plan.suppliers.map((e) => ({ id: e.supplier.id, name: e.supplier.name, subtotal: r2(e.subtotal), delivery: r2(e.delivery) })),
      route: { type: rt.type, id: rt.id, name: rt.name, supplier_direct_to_producer: direct },
      costs: { blanks: r2(pl.plan.blanks), stock_on_hand_value: repl.value, supplier_delivery: pl.plan.delivery, decoration: dec.total, decoration_parts: dec.parts, transport_to_producer: out, transport_back: back, total },
      revenue, profit, margin_pct: margin, cost_per_unit: units ? r2(total / units) : null, profit_per_unit: units ? r2(profit / units) : null,
      timeline: { supplier_days: supplierDays, goods_in_days: goodsIn, transit_days: transitDays, production_days: prodDays, total_days: totalDays, ready_date: ready, slack_days: slack },
      risk: { score: risk, flags }, score_parts: Object.assign(parts, { penalty: -penalty }), score, incomplete, late: slack != null && slack < 0
    });
  }

  // 4. rank, label, recommend
  const rank = (a, b) => b.score - a.score || a.costs.total - b.costs.total || a.key.localeCompare(b.key);
  options.sort(rank);
  const complete = options.filter((o) => !o.incomplete);
  const eligible = complete.filter((o) => !o.late);
  const pool = eligible.length ? eligible : complete.length ? complete : [];
  const rec = pool[0] || null;
  const pick = (arr, f) => arr.slice().sort((a, b) => f(a) - f(b) || rank(a, b))[0];
  const labels = new Map();
  const tag = (o, l) => { if (o) labels.set(o.key, (labels.get(o.key) || []).concat(l)); };
  if (complete.length) { tag(pick(complete, (o) => o.costs.total), 'Cheapest'); tag(pick(complete, (o) => o.timeline.total_days), 'Fastest'); tag(pick(complete, (o) => o.risk.score), 'Safest'); }
  if (rec) tag(rec, 'Recommended');
  for (const o of options) { o.labels = labels.get(o.key) || []; o.eligible = !o.incomplete && !o.late; }

  let explanation;
  if (!options.length) explanation = 'No option could be built: ' + (rejected.map((r) => r.what + ' ' + r.reason).join('; ') || 'no suppliers or production routes were supplied') + '.';
  else if (!rec) explanation = 'Every option has missing costs, so none can be recommended yet. Add the missing rates or supplier costs (see the flags on each option).';
  else {
    const name = (o) => o.supplier_plan + ' + ' + o.route.name + (o.route.supplier_direct_to_producer ? ' (delivered straight to the producer)' : '');
    const bits = [`Recommended: ${name(rec)}.`,
      `Total cost ${gbp(rec.costs.total)} (${gbp(rec.cost_per_unit)} a unit) against revenue ${gbp(rec.revenue)}: profit ${gbp(rec.profit)}${rec.margin_pct != null ? ' (' + rec.margin_pct + '% margin)' : ''}.`];
    if (rec.timeline.slack_days != null) bits.push(`Ready ${rec.timeline.ready_date}, ${rec.timeline.slack_days >= 0 ? rec.timeline.slack_days + ' day(s) spare before the dispatch deadline' : Math.abs(rec.timeline.slack_days) + ' day(s) after the dispatch deadline'}.`);
    const next = pool[1];
    if (next) {
      const dC = r2(next.costs.total - rec.costs.total), dD = next.timeline.total_days - rec.timeline.total_days;
      const why = [];
      if (dC > 0.005) why.push(`${gbp(dC)} cheaper`); else if (dC < -0.005) why.push(`${gbp(-dC)} dearer`);
      if (dD > 0) why.push(`${dD} day(s) faster`); else if (dD < 0) why.push(`${-dD} day(s) slower`);
      const dR = r1(next.risk.score - rec.risk.score);
      if (dR > 0.5) why.push('lower risk'); else if (dR < -0.5) why.push('higher risk');
      bits.push(`Runner-up ${name(next)} (${gbp(next.costs.total)}, score ${next.score} vs ${rec.score}); the recommendation is ${why.length ? why.join(', ') : 'about the same'} compared with it.`);
    }
    const cheapest = pick(complete, (o) => o.costs.total);
    if (cheapest && cheapest.key !== rec.key) bits.push(`The cheapest option is ${name(cheapest)} at ${gbp(cheapest.costs.total)}, but it ${cheapest.late ? 'would miss the due date' : 'scores lower once speed and risk are counted'}.`);
    if (!eligible.length) bits.push('No option meets the due date; this is the best of the late options.');
    if (rec.risk.flags.length) bits.push('Watch: ' + rec.risk.flags.map((f) => f.text).join('; ') + '.');
    explanation = bits.join(' ');
  }
  const forced = ov.force ? options.find((o) => (!ov.force.supplier_id || o.suppliers.some((s) => s.id === ov.force.supplier_id) || o.key.startsWith('stock')) && (!ov.force.route_id || o.route.id === ov.force.route_id)) : null;
  return {
    version: 'sel-1', order_id: order.id, order_ref: order.order_ref, today, units, revenue, methods,
    options, rejected, recommended_key: rec ? rec.key : null, selected_key: forced ? forced.key : rec ? rec.key : null,
    selected_differs_from_recommended: !!(forced && rec && forced.key !== rec.key),
    explanation, summary: { options: options.length, complete: complete.length, eligible: eligible.length, rejected: rejected.length }
  };
}

if (typeof module !== 'undefined' && module.exports) module.exports = { buildSelection, DEFAULT_CONFIG };
