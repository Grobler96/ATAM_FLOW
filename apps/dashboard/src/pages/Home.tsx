import { useMemo, useState } from 'react';
import { Icon } from '../ui/Icon';
import { Button, Chip, EmptyState, Kpi, Panel, Progress, Skeleton, Status } from '../ui/primitives';
import { StackBar } from '../ui/charts';
import { useView } from '../data/store';
import { useRpcList } from '../data/useRpcList';
import { useCtx } from '../data/context';
import { href, navigate } from '../router';
import { exceptionActionTo } from '../lib/api';
import { useToast } from '../ui/overlay';
import { VIEWS } from '../lib/filters';
import { gbp, ageText, deadlineText, dateTime } from '../lib/format';
import { METHOD_LABEL, within, shortDate, plural } from '../lib/domain';
import { OrderTags } from '../components/common';
import type { ExceptionRow } from '../types';
import type { ActivityRow, HeldRow, MachineRow, MovementRow, OrderRow, PoRow, ProducerRow, QueueRow, ShortageRow, StockRow } from '../data/types';

const sevTone = (s: string) => (s === 'critical' ? 'critical' : s === 'high' ? 'high' : s === 'medium' ? 'medium' : 'low') as 'critical' | 'high' | 'medium' | 'low';
const ACT_ICON: Record<string, string> = { audit: 'check', sync: 'refresh', exception: 'exceptions', receipt: 'box', movement: 'truck' };

export function Home() {
  const orders = useView<OrderRow>('ui_orders'), ex = useView<ExceptionRow>('ui_exceptions'), queue = useView<QueueRow>('ui_production_queue'), machines = useView<MachineRow>('ui_machines');
  const moves = useView<MovementRow>('ui_tp_movements'), producers = useView<ProducerRow>('ui_producers'), stock = useView<StockRow>('ui_stock'), shortages = useView<ShortageRow>('ui_shortages');
  const pos = useView<PoRow>('ui_purchase_orders'), held = useView<HeldRow>('ui_producer_held_stock'), exStatus = useView<{ last_detection_at: string | null }>('ui_status');
  const activity = useRpcList<ActivityRow>('ui_activity', { p_limit: 30 });
  const { range, inRange, email, canAct } = useCtx(); const toast = useToast();
  const [group, setGroup] = useState('all'); const [showAll, setShowAll] = useState(false); const [open, setOpen] = useState<string | null>(null);
  const loading = orders.loading || ex.loading;

  const k = useMemo(() => {
    const o = orders.rows.filter((x) => x.order_status !== 'dispatched');
    const dueToday = o.filter((x) => x.is_due_today);
    const arrivals = pos.rows.filter((p) => p.units_outstanding > 0 && !p.is_late && p.expected_date && within(p.expected_date, 3));
    const tp = moves.rows.filter((m) => !['closed', 'cancelled', 'draft', 'checked'].includes(m.status));
    return {
      dueToday: dueToday.length, unitsToday: dueToday.reduce((t, x) => t + x.total_units, 0), overdue: o.filter((x) => x.is_overdue).length,
      atRisk: ex.rows.filter((e) => e.type_code === 'order_at_risk').length, ready: o.filter((x) => x.order_status === 'ready_for_production').length, blocked: o.filter((x) => x.order_status === 'awaiting_stock').length,
      withProducers: new Set(tp.flatMap((m) => m.order_refs ?? [])).size, open: ex.rows.length, critical: ex.rows.filter((e) => e.severity === 'critical').length,
      arrivals: arrivals.length, arrivalUnits: arrivals.reduce((t, p) => t + p.units_outstanding, 0), bottleneck: queue.rows.find((q) => q.is_bottleneck) ?? null, openOrders: o.length
    };
  }, [orders.rows, ex.rows, pos.rows, moves.rows, queue.rows]);

  const groupView = VIEWS.find((v) => v.id === group) ?? VIEWS[0];
  const attention = useMemo(() => {
    const list = ex.rows.filter(groupView.match).filter((e) => range === 'all' || e.order_refs.length === 0 || e.severity === 'critical' || e.is_overdue || (() => { const o = orders.rows.find((x) => e.order_refs.includes(x.order_ref)); return !o || inRange(o.due_date); })());
    return list.sort((a, b) => a.severity_rank - b.severity_rank || Number(b.is_overdue) - Number(a.is_overdue) || Date.parse(a.response_deadline) - Date.parse(b.response_deadline));
  }, [ex.rows, groupView, range, inRange, orders.rows]);

  async function takeIt(e: ExceptionRow) {
    const r = await exceptionActionTo('exceptions', 'assign', { exception_id: e.id, owner: email });
    toast.push(r.ok === false ? { tone: 'bad', title: 'Could not assign', body: String(r.error) } : { tone: 'good', title: `${e.exc_ref} assigned to you` }); if (r.ok !== false) void ex.refresh();
  }

  const nextUp = useMemo(() => queue.rows.filter((q) => ['pending', 'ready', 'in_progress'].includes(q.status)).sort((a, b) => (a.sequence_position ?? 9999) - (b.sequence_position ?? 9999)).slice(0, 6), [queue.rows]);
  const qc = useMemo(() => ({ progress: queue.rows.filter((q) => q.status === 'in_progress').length, queued: queue.rows.filter((q) => ['pending', 'ready'].includes(q.status) && !q.blocked_reason).length, blocked: queue.rows.filter((q) => q.status === 'blocked' || !!q.blocked_reason).length, late: queue.rows.filter((q) => q.is_late && q.status !== 'complete').length }), [queue.rows]);
  const maxMin = Math.max(1, ...machines.rows.map((m) => m.queued_minutes));
  const stockK = useMemo(() => ({ low: stock.rows.filter((s) => s.is_low_stock && !s.is_out_of_stock).length, out: stock.rows.filter((s) => s.is_out_of_stock).length, incoming: pos.rows.filter((p) => p.units_outstanding > 0 && p.po_status !== 'draft').length,
    incomingUnits: pos.rows.reduce((t, p) => t + (p.po_status === 'draft' || p.po_status === 'cancelled' ? 0 : p.units_outstanding), 0), soon: pos.rows.filter((p) => p.units_outstanding > 0 && p.expected_date && within(p.expected_date, 7) && !p.is_late).length,
    short: pos.rows.filter((p) => p.units_short > 0 || p.po_status === 'short_shipped').length, late: pos.rows.filter((p) => p.is_late).length, atProducers: held.rows.reduce((t, h) => t + h.qty, 0) }), [stock.rows, pos.rows, held.rows]);
  const tpK = useMemo(() => {
    const act = moves.rows.filter((m) => !['closed', 'cancelled', 'draft', 'checked'].includes(m.status)); const todayIso = new Date().toISOString().slice(0, 10); const tmrw = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
    return { transit: act.filter((m) => ['dispatched', 'in_transit_back'].includes(m.status)).reduce((t, m) => t + m.units_sent, 0), heldUnits: producers.rows.reduce((t, p) => t + p.units_held, 0),
      dueToday: act.filter((m) => m.expected_return_date === todayIso).length, dueTomorrow: act.filter((m) => m.expected_return_date === tmrw).length, overdue: act.filter((m) => m.is_overdue).length,
      noReceipt: act.filter((m) => m.status === 'dispatched' && !m.received_by_producer_at).length, atRiskProducer: ex.rows.filter((e) => e.category === 'producer').flatMap((e) => e.order_refs) };
  }, [moves.rows, producers.rows, ex.rows]);

  const go = (path: string, q?: Record<string, string>) => () => navigate(path, q);
  const checked = exStatus.rows[0]?.last_detection_at;
  const sk = (n: number) => Array.from({ length: n }, (_, i) => <Skeleton key={i} h={72} r={14} />);
  const mid = (iso: string | null) => (iso ? dateTime(iso) : '—');

  return (
    <div className="stack" style={{ gap: 20 }}>
      <div className="page-head"><div><h1>Command Centre</h1><p>{k.openOrders} open orders · {k.open} open exceptions{checked ? ` · exceptions checked ${ageText((Date.now() - Date.parse(checked)) / 3600000).replace(' old', ' ago')}` : ''}</p></div></div>

      <section aria-label="Key numbers" className="kpi-grid">
        {loading ? sk(10) : <>
          <Kpi label="Orders due today" value={k.dueToday} sub={`${k.unitsToday.toLocaleString('en-GB')} units`} tone={k.dueToday ? 'high' : ''} onClick={go('orders', { view: 'today' })} />
          <Kpi label="Overdue orders" value={k.overdue} sub="Past their due date" tone={k.overdue ? 'critical' : ''} onClick={go('orders', { view: 'overdue' })} />
          <Kpi label="Orders at risk" value={k.atRisk} sub="May miss dispatch" tone={k.atRisk ? 'critical' : ''} onClick={go('orders', { view: 'risk' })} />
          <Kpi label="Ready for production" value={k.ready} sub="Stock and status OK" tone="good" onClick={go('orders', { view: 'ready' })} />
          <Kpi label="Blocked by stock" value={k.blocked} sub="Awaiting stock or PO" tone={k.blocked ? 'high' : ''} onClick={go('orders', { view: 'stock' })} />
          <Kpi label="Orders with producers" value={k.withProducers} sub="Out for decoration" tone="info" onClick={go('orders', { view: 'producers' })} />
          <Kpi label="Units due today" value={k.unitsToday} sub={plural(k.dueToday, 'order')} onClick={go('orders', { view: 'today' })} />
          <Kpi label="Open exceptions" value={k.open} sub={`${k.critical} critical`} tone={k.critical ? 'critical' : k.open ? 'high' : 'good'} onClick={go('exceptions')} />
          <Kpi label="Stock arrivals expected" value={k.arrivals} sub={`${k.arrivalUnits.toLocaleString('en-GB')} units in 3 days`} onClick={go('purchasing', { view: 'arriving' })} />
          <Kpi label="Current bottleneck" text={k.bottleneck ? (METHOD_LABEL[k.bottleneck.method_code] ?? k.bottleneck.method_code) : 'None'} sub={k.bottleneck ? `${k.bottleneck.machine_code ?? 'unassigned'} · ${k.bottleneck.order_ref}` : 'Nothing flagged'} tone={k.bottleneck ? 'high' : 'good'} onClick={go('production', { view: 'schedule' })} />
        </>}
      </section>

      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1.55fr) minmax(0, 1fr)', gap: 16 }} className="home-grid">
        <Panel title="What needs attention now" icon="exceptions" count={attention.length} actions={<><span className="dim hide-m">{range === 'all' ? 'All dates' : 'Due ' + (range === 'today' ? 'today' : range === 'week' ? 'this week' : 'this month')}</span><Button size="sm" onClick={go('exceptions')}>Open Exceptions</Button></>}>
          <div className="row wrap" style={{ marginBottom: 12, gap: 6 }}>{['all', 'orders', 'stock', 'producers', 'artwork', 'courier', 'data'].map((id) => { const v = VIEWS.find((x) => x.id === id)!; return <Chip key={id} on={group === id} count={ex.rows.filter(v.match).length} onClick={() => setGroup(id)}>{id === 'all' ? 'Everything' : v.label}</Chip>; })}</div>
          {ex.loading ? <div className="stack">{sk(4)}</div> : attention.length === 0 ? <EmptyState icon="check" title="Nothing needs attention here">Everything in this group is accounted for.</EmptyState> :
            <div className="stack" style={{ gap: 0 }}>
              {(showAll ? attention : attention.slice(0, 7)).map((e) => (
                <div key={e.id} className="attn-row">
                  <Status tone={sevTone(e.severity)}>{e.severity}</Status>
                  <div style={{ minWidth: 0 }}>
                    <div className="row wrap" style={{ gap: 8 }}><b>{e.type_label}</b>{e.is_overdue && <Status tone="critical" plain>Overdue</Status>}{e.escalation_level > 0 && <Status plain>Escalated ×{e.escalation_level}</Status>}{e.is_blocking && <Status tone="high" plain>Blocks work</Status>}</div>
                    <p className="muted" style={{ margin: '2px 0 4px' }}>{e.description}</p>
                    <div className="row wrap" style={{ gap: 12, fontSize: 12 }}><OrderTags refs={e.order_refs} max={3} /><span className={e.needs_owner ? 'warn' : 'dim'}>{e.owner ?? `No owner · ${e.owner_role}`}</span><span className={e.is_overdue ? 'bad' : 'dim'}>{deadlineText(e.response_deadline, e.is_overdue)}</span>{e.financial_impact != null && <span className="dim num">{gbp(e.financial_impact)} at stake</span>}</div>
                    {e.recommended_action && <p className="dim" style={{ marginTop: 4, fontSize: 12 }}><Icon name="arrow" size={11} /> {e.recommended_action}</p>}
                  </div>
                  <div className="row" style={{ gap: 6 }}>{canAct && e.needs_owner && <Button size="sm" onClick={() => void takeIt(e)}>Take it</Button>}<Button size="sm" variant="primary" onClick={go('exceptions/' + e.exc_ref)}>View</Button></div>
                </div>))}
              {attention.length > 7 && <Button variant="ghost" onClick={() => setShowAll((s) => !s)} style={{ marginTop: 8 }}>{showAll ? 'Show fewer' : `Show all ${attention.length}`}</Button>}
            </div>}
        </Panel>

        <Panel title="Production pulse" icon="production" actions={<Button size="sm" onClick={go('production')}>Open Production</Button>}>
          {queue.loading ? <div className="stack">{sk(3)}</div> : <div className="stack">
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8, textAlign: 'center' }}>
              {[['In progress', qc.progress, ''], ['Queued', qc.queued, ''], ['Blocked', qc.blocked, qc.blocked ? 'warn' : ''], ['Predicted late', qc.late, qc.late ? 'bad' : '']].map(([l, v, c]) => <div key={l as string}><div className={`num ${c}`} style={{ fontSize: 24, fontWeight: 680 }}>{v as number}</div><div className="dim" style={{ fontSize: 11 }}>{l as string}</div></div>)}
            </div>
            <h3>Recommended sequence</h3>
            {nextUp.length === 0 ? <p className="dim">No jobs are scheduled yet. Re-plan production from Quick actions.</p> : nextUp.map((q) => (
              <div key={q.step_id}><button className="row" style={{ width: '100%', background: 'none', border: 0, padding: '6px 0', textAlign: 'left', gap: 10 }} onClick={() => setOpen(open === q.step_id ? null : q.step_id)} aria-expanded={open === q.step_id}>
                <span className="num dim" style={{ width: 22 }}>#{q.sequence_position ?? '–'}</span><span className="grow"><b>{q.order_ref}</b> <span className="muted">{METHOD_LABEL[q.method_code] ?? q.method_code} · {plural(q.units, 'unit')}</span></span>
                {q.is_late && <Status tone="critical" plain>Late</Status>}<span className="dim num">{q.machine_code ?? 'no machine'} · {q.planned_start ? shortDate(q.planned_start) : '—'}</span><Icon name={open === q.step_id ? 'chevD' : 'chevR'} size={13} /></button>
                {open === q.step_id && <div className="callout soft" style={{ margin: '2px 0 8px' }}><b>Why this order, now</b><span className="muted">{q.reason ?? 'No reason recorded.'}</span>{q.score != null && <div className="dim" style={{ marginTop: 4 }}>Priority score {q.score}</div>}</div>}</div>))}
            <h3>Machine load</h3>
            {machines.rows.length === 0 ? <p className="dim">No machines set up.</p> : machines.rows.map((m) => <div key={m.id}><div className="row" style={{ justifyContent: 'space-between', fontSize: 12 }}><span>{m.name}</span><span className="dim num">{(m.queued_minutes / 60).toFixed(1)} h queued{m.late_jobs ? ` · ${m.late_jobs} late` : ''}</span></div><Progress value={(m.queued_minutes / maxMin) * 100} tone={m.late_jobs ? 'warn' : ''} /></div>)}
            <p className="dim" style={{ fontSize: 11 }}>Machine status, downtime and maintenance are not tracked yet.</p>
          </div>}
        </Panel>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 16 }}>
        <Panel title="Third-party pulse" icon="producers" actions={<Button size="sm" onClick={go('producers')}>Open Producers</Button>}>
          {producers.loading ? <div className="stack">{sk(3)}</div> : producers.rows.length === 0 && moves.rows.length === 0 ? <EmptyState icon="producers" title="No producers set up yet">Add producers and their rate cards, then outbound movements will be tracked here.</EmptyState> :
            <div className="stack">
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                {[['In transit', tpK.transit, ''], ['Held by producers', tpK.heldUnits, ''], ['Overdue returns', tpK.overdue, tpK.overdue ? 'bad' : ''], ['Returns today', tpK.dueToday, ''], ['Returns tomorrow', tpK.dueTomorrow, ''], ['Receipts unconfirmed', tpK.noReceipt, tpK.noReceipt ? 'warn' : '']].map(([l, v, c]) => <div key={l as string}><div className={`num ${c}`} style={{ fontSize: 22, fontWeight: 680 }}>{v as number}</div><div className="dim" style={{ fontSize: 11 }}>{l as string}</div></div>)}
              </div>
              {tpK.atRiskProducer.length > 0 && <div className="callout soft"><b>Orders at risk because of a producer</b><OrderTags refs={[...new Set(tpK.atRiskProducer)]} max={6} /></div>}
              {producers.rows.slice(0, 4).map((p) => <div key={p.id} className="row" style={{ justifyContent: 'space-between' }}><span>{p.name}</span><span className="dim num">{p.open_jobs} jobs · {p.units_held} held{p.on_time_rate != null ? ` · ${Math.round(p.on_time_rate)}% on time` : ''}</span></div>)}
            </div>}
        </Panel>

        <Panel title="Stock pulse" icon="stock" actions={<Button size="sm" onClick={go('stock')}>Open Stock</Button>}>
          {stock.loading ? <div className="stack">{sk(3)}</div> : <div className="stack">
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
              {[['Low stock', stockK.low, stockK.low ? 'warn' : '', 'low'], ['Out of stock', stockK.out, stockK.out ? 'bad' : '', 'out'], ['At producers', stockK.atProducers, '', 'producers'], ['POs incoming', stockK.incoming, '', ''], ['Due in 7 days', stockK.soon, '', ''], ['Short-shipped', stockK.short, stockK.short ? 'bad' : '', '']].map(([l, v, c]) => <div key={l as string}><div className={`num ${c}`} style={{ fontSize: 22, fontWeight: 680 }}>{v as number}</div><div className="dim" style={{ fontSize: 11 }}>{l as string}</div></div>)}
            </div>
            <p className="muted num">{stockK.incomingUnits.toLocaleString('en-GB')} units on order · {stockK.late} late POs</p>
            <h3>Shortages affecting orders</h3>
            {shortages.rows.length === 0 ? <p className="dim">No SKU is short.</p> : [...shortages.rows].sort((a, b) => (a.earliest_due ?? '9').localeCompare(b.earliest_due ?? '9')).slice(0, 5).map((s) => <a key={s.sku} href={href('stock/' + encodeURIComponent(s.sku))} className="row" style={{ justifyContent: 'space-between', color: 'inherit', textDecoration: 'none', padding: '3px 0' }}><span className="mono" style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.sku}</span><span className="dim num">short {s.units_short} · {s.orders_affected} orders · due {shortDate(s.earliest_due)}</span></a>)}
            <StackBar parts={[{ label: 'Low', value: stockK.low, tone: 'var(--high)' }, { label: 'Out', value: stockK.out, tone: 'var(--critical)' }, { label: 'OK', value: Math.max(0, stock.rows.length - stockK.low - stockK.out), tone: 'var(--good)' }]} />
            <p className="dim" style={{ fontSize: 11 }}>Stock ageing is not tracked yet.</p>
          </div>}
        </Panel>

        <Panel title="Recent activity" icon="clock" actions={<span className="dim">{activity.rows[0] ? 'Latest ' + mid(activity.rows[0].at) : ''}</span>}>
          {activity.loading ? <div className="stack">{sk(4)}</div> : activity.rows.length === 0 ? <EmptyState icon="clock" title="No activity yet" /> :
            <ul className="timeline" style={{ maxHeight: 420, overflow: 'auto' }}>{activity.rows.slice(0, 18).map((a, i) => (
              <li key={i} className={'k-' + a.kind}><div className="row" style={{ gap: 6 }}><Icon name={ACT_ICON[a.kind] ?? 'info'} size={13} />{a.route ? <a href={'#' + a.route}><b style={{ textTransform: 'capitalize' }}>{a.title}</b></a> : <b style={{ textTransform: 'capitalize' }}>{a.title}</b>}</div>
                <div className="dim" style={{ fontSize: 12 }}>{a.detail ? a.detail.slice(0, 110) : ''}</div><div className="dim" style={{ fontSize: 11 }}>{dateTime(a.at)}{a.actor ? ` · ${a.actor}` : ''}</div></li>))}</ul>}
        </Panel>
      </div>
    </div>
  );
}
