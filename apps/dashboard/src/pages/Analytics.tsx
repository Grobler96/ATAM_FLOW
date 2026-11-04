import { useMemo } from 'react';
import { Panel, Status, Kpi, Skeleton } from '../ui/primitives';
import { BarChart, Heat, Sparkline, StackBar } from '../ui/charts';
import { useView } from '../data/store';
import { navigate } from '../router';
import { statusLabel, ORDER_STATUS } from '../lib/domain';
import { AGE_BUCKETS } from '../lib/filters';
import { gbp } from '../lib/format';
import type { ExceptionRow } from '../types';
import type { OrderRow, PoRow, ShortageRow, StockRow } from '../data/types';

const TONE = { critical: 'var(--critical)', high: 'var(--high)', medium: 'var(--medium)', low: 'var(--low)', good: 'var(--good)', info: 'var(--accent)', '': 'var(--text-3)' } as const;
const CATS = ['stock', 'purchasing', 'producer', 'artwork', 'production', 'logistics', 'integration', 'data', 'order'];

export function AnalyticsPage() {
  const orders = useView<OrderRow>('ui_orders'), ex = useView<ExceptionRow>('ui_exceptions'), pos = useView<PoRow>('ui_purchase_orders'), short = useView<ShortageRow>('ui_shortages'), stock = useView<StockRow>('ui_stock');
  const open = useMemo(() => orders.rows.filter((o) => o.order_status !== 'dispatched'), [orders.rows]);

  const dueBars = useMemo(() => {
    const b = [{ label: 'Overdue', value: open.filter((o) => o.is_overdue).length, tone: 'var(--critical)', q: 'overdue' }, { label: 'Today', value: open.filter((o) => o.is_due_today).length, tone: 'var(--high)', q: 'today' }];
    for (let d = 1; d <= 10; d++) { const dt = new Date(Date.now() + d * 86400000); b.push({ label: dt.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric' }), value: open.filter((o) => o.days_to_due === d).length, tone: 'var(--accent)', q: '' }); }
    b.push({ label: 'Later', value: open.filter((o) => (o.days_to_due ?? 0) > 10).length, tone: 'var(--text-3)', q: '' }, { label: 'No date', value: open.filter((o) => o.days_to_due === null).length, tone: 'var(--medium)', q: '' });
    return b;
  }, [open]);
  const statusParts = useMemo(() => { const m = new Map<string, number>(); open.forEach((o) => m.set(o.order_status, (m.get(o.order_status) ?? 0) + 1)); return [...m.entries()].map(([s, n]) => ({ label: statusLabel(s), value: n, tone: TONE[ORDER_STATUS[s]?.tone ?? ''], key: s })).sort((a, b) => b.value - a.value); }, [open]);
  const exCat = useMemo(() => CATS.map((c) => ({ label: c, value: ex.rows.filter((e) => e.category === c).length, tone: 'var(--accent)' })).filter((d) => d.value > 0), [ex.rows]);
  const heat = useMemo(() => { const rows = CATS.filter((c) => ex.rows.some((e) => e.category === c)); return { rows, cells: rows.map((c) => AGE_BUCKETS.map((b) => ex.rows.filter((e) => e.category === c && e.age_bucket === b).length)) }; }, [ex.rows]);
  const trend = useMemo(() => Array.from({ length: 14 }, (_, i) => { const d0 = Date.now() - (13 - i) * 86400000; return ex.rows.filter((e) => { const t = Date.parse(e.detected_at); return t >= d0 - 43200000 && t < d0 + 43200000; }).length; }), [ex.rows]);
  const late = useMemo(() => { const l = pos.rows.filter((p) => p.is_late); const b = [['1-7 d', 1, 7], ['8-14 d', 8, 14], ['15-30 d', 15, 30], ['30+ d', 31, 9999]] as const; return b.map(([label, lo, hi]) => ({ label, value: l.filter((p) => p.days_late >= lo && p.days_late <= hi).length, tone: lo > 14 ? 'var(--critical)' : 'var(--high)' })); }, [pos.rows]);
  const supplierLate = useMemo(() => { const m = new Map<string, { late: number; open: number }>(); pos.rows.filter((p) => p.units_outstanding > 0).forEach((p) => { const k = p.supplier ?? '—'; const e = m.get(k) ?? { late: 0, open: 0 }; e.open++; if (p.is_late) e.late++; m.set(k, e); }); return [...m.entries()].sort((a, b) => b[1].late - a[1].late).slice(0, 8); }, [pos.rows]);
  const shortBars = useMemo(() => short.rows.reduce<Record<string, number>>((m, s) => { const k = !s.earliest_due ? 'No date' : Date.parse(s.earliest_due) < Date.now() ? 'Overdue' : Date.parse(s.earliest_due) < Date.now() + 7 * 86400000 ? 'This week' : 'Later'; m[k] = (m[k] ?? 0) + s.units_short; return m; }, {}), [short.rows]);
  const atRisk = useMemo(() => ex.rows.filter((e) => e.type_code === 'order_at_risk').reduce((t, e) => t + (e.financial_impact ?? 0), 0), [ex.rows]);
  const loading = orders.loading || ex.loading;

  const metrics: [string, string, 'now' | 'data' | 'next'][] = [['On-time completion rate', 'Builds up as orders complete through ATAM_FLOW', 'data'], ['Production throughput (jobs and units per day)', 'Needs completed-job history', 'data'], ['Machine utilisation and downtime', 'Needs machine status tracking (resilience step R3)', 'next'], ['Rework and quality failures', 'Needs quality-control gates (R7)', 'next'],
    ['Supplier lead time and on-time rate', 'Fills as POs are booked in through ATAM_FLOW', 'data'], ['Producer turnaround and discrepancy rate', 'Fills as consignments return', 'data'], ['Margin by producer / method / order type', 'Needs producer rate cards and saved supplier choices', 'data'], ['Cost of exceptions and profit at risk', 'Exposure shown now; cost builds as exceptions close', 'now']];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Analytics</h1><p>Trends and shape of the business, kept apart from daily operations. Charts drill into the underlying records.</p></div></div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))', gap: 12 }}>
        {loading ? [0, 1, 2, 3].map((i) => <Skeleton key={i} h={72} r={14} />) : <>
          <Kpi label="Open orders" value={open.length} sub={`${gbp(open.reduce((t, o) => t + (o.order_value ?? 0), 0))} value`} onClick={() => navigate('orders')} />
          <Kpi label="Revenue at risk" text={gbp(atRisk)} sub="Orders flagged at risk" tone={atRisk ? 'critical' : ''} onClick={() => navigate('orders', { view: 'risk' })} />
          <Kpi label="Open exceptions" value={ex.rows.length} sub={`${gbp(ex.rows.reduce((t, e) => t + (e.financial_impact ?? 0), 0))} exposed`} tone="high" onClick={() => navigate('exceptions')} />
          <Kpi label="Stock units short" value={short.rows.reduce((t, s) => t + s.units_short, 0)} sub={`${short.rows.length} SKUs`} tone="high" onClick={() => navigate('stock', { view: 'short' })} /></>}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(420px, 1fr))', gap: 16 }}>
        <Panel title="Orders by due date" icon="calendar"><BarChart data={dueBars.map((d) => ({ ...d, onClick: d.q ? () => navigate('orders', { view: d.q }) : undefined }))} unit=" orders" /></Panel>
        <Panel title="Pipeline" icon="orders"><div className="stack"><StackBar height={14} parts={statusParts} />
          {statusParts.map((s) => <button key={s.key} className="row" style={{ justifyContent: 'space-between', background: 'none', border: 0, padding: '4px 0', color: 'inherit' }} onClick={() => navigate('orders', { 'f.status': s.key })}><span className="row"><span className="dot" style={{ background: s.tone }} />{s.label}</span><b className="num">{s.value}</b></button>)}</div></Panel>
        <Panel title="Exceptions by area" icon="exceptions">{exCat.length ? <BarChart data={exCat.map((d) => ({ ...d, onClick: () => navigate('exceptions', { view: d.label === 'stock' ? 'stock' : d.label === 'producer' ? 'producers' : d.label === 'artwork' ? 'artwork' : d.label === 'logistics' ? 'courier' : 'all' }) }))} /> : <p className="dim">No open exceptions.</p>}</Panel>
        <Panel title="How old are they?" icon="clock">{heat.rows.length ? <Heat rows={heat.rows} cols={[...AGE_BUCKETS]} cells={heat.cells} /> : <p className="dim">Nothing open.</p>}</Panel>
        <Panel title="Open exceptions by day detected" icon="analytics"><div className="row" style={{ justifyContent: 'space-between' }}><Sparkline data={trend} w={300} h={64} /><span className="dim">last 14 days · full trend history builds up from here</span></div></Panel>
        <Panel title="Late purchase orders" icon="purchasing"><BarChart data={late} unit=" POs" /><div className="stack" style={{ marginTop: 12, gap: 2 }}>{supplierLate.map(([s, v]) => <div key={s} className="row" style={{ justifyContent: 'space-between' }}><span>{s}</span><span className="num dim">{v.late} late of {v.open} open</span></div>)}</div></Panel>
        <Panel title="Units short by when they are needed" icon="stock"><BarChart data={['Overdue', 'This week', 'Later', 'No date'].map((k) => ({ label: k, value: shortBars[k] ?? 0, tone: k === 'Overdue' ? 'var(--critical)' : k === 'This week' ? 'var(--high)' : 'var(--accent)', onClick: () => navigate('stock', { view: 'short' }) }))} unit=" units" /><p className="dim" style={{ marginTop: 8 }}>{stock.rows.filter((s) => s.is_low_stock).length} SKUs are below their minimum.</p></Panel>
        <Panel title="Metrics we are building towards" icon="info"><div className="stack" style={{ gap: 8 }}>{metrics.map(([m, why, st]) => <div key={m} className="row" style={{ justifyContent: 'space-between', gap: 12 }}><span><b>{m}</b><br /><span className="dim">{why}</span></span><Status tone={st === 'now' ? 'good' : st === 'data' ? 'medium' : 'low'} plain>{st === 'now' ? 'Available' : st === 'data' ? 'Needs history' : 'Needs build'}</Status></div>)}</div></Panel>
      </div>
    </div>
  );
}
