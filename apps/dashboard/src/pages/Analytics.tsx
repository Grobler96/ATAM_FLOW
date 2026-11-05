import { useMemo } from 'react';
import { Panel, Kpi, Skeleton } from '../ui/primitives';
import { BarChart, Heat, Sparkline, StackBar } from '../ui/charts';
import { useView } from '../data/store';
import { navigate } from '../router';
import { statusLabel, ORDER_STATUS } from '../lib/domain';
import { AGE_BUCKETS } from '../lib/filters';
import { gbp } from '../lib/format';
import type { ExceptionRow } from '../types';
import type { OrderRow, PoRow, ShortageRow, StockRow } from '../data/types';

interface Head { shipped_30d: number; on_time_pct_30d: number | null; avg_days_late_30d: number | null; shipped_7d: number; shipped_prev_7d: number; units_7d: number; overdue_open: number; downtime_hours_30d: number | null; first_pass_pct_30d: number | null; open_rework: number; rework_units_30d: number; supplier_on_time_pct: number | null; producer_on_time_pct: number | null; exceptions_open: number; exceptions_median_age_hours: number | null }
interface DispDay { day: string; orders_shipped: number; units_shipped: number; on_time: number; late: number }
interface DownRow { machine_id: string; code: string; name: string; hours_down: number; hours_reduced: number; hours_unplanned: number; incidents: number }
interface QualWeek { week: string; checks: number; units_checked: number; units_failed: number; first_pass_pct: number | null }
interface DefectRow { defect_type: string; cause: string; jobs: number; units: number; units_scrapped: number }
interface ExcMetric { category: string; opened_30d: number; resolved_30d: number; open_now: number; avg_hours_to_resolve: number | null; past_deadline: number }

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

  const head = useView<Head>('ui_metric_headline').rows[0], disp = useView<DispDay>('ui_metric_dispatch_daily'), dt = useView<DownRow>('ui_metric_downtime'), qw = useView<QualWeek>('ui_metric_quality_weekly'), df = useView<DefectRow>('ui_metric_defects'), mx = useView<ExcMetric>('ui_metric_exceptions');
  const days = useMemo(() => Array.from({ length: 14 }, (_, i) => { const d = new Date(Date.now() - (13 - i) * 86400000); const key = d.toISOString().slice(0, 10); const r = disp.rows.find((x) => x.day === key); return { label: d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }), value: r?.orders_shipped ?? 0, tone: r && r.late > 0 ? 'var(--high)' : 'var(--good)' }; }), [disp.rows]);
  const defects = useMemo(() => [...df.rows.reduce((m, r) => m.set(r.defect_type, (m.get(r.defect_type) ?? 0) + r.units), new Map<string, number>()).entries()].map(([k, v]) => ({ label: k.replace(/_/g, ' '), value: v, tone: 'var(--high)' })).sort((a, b) => b.value - a.value), [df.rows]);
  const pctText = (v: number | null | undefined) => (v == null ? '—' : `${v}%`);
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
      {head && <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))', gap: 12 }}>
        <Kpi label="On-time dispatch (30 days)" text={pctText(head.on_time_pct_30d)} sub={`${head.shipped_30d} shipped${head.avg_days_late_30d != null ? ` · late ones avg ${head.avg_days_late_30d} d` : ''}`} tone={head.on_time_pct_30d != null && head.on_time_pct_30d < 85 ? 'high' : 'good'} />
        <Kpi label="Shipped this week" value={head.shipped_7d} sub={`${head.shipped_prev_7d} the week before · ${head.units_7d} units`} />
        <Kpi label="Open and overdue" value={head.overdue_open} sub="past their dispatch date" tone={head.overdue_open ? 'critical' : ''} onClick={() => navigate('orders', { view: 'overdue' })} />
        <Kpi label="First-pass quality (30 days)" text={pctText(head.first_pass_pct_30d)} sub={`${head.open_rework} rework job(s) open`} onClick={() => navigate('quality')} />
        <Kpi label="Machine downtime (30 days)" text={`${head.downtime_hours_30d ?? 0} h`} sub="all machines" />
        <Kpi label="Supplier on time" text={pctText(head.supplier_on_time_pct)} sub="average, suppliers with history" />
        <Kpi label="Producer on time" text={pctText(head.producer_on_time_pct)} sub="average, producers with history" />
        <Kpi label="Median open issue age" text={head.exceptions_median_age_hours != null ? `${head.exceptions_median_age_hours} h` : '—'} sub={`${head.exceptions_open} open`} onClick={() => navigate('exceptions')} /></div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(420px, 1fr))', gap: 16 }}>
        <Panel title="Orders by due date" icon="calendar"><BarChart data={dueBars.map((d) => ({ ...d, onClick: d.q ? () => navigate('orders', { view: d.q }) : undefined }))} unit=" orders" /></Panel>
        <Panel title="Pipeline" icon="orders"><div className="stack"><StackBar height={14} parts={statusParts} />
          {statusParts.map((s) => <button key={s.key} className="row" style={{ justifyContent: 'space-between', background: 'none', border: 0, padding: '4px 0', color: 'inherit' }} onClick={() => navigate('orders', { 'f.status': s.key })}><span className="row"><span className="dot" style={{ background: s.tone }} />{s.label}</span><b className="num">{s.value}</b></button>)}</div></Panel>
        <Panel title="Exceptions by area" icon="exceptions">{exCat.length ? <BarChart data={exCat.map((d) => ({ ...d, onClick: () => navigate('exceptions', { view: d.label === 'stock' ? 'stock' : d.label === 'producer' ? 'producers' : d.label === 'artwork' ? 'artwork' : d.label === 'logistics' ? 'courier' : 'all' }) }))} /> : <p className="dim">No open exceptions.</p>}</Panel>
        <Panel title="How old are they?" icon="clock">{heat.rows.length ? <Heat rows={heat.rows} cols={[...AGE_BUCKETS]} cells={heat.cells} /> : <p className="dim">Nothing open.</p>}</Panel>
        <Panel title="Open exceptions by day detected" icon="analytics"><div className="row" style={{ justifyContent: 'space-between' }}><Sparkline data={trend} w={300} h={64} /><span className="dim">last 14 days · full trend history builds up from here</span></div></Panel>
        <Panel title="Late purchase orders" icon="purchasing"><BarChart data={late} unit=" POs" /><div className="stack" style={{ marginTop: 12, gap: 2 }}>{supplierLate.map(([s, v]) => <div key={s} className="row" style={{ justifyContent: 'space-between' }}><span>{s}</span><span className="num dim">{v.late} late of {v.open} open</span></div>)}</div></Panel>
        <Panel title="Units short by when they are needed" icon="stock"><BarChart data={['Overdue', 'This week', 'Later', 'No date'].map((k) => ({ label: k, value: shortBars[k] ?? 0, tone: k === 'Overdue' ? 'var(--critical)' : k === 'This week' ? 'var(--high)' : 'var(--accent)', onClick: () => navigate('stock', { view: 'short' }) }))} unit=" units" /><p className="dim" style={{ marginTop: 8 }}>{stock.rows.filter((s) => s.is_low_stock).length} SKUs are below their minimum.</p></Panel>
        <Panel title="Orders shipped per day (last 14 days)" icon="orders"><BarChart data={days} unit=" orders" /><p className="dim" style={{ marginTop: 8 }}>Amber days include at least one late order. Built from shipped dates DecoNetwork reports; history is limited to orders ATAM_FLOW has seen.</p></Panel>
        <Panel title="Machine downtime (last 30 days)" icon="production">{dt.rows.length === 0 ? <p className="dim">No machines.</p> : <div className="stack" style={{ gap: 4 }}>{dt.rows.map((m) => <div key={m.machine_id} className="row" style={{ justifyContent: 'space-between' }}><span><b className="mono">{m.code}</b> <span className="dim">{m.name}</span></span><span className="num">{m.hours_down} h down{m.hours_reduced > 0 ? ` · ${m.hours_reduced} h reduced` : ''} · {m.incidents} incident(s) · {Math.max(0, Math.round((1 - m.hours_down / 720) * 1000) / 10)}% available</span></div>)}<p className="dim">Availability is on a calendar-hour basis (24 h × 30 days); machine shift calendars are not modelled.</p></div>}</Panel>
        <Panel title="Quality" icon="check"><div className="stack"><div className="row" style={{ justifyContent: 'space-between' }}><span>First-pass yield by week</span>{qw.rows.length > 1 ? <Sparkline data={qw.rows.sort((a, b) => a.week.localeCompare(b.week)).map((r) => r.first_pass_pct ?? 0)} w={220} h={48} /> : <span className="dim">{qw.rows.length === 1 ? `${qw.rows[0].first_pass_pct}% this week` : 'no checks recorded yet'}</span>}</div>{defects.length ? <><h3>Units reworked by problem (30 days)</h3><BarChart data={defects} unit=" units" /></> : <p className="dim">No rework in the last 30 days.</p>}</div></Panel>
        <Panel title="Exceptions: how fast are they dealt with? (30 days)" icon="exceptions" flush>{mx.rows.length === 0 ? <p className="dim" style={{ padding: 12 }}>No exceptions yet.</p> : <div style={{ overflow: 'auto' }}><table className="table"><thead><tr><th>Area</th><th className="r">Opened</th><th className="r">Resolved</th><th className="r">Open now</th><th className="r">Avg hours to resolve</th><th className="r">Past deadline</th></tr></thead><tbody>{mx.rows.sort((a, b) => b.open_now - a.open_now).map((r) => <tr key={r.category}><td>{r.category}</td><td className="r num">{r.opened_30d}</td><td className="r num">{r.resolved_30d}</td><td className="r num">{r.open_now}</td><td className="r num">{r.avg_hours_to_resolve ?? '—'}</td><td className={`r num ${r.past_deadline ? 'bad' : ''}`}>{r.past_deadline}</td></tr>)}</tbody></table></div>}</Panel>
        <Panel title="Not measured yet" icon="info"><p className="muted">Margin by producer, method and order type (needs saved supplier and producer choices on completed orders), production throughput by machine (needs completed-job history), and the cost of exceptions over time. They fill in as the system is used.</p></Panel>
      </div>
    </div>
  );
}
