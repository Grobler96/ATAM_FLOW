'use strict';
// ATAM_FLOW production scheduler v1 (transparent weighted heuristic, no I/O).
// buildPlan(input) -> plan. Same file is embedded verbatim in the n8n Code node (see docs/scoring-and-sequencing.md).
// Method: score every (order x decoration method) job, then simulate each machine's working calendar, repeatedly
// placing the best READY job (urgency + continuity bonus - changeover penalty). Deterministic: ties break on job key.

const MIN = 60000, HOUR = 3600000, DAY = 86400000;

const DEFAULT_WEIGHTS = {
  due_date: { weight: 30, horizon_days: 14 }, overdue_bonus: 30, rush_bonus: 20, vip_bonus: 8,
  stock_ready_bonus: 15, critical_ratio_bonus: 15, same_colour_bonus: 6, same_design_bonus: 8,
  batch_compat_bonus: 5, changeover_penalty_per_min: 0.3, long_job_early_start: { weight: 10, hours: 4 },
  pin_boost: 10000
};
const DEFAULT_OPTIONS = {
  timezone: 'Europe/London', horizon_days: 14, stock_gate: 'ignore', batch_max_changeover_min: 5,
  bottleneck_utilisation: 0.85, blocked_statuses: ['missing', 'pending', 'awaiting', 'rejected', 'awaiting_approval'],
  method_order: ['screen_print', 'dtg', 'vinyl', 'dtf', 'uv', 'heat_press', 'embroidery', 'packing']
};

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
const round1 = (x) => Math.round(x * 10) / 10;
const iso = (ms) => (ms == null ? null : new Date(ms).toISOString());
const intersects = (a, b) => (a || []).some((x) => (b || []).includes(x));

// ---------- time zone / working calendar ----------
function localParts(ts, tz) {
  const f = new Intl.DateTimeFormat('en-GB', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short' });
  const o = {};
  for (const p of f.formatToParts(new Date(ts))) o[p.type] = p.value;
  return { y: +o.year, m: +o.month, d: +o.day, h: +o.hour, mi: +o.minute,
           wd: { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 }[o.weekday] };
}
function zonedToUtc(y, m, d, h, mi, tz) {
  const target = Date.UTC(y, m - 1, d, h, mi);
  let guess = target;
  for (let i = 0; i < 2; i++) {
    const p = localParts(guess, tz);
    guess += target - Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi);
  }
  return guess;
}
const toMinutes = (t) => { const [h, m] = String(t).split(':'); return (+h) * 60 + (+m); };
function buildWindows(shifts, now, tz, days) {
  const p = localParts(now, tz), out = [];
  for (let k = 0; k < days; k++) {
    const dt = new Date(Date.UTC(p.y, p.m - 1, p.d + k));
    const y = dt.getUTCFullYear(), m = dt.getUTCMonth() + 1, d = dt.getUTCDate(), wd = ((dt.getUTCDay() + 6) % 7) + 1;
    for (const s of shifts) {
      if (s.weekday !== wd) continue;
      out.push({ s: zonedToUtc(y, m, d, Math.floor(s.sm / 60), s.sm % 60, tz), e: zonedToUtc(y, m, d, Math.floor(s.em / 60), s.em % 60, tz) });
    }
  }
  return out.sort((a, b) => a.s - b.s);
}
// Consume `minutes` of working time starting no earlier than `from`. Jobs may pause overnight/weekends.
function place(wins, from, minutes) {
  let rem = minutes, start = null, cur = from;
  for (const w of wins) {
    if (w.e <= cur) continue;
    const st = Math.max(cur, w.s);
    if (start === null) start = st;
    const use = Math.min((w.e - st) / MIN, rem);
    rem -= use; cur = st + use * MIN;
    if (rem <= 1e-9) return { start, end: cur };
  }
  return null;
}
const nextWorking = (wins, from) => { const r = place(wins, from, 0); return r ? r.start : null; };

// ---------- scoring ----------
function urgency(job, ctx) {
  const W = ctx.W, now = ctx.now, parts = {};
  if (job.dueEnd != null) {
    const days = (job.dueEnd - now) / DAY;
    if (days < 0) parts.overdue = W.overdue_bonus + Math.min(10, Math.ceil(-days));
    parts.due_date = round1(clamp(1 - Math.max(days, 0) / W.due_date.horizon_days, 0, 1) * W.due_date.weight);
    const need = job.order_remaining_min * MIN * 3;      // elapsed time is roughly 3x work time on 8h shifts
    if (need > 0 && days >= 0) parts.critical_ratio = round1(W.critical_ratio_bonus * clamp(1 - (job.dueEnd - now) / need, 0, 1));
    const hrs = job.run_min / 60;
    if (hrs >= W.long_job_early_start.hours && days <= W.due_date.horizon_days)
      parts.long_job = round1(W.long_job_early_start.weight * clamp(hrs / (W.long_job_early_start.hours * 4), 0, 1));
  }
  if (job.priority >= 1) parts.priority = ({ 1: 0.4, 2: 1, 3: 2 }[Math.min(job.priority, 3)]) * W.rush_bonus;
  if (job.vip) parts.vip = W.vip_bonus;
  if (job.alloc_state === 'full' || job.stock_secured) parts.stock_ready = W.stock_ready_bonus;   // garments already secured
  let total = 0;
  for (const k in parts) total += parts[k];
  return { total: round1(total), parts };
}

function changeover(prev, job, method, rules) {
  if (!prev) return { min: Number(method.setup_minutes || 0), why: ['first job on machine: setup'], sameCustomer: false, sameColour: false, sameType: false };
  const r = rules[job.method] || {}, why = [];
  const sameCustomer = prev.customer === job.customer;
  const sameColour = intersects(prev.colours, job.colours);
  const sameType = intersects(prev.garment_types, job.garment_types);
  let min = 0;
  const add = (type, cond) => { if (cond && r[type]) { min += r[type]; why.push(`${type.replace('_', ' ')} +${r[type]}m`); } };
  add('design', !sameCustomer);                 // proxy: different customer = different artwork
  add('thread_colour', !sameCustomer);          // proxy until thread colours are captured
  add('ink_colour', !sameCustomer);
  add('garment_colour', !sameColour);
  add('garment_type', !sameType);
  return { min, why, sameCustomer, sameColour, sameType };
}

// ---------- jobs ----------
function buildJobs(input, S) {
  const orders = new Map((input.orders || []).map((o) => [o.id, o]));
  const fixed = new Map((input.fixed_steps || []).map((f) => [f.order_id + '|' + f.method_code, f]));
  const pins = new Map((input.overrides || []).map((p) => [p.order_id + '|' + (p.method_code || ''), p]));
  const activeMethods = new Set((input.machines || []).filter((m) => m.is_active).map((m) => m.method_code));
  const orderIdx = (m) => { const i = S.method_order.indexOf(m); return i < 0 ? 999 : i; };
  const byOrder = new Map();
  for (const s of input.steps || []) {
    const f = fixed.get(s.order_id + '|' + s.method_code);
    if (f && (f.status === 'complete' || f.status === 'in_progress')) continue;
    if (!orders.has(s.order_id)) continue;
    if (!byOrder.has(s.order_id)) byOrder.set(s.order_id, []);
    byOrder.get(s.order_id).push(s);
  }
  const jobs = [];
  for (const [oid, steps] of byOrder) {
    const o = orders.get(oid);
    steps.sort((a, b) => orderIdx(a.method_code) - orderIdx(b.method_code) || a.method_code.localeCompare(b.method_code));
    const remaining = steps.reduce((t, s) => t + Number(s.run_min || 0), 0);
    let dueEnd = null;
    if (o.due_date) { const p = localParts(Date.parse(o.due_date), S.timezone); dueEnd = zonedToUtc(p.y, p.m, p.d, 23, 59, S.timezone); }
    let orderBlock = null;
    if (o.hold_reason) orderBlock = o.hold_reason;           // DecoNetwork status: on hold / awaiting stock / PO / artwork
    else if (o.order_status === 'on_hold') orderBlock = 'order is on hold';
    else if (o.order_status === 'blocked') orderBlock = 'order is blocked';
    else if (S.blocked_statuses.includes(String(o.artwork_status || '').toLowerCase())) orderBlock = `artwork ${o.artwork_status}`;
    else if (S.blocked_statuses.includes(String(o.proof_status || '').toLowerCase())) orderBlock = `proof ${o.proof_status}`;
    else if (S.stock_gate === 'require_allocation' && o.alloc_state !== 'full') orderBlock = 'waiting on stock allocation';
    steps.forEach((s, i) => {
      const pin = pins.get(oid + '|' + s.method_code) || pins.get(oid + '|');
      jobs.push({
        key: oid + '|' + s.method_code, order_id: oid, order_ref: o.order_ref, customer: o.customer_name || '', method: s.method_code,
        units: Number(s.units || 0), run_min: Number(s.run_min || 0), colours: s.colours || [], garment_types: s.garment_types || [],
        dueEnd, priority: Number(o.priority || 0), vip: !!o.is_vip, alloc_state: o.alloc_state, stock_secured: !!o.stock_secured, step_index: i,
        dep: i > 0 ? oid + '|' + steps[i - 1].method_code : null, order_remaining_min: remaining,
        blocked: orderBlock || (activeMethods.has(s.method_code) ? null : `no active machine for ${s.method_code}`),
        pin_rank: pin ? Number(pin.pin_rank || 1) : null, pin_note: pin ? pin.note : null, pin_by: pin ? pin.set_by : null
      });
    });
  }
  const byKey = new Map(jobs.map((j) => [j.key, j]));
  for (const j of jobs) {                                  // a blocked step blocks everything after it
    let d = j.dep;
    while (!j.blocked && d) { const dj = byKey.get(d); if (dj && dj.blocked) j.blocked = `waiting on blocked ${dj.method} step (${dj.blocked})`; d = dj ? dj.dep : null; }
  }
  return jobs;
}

// ---------- simulation ----------
function simulate(jobs, ctx, usePins) {
  const { S, W, now, machines, rules, methods, winsByMachine } = ctx;
  const placed = new Map();
  const mstate = machines.filter((m) => m.is_active).sort((a, b) => a.code.localeCompare(b.code)).map((m) => ({
    m, wins: winsByMachine.get(m.id), cursor: Math.max(now, m.busy_until ? Date.parse(m.busy_until) : now), last: null, seq: [] }));
  const pending = jobs.filter((j) => !j.blocked).sort((a, b) => a.key.localeCompare(b.key));
  const urg = new Map(pending.map((j) => [j.key, urgency(j, ctx)]));
  while (pending.length) {
    let pick = null;
    for (const ms of mstate) {
      const cands = [];
      for (const j of pending) {
        if (j.method !== ms.m.method_code) continue;
        let ready = now;
        if (j.dep) { const d = placed.get(j.dep); if (!d) continue; if (d.blocked) { cands.push({ j, start: Infinity, blocked: d }); continue; } ready = d.end; }
        const st = nextWorking(ms.wins, Math.max(ms.cursor, ready));
        cands.push({ j, start: st == null ? Infinity : st });
      }
      if (!cands.length) continue;
      const min = Math.min(...cands.map((c) => c.start));
      if (min === Infinity) { const c = cands[0]; pick = { ms, c, noCapacity: true, start: Infinity }; break; }
      const pool = cands.filter((c) => c.start === min).map((c) => {
        const co = changeover(ms.last && ms.last.job, c.j, methods.get(ms.m.method_code) || {}, rules);
        let adj = urg.get(c.j.key).total - W.changeover_penalty_per_min * co.min;
        if (ms.last) adj += (co.sameCustomer ? W.same_design_bonus : 0) + (co.sameColour ? W.same_colour_bonus : 0) + (co.sameType ? W.batch_compat_bonus : 0);
        if (usePins && c.j.pin_rank != null) adj += W.pin_boost - c.j.pin_rank;
        return { c, co, adj };
      }).sort((a, b) => b.adj - a.adj || a.c.j.key.localeCompare(b.c.j.key));
      if (!pick || min < pick.start) pick = { ms, c: pool[0].c, co: pool[0].co, adj: pool[0].adj, start: min };
    }
    if (!pick) { for (const j of pending) placed.set(j.key, { job: j, blocked: 'dependency could not be scheduled' }); break; }
    const { ms, c } = pick, j = c.j;
    pending.splice(pending.indexOf(j), 1);
    if (pick.noCapacity) { placed.set(j.key, { job: j, blocked: 'no machine capacity within the planning window' }); continue; }
    const ready = j.dep ? placed.get(j.dep).end : now;
    const r = place(ms.wins, Math.max(ms.cursor, ready), pick.co.min + j.run_min);
    if (!r) { placed.set(j.key, { job: j, blocked: 'no machine capacity within the planning window' }); continue; }
    const rec = { job: j, machine: ms.m, start: r.start, end: r.end, setup_min: pick.co.min, co: pick.co, adj: pick.adj, prev: ms.last && ms.last.job, urg: urg.get(j.key) };
    placed.set(j.key, rec); ms.seq.push(rec); ms.cursor = r.end; ms.last = rec;
  }
  for (const j of jobs) if (j.blocked) placed.set(j.key, { job: j, blocked: j.blocked });
  return { placed, mstate };
}

// ---------- output ----------
function fmtDay(ms, tz) { return new Intl.DateTimeFormat('en-GB', { timeZone: tz, weekday: 'short', day: '2-digit', month: 'short' }).format(new Date(ms)); }
function fmtTime(ms, tz) { return new Intl.DateTimeFormat('en-GB', { timeZone: tz, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(ms)); }

function reasonFor(r, pos, ctx) {
  const { S, now } = ctx, j = r.job, bits = [];
  if (j.dueEnd != null) {
    const days = (j.dueEnd - now) / DAY;
    if (days < 0) bits.push(`overdue by ${Math.ceil(-days)} day(s)`);
    else if (days < 1) bits.push('due today');
    else bits.push(`due ${fmtDay(j.dueEnd, S.timezone)}`);
  } else bits.push('no due date');
  if (j.pin_rank != null) bits.push(`PINNED by ${j.pin_by || 'a manager'}${j.pin_note ? ': ' + j.pin_note : ''}`);
  if (j.priority >= 2) bits.push('RUSH priority'); else if (j.priority === 1) bits.push('high priority');
  if (j.vip) bits.push('VIP customer');
  if (r.urg.parts.long_job) bits.push(`large job (${round1(j.run_min / 60)} h) started early`);
  if (r.urg.parts.critical_ratio > 5) bits.push('little slack for the work remaining');
  if (j.step_index > 0) bits.push(`runs after the previous process step (ends ${fmtTime(ctx.placed.get(j.dep).end, S.timezone)})`);
  if (r.prev) {
    if (r.co.min === 0) bits.push('no changeover: same customer, colour and garment type as the previous job');
    else if (r.co.sameCustomer || r.co.sameColour) bits.push(`kept close to related work (changeover ${r.co.min} min)`);
    else bits.push(`changeover ${r.co.min} min (${r.co.why.join(', ')})`);
  }
  const late = j.dueEnd != null && r.end > j.dueEnd;
  if (late) bits.push('PREDICTED LATE: finishes after the due date');
  return `#${pos} on ${r.machine.code}: ` + bits.join('; ') + '.';
}

function riskScore(finish, dueEnd, now, blocked) {
  let s;
  if (dueEnd == null) s = 10;
  else if (dueEnd < now) s = 95 + Math.min(5, Math.ceil((now - dueEnd) / DAY));
  else { const slack = (dueEnd - finish) / HOUR; s = slack <= 0 ? 90 : slack < 24 ? 70 : slack < 72 ? 45 : slack < 168 ? 25 : 10; }
  if (blocked && dueEnd != null && (dueEnd - now) / DAY <= 7) s = Math.max(s, 70); else if (blocked) s = Math.max(s, 40);
  return s;
}

function buildPlan(input) {
  const now = input.now ? Date.parse(input.now) : Date.now();
  const opt = Object.assign({}, DEFAULT_OPTIONS, (input.settings && input.settings.options) || {});
  const wIn = (input.settings && input.settings.weights) || {};
  const W = Object.assign({}, DEFAULT_WEIGHTS, wIn);
  W.due_date = Object.assign({}, DEFAULT_WEIGHTS.due_date, wIn.due_date || {});
  W.long_job_early_start = Object.assign({}, DEFAULT_WEIGHTS.long_job_early_start, wIn.long_job_early_start || {});
  const S = { timezone: opt.timezone, stock_gate: opt.stock_gate, blocked_statuses: opt.blocked_statuses, method_order: (input.settings && input.settings.method_order) || opt.method_order };
  const horizon = Number((input.settings && input.settings.horizon_days) || opt.horizon_days);
  W.due_date.horizon_days = W.due_date.horizon_days || horizon;

  const machines = input.machines || [], methods = new Map((input.methods || []).map((m) => [m.code, m]));
  const rules = {};
  for (const r of input.changeover || []) (rules[r.method_code] = rules[r.method_code] || {})[r.change_type] = Number(r.minutes);
  const allShifts = (input.shifts || []).map((s) => ({ machine_id: s.machine_id, weekday: s.weekday, sm: toMinutes(s.start_time), em: toMinutes(s.end_time) }));
  const winsByMachine = new Map();
  for (const m of machines) {
    const own = allShifts.filter((s) => s.machine_id === m.id);
    winsByMachine.set(m.id, buildWindows(own.length ? own : allShifts.filter((s) => s.machine_id == null), now, S.timezone, 75));
  }
  const ctx = { S, W, now, machines, rules, methods, winsByMachine, placed: null };
  const jobs = buildJobs(input, S);
  const hasPins = jobs.some((j) => j.pin_rank != null);

  const order = (sim) => [...sim.placed.values()].filter((r) => r.machine).sort((a, b) => a.start - b.start || a.machine.code.localeCompare(b.machine.code) || a.job.key.localeCompare(b.job.key));
  const rec = hasPins ? simulate(jobs, ctx, false) : null;
  const fin = simulate(jobs, ctx, true);
  ctx.placed = fin.placed;
  const recPos = new Map(); if (rec) order(rec).forEach((r, i) => recPos.set(r.job.key, i + 1));

  const ordered = order(fin), posOf = new Map(ordered.map((r, i) => [r.job.key, i + 1]));
  const steps = [];
  for (const r of fin.placed.values()) {
    const j = r.job;
    if (!r.machine) { steps.push({ order_id: j.order_id, method_code: j.method, step_no: j.step_index + 1, units: j.units, est_minutes: j.run_min, machine_id: null, blocked_reason: r.blocked, status: 'blocked', reason: `Blocked: ${r.blocked}.` }); continue; }
    const pos = posOf.get(j.key), late = j.dueEnd != null && r.end > j.dueEnd;
    steps.push({ order_id: j.order_id, method_code: j.method, step_no: j.step_index + 1, units: j.units, est_minutes: j.run_min, setup_minutes: r.setup_min,
      machine_id: r.machine.id, machine_code: r.machine.code, planned_start: iso(r.start), planned_end: iso(r.end), score: r.adj,
      score_breakdown: Object.assign({}, r.urg.parts, { changeover_min: r.setup_min, selection_score: round1(r.adj) }),
      reason: reasonFor(r, pos, ctx), sequence_position: pos, recommended_position: recPos.get(j.key) || pos, is_late: late, blocked_reason: null,
      status: j.step_index === 0 ? 'ready' : 'pending' });
  }
  steps.sort((a, b) => (a.sequence_position || 1e9) - (b.sequence_position || 1e9) || (a.order_id + a.method_code).localeCompare(b.order_id + b.method_code));

  // batches: consecutive jobs on one machine with a small changeover between them
  const batches = [];
  for (const ms of fin.mstate) {
    let cur = null, n = 0, lastDay = null;
    for (const r of ms.seq) {
      const day = fmtDay(r.start, S.timezone);
      const joins = cur && r.co.min <= opt.batch_max_changeover_min && r.prev;
      if (!joins) {
        n = day === lastDay ? n + 1 : 1; lastDay = day;
        const p = localParts(r.start, S.timezone), ymd = `${p.y}${String(p.m).padStart(2, '0')}${String(p.d).padStart(2, '0')}`;
        cur = { batch_code: `B${ymd}-${ms.m.code}-${n}`, method_code: ms.m.method_code, machine_id: ms.m.id, _jobs: [] };
        batches.push(cur);
      }
      cur._jobs.push(r);
      for (const st of steps) if (st.order_id === r.job.order_id && st.method_code === r.job.method) st.batch_code = cur.batch_code;
    }
  }
  const lateByMethod = {};                    // capacity-caused lateness only: work already overdue before planning is not a bottleneck signal
  for (const r of fin.placed.values()) if (r.machine && r.job.dueEnd != null && r.job.dueEnd >= now && r.end > r.job.dueEnd) lateByMethod[r.job.method] = (lateByMethod[r.job.method] || 0) + 1;
  const horizonEnd = now + horizon * DAY;
  const util = {};
  for (const [mid, wins] of winsByMachine) {
    const m = machines.find((x) => x.id === mid); if (!m || !m.is_active) continue;
    const cap = wins.reduce((t, w) => t + Math.max(0, Math.min(w.e, horizonEnd) - Math.max(w.s, now)) / MIN, 0);
    (util[m.method_code] = util[m.method_code] || { cap: 0, demand: 0 }).cap += cap;
  }
  for (const r of fin.placed.values()) {
    if (!r.machine || !util[r.machine.method_code]) continue;
    const frac = r.end > r.start ? clamp((Math.min(r.end, horizonEnd) - r.start) / (r.end - r.start), 0, 1) : (r.start < horizonEnd ? 1 : 0);
    util[r.machine.method_code].demand += (r.setup_min + r.job.run_min) * frac;
  }
  const utilisation = {};
  let bn = null;
  for (const m in util) {
    const u = util[m].cap > 0 ? util[m].demand / util[m].cap : 0;
    utilisation[m] = { utilisation: round1(u * 100) / 100, demand_min: Math.round(util[m].demand), capacity_min: Math.round(util[m].cap), late_jobs: lateByMethod[m] || 0 };
    const score = u + 0.1 * (lateByMethod[m] || 0);
    if ((u >= opt.bottleneck_utilisation || lateByMethod[m]) && (!bn || score > bn.score)) bn = { method: m, score };
  }
  const bottleneck = bn ? { method: bn.method, ...utilisation[bn.method],
    suggestion: `${(methods.get(bn.method) || {}).name || bn.method} is the bottleneck: ${Math.round(utilisation[bn.method].utilisation * 100)}% of capacity over ${horizon} days` +
      `${utilisation[bn.method].late_jobs ? ` and ${utilisation[bn.method].late_jobs} job(s) predicted late` : ''}. Options: add hours or a machine, or re-prioritise the latest-due work.` } : null;

  for (const b of batches) {
    const rs = b._jobs, ids = [...new Set(rs.map((r) => r.job.order_id))];
    b.total_units = rs.reduce((t, r) => t + r.job.units, 0);
    b.garment_types = [...new Set(rs.flatMap((r) => r.job.garment_types))].sort();
    b.colours = [...new Set(rs.flatMap((r) => r.job.colours))].sort();
    b.est_setup_min = round1(rs.reduce((t, r) => t + r.setup_min, 0));
    b.est_run_min = round1(rs.reduce((t, r) => t + r.job.run_min, 0));
    b.priority_score = Math.max(...rs.map((r) => r.urg.total));
    b.scheduled_start = iso(rs[0].start); b.scheduled_end = iso(rs[rs.length - 1].end);
    b.is_bottleneck = !!(bottleneck && bottleneck.method === b.method_code);
    b.order_ids = ids; b.units_by_order = {}; rs.forEach((r) => { b.units_by_order[r.job.order_id] = (b.units_by_order[r.job.order_id] || 0) + r.job.units; });
    b.status = rs[0].job.step_index === 0 && rs[0].start <= now + DAY ? 'ready' : 'queued';
    b.sequence_reason = `${ids.length} order(s), ${b.total_units} units on ${rs[0].machine.code}; ` +
      (rs.length > 1 ? `grouped because changeovers between them are ${opt.batch_max_changeover_min} min or less; ` : '') + `most urgent score ${b.priority_score}.`;
    delete b._jobs;
  }
  batches.sort((a, b) => a.scheduled_start.localeCompare(b.scheduled_start) || a.batch_code.localeCompare(b.batch_code));
  batches.forEach((b, i) => { b.sequence_position = i + 1; });

  // per-order results
  const byOrder = new Map();
  for (const st of steps) { if (!byOrder.has(st.order_id)) byOrder.set(st.order_id, []); byOrder.get(st.order_id).push(st); }
  const ordMeta = new Map((input.orders || []).map((o) => [o.id, o]));
  const orders = [];
  for (const [oid, sts] of byOrder) {
    const j0 = jobs.find((j) => j.order_id === oid), sched = sts.filter((s) => s.planned_end), blockedAny = sts.some((s) => s.blocked_reason);
    const finish = sched.length ? Math.max(...sched.map((s) => Date.parse(s.planned_end))) : null;
    const first = sched.length ? Math.min(...sched.map((s) => Date.parse(s.planned_start))) : null;
    const next = sts.slice().sort((a, b) => a.step_no - b.step_no)[0];
    orders.push({ order_id: oid, order_ref: (ordMeta.get(oid) || {}).order_ref, planned_start: iso(first), planned_finish: iso(finish),
      is_late: sched.some((s) => s.is_late), blocked: blockedAny,
      risk_score: riskScore(finish == null ? Infinity : finish, j0.dueEnd, now, blockedAny),
      production_stage: blockedAny ? 'blocked' : next.method_code });
  }
  orders.sort((a, b) => (a.planned_start || '9').localeCompare(b.planned_start || '9') || b.risk_score - a.risk_score || a.order_id.localeCompare(b.order_id));
  orders.forEach((o, i) => { o.sequence_position = i + 1; });

  const blocked = steps.filter((s) => s.blocked_reason).map((s) => ({ order_id: s.order_id, method_code: s.method_code, reason: s.blocked_reason }));
  return { version: 'sched-1', generated_at: iso(now), steps, batches, orders, blocked,
    bottleneck, utilisation,
    summary: { orders_planned: orders.length, steps_scheduled: steps.length - blocked.length, steps_blocked: blocked.length,
      steps_late: steps.filter((s) => s.is_late).length, batches: batches.length, pins_applied: jobs.filter((j) => j.pin_rank != null).length,
      stock_gate: S.stock_gate, notes: S.stock_gate === 'ignore' ? ['Stock availability is not yet considered (allocation engine pending).'] : [] } };
}

if (typeof module !== 'undefined' && module.exports) module.exports = { buildPlan, localParts, zonedToUtc, buildWindows, place };
