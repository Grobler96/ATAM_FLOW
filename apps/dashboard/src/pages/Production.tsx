import { useMemo } from 'react';
import { MachinesView } from './MachinesView';
import { Button, EmptyState, Panel, Segmented, Skeleton, Status, Tag } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { ScopeBanner } from '../components/ScopeBanner';
import { useView } from '../data/store';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { useRunner } from '../shell/useRunner';
import { WORKFLOWS } from '../lib/workflows';
import { METHOD_LABEL, PRIORITY, shortDate, stockStatus, plural } from '../lib/domain';
import { dateTime } from '../lib/format';
import { DueCell, Num } from '../components/common';
import type { ExceptionRow } from '../types';
import type { ArtworkStatusRow, MachineRow, OrderRow, QueueRow, TpOrderRow } from '../data/types';

type Mode = 'board' | 'schedule' | 'machines';
const COLS: { id: string; label: string; tone: string }[] = [{ id: 'stock', label: 'Awaiting stock', tone: 'var(--high)' }, { id: 'ready', label: 'Ready to produce', tone: 'var(--good)' }, { id: 'queued', label: 'Queued', tone: 'var(--accent)' },
  { id: 'progress', label: 'In progress', tone: 'var(--accent-2)' }, { id: 'qc', label: 'Quality check', tone: 'var(--accent)' }, { id: 'done', label: 'Complete', tone: 'var(--good)' }, { id: 'blocked', label: 'Blocked', tone: 'var(--critical)' }, { id: 'producer', label: 'With producer', tone: 'var(--low)' }];

export function ProductionPage({ route }: { route: Route }) {
  const mode = (route.query.get('view') as Mode) || 'board';
  const orders = useView<OrderRow>('ui_orders'), queue = useView<QueueRow>('ui_production_queue'), machines = useView<MachineRow>('ui_machines'), tpo = useView<TpOrderRow>('ui_tp_orders'), art = useView<ArtworkStatusRow>('ui_artwork_status'), ex = useView<ExceptionRow>('ui_exceptions');
  const runner = useRunner(); const sched = WORKFLOWS.find((w) => w.id === 'scheduler')!;
  const set = (m: Mode) => navigate('production', { view: m === 'board' ? undefined : m });
  const loading = orders.loading || queue.loading;

  const cards = useMemo(() => {
    const open = orders.rows.filter((o) => o.order_status !== 'dispatched');
    return open.map((o) => {
      const steps = queue.rows.filter((q) => q.order_id === o.id), tp = tpo.rows.find((t) => t.order_id === o.id && t.tp_status), a = art.rows.find((x) => x.order_id === o.id);
      const col = tp ? 'producer' : o.order_status === 'blocked' || o.order_status === 'on_hold' ? 'blocked' : o.order_status === 'awaiting_stock' || o.order_status === 'stock_allocated' ? 'stock' : o.order_status === 'quality_check' ? 'qc'
        : o.order_status === 'ready_for_dispatch' ? 'done' : o.order_status === 'in_production' || steps.some((s) => s.status === 'in_progress') ? 'progress' : steps.some((s) => s.planned_start) ? 'queued' : 'ready';
      const reason = o.order_status === 'on_hold' ? 'On hold' + (o.status_reason ? ': ' + o.status_reason : ' (no reason recorded)') : o.order_status === 'blocked' ? o.status_reason ?? 'Blocked' : steps.find((s) => s.blocked_reason)?.blocked_reason ?? null;
      return { o, col, steps, tp, a, reason, machine: steps.find((s) => s.machine_code)?.machine_code ?? null, eta: steps.map((s) => s.planned_end).filter(Boolean).sort().pop() ?? null, late: steps.some((s) => s.is_late), sev: ex.rows.find((e) => e.order_refs.includes(o.order_ref))?.severity };
    });
  }, [orders.rows, queue.rows, tpo.rows, art.rows, ex.rows]);

  return (
    <div className="stack" style={{ gap: 16 }}>
      <ScopeBanner />
      <div className="page-head"><div><h1>Production</h1><p>What to make next, on which machine, and why.</p></div>
        <div className="row"><Segmented label="Production view" value={mode} options={[{ id: 'board', label: 'Board' }, { id: 'schedule', label: 'Schedule' }, { id: 'machines', label: 'Machines' }]} onChange={set} />
          <Button icon="refresh" variant="primary" disabled={!runner.can(sched) || !!runner.running} onClick={() => void runner.run(sched)}>Re-plan production</Button></div></div>

      {mode === 'board' && (loading ? <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>{[0, 1, 2, 3].map((i) => <Skeleton key={i} h={260} r={14} />)}</div> : (
        <div style={{ display: 'grid', gridAutoFlow: 'column', gridAutoColumns: 'minmax(270px, 1fr)', gap: 12, overflowX: 'auto', paddingBottom: 8 }} role="list" aria-label="Production board">
          {COLS.map((c) => { const list = cards.filter((x) => x.col === c.id).sort((a, b) => (a.o.due_date ?? '9').localeCompare(b.o.due_date ?? '9')); return (
            <section key={c.id} className="panel" style={{ display: 'flex', flexDirection: 'column', maxHeight: 'calc(100vh - 250px)', borderTop: `2px solid ${c.tone}` }} role="listitem" aria-label={c.label}>
              <header className="panel-head"><div className="panel-title">{c.label}<span className="count num">{list.length}</span></div></header>
              <div style={{ overflowY: 'auto', padding: 8, display: 'grid', gap: 8, alignContent: 'start' }}>
                {list.length === 0 && <p className="dim" style={{ padding: 8 }}>Nothing here.</p>}
                {list.slice(0, 40).map(({ o, steps, tp, a, reason, machine, eta, late, sev }) => { const ss = stockStatus(o); return (
                  <a key={o.id} href={href('orders/' + o.order_ref.replace('#', ''))} className="panel" style={{ display: 'grid', gap: 6, padding: 10, color: 'inherit', textDecoration: 'none', borderLeft: `3px solid ${sev === 'critical' || late ? 'var(--critical)' : sev === 'high' ? 'var(--high)' : 'var(--border-strong)'}` }}>
                    <div className="row" style={{ justifyContent: 'space-between' }}><b className="mono">{o.order_ref}</b><DueCell days={o.days_to_due} /></div>
                    <div className="muted" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{o.customer_name}</div>
                    <div className="row wrap" style={{ gap: 4 }}>{o.decoration_methods.map((m) => <Tag key={m}>{METHOD_LABEL[m] ?? m}</Tag>)}<Tag>{plural(o.total_units, 'unit')}</Tag>{o.priority > 0 && <Status tone={PRIORITY[o.priority].tone} plain>{PRIORITY[o.priority].label}</Status>}</div>
                    <div className="row wrap dim" style={{ gap: 10, fontSize: 11.5 }}><span>{machine ?? (steps.length ? 'No machine' : 'Not scheduled')}</span><span>Stock: {ss.label}</span><span>Artwork: {a ? (a.blocking_issues ? `${a.blocking_issues} issue(s)` : 'ready') : 'n/a'}</span>{tp && <span>{tp.producer_name}</span>}{eta && <span>ETA {shortDate(eta)}</span>}</div>
                    {reason && <div className="warn" style={{ fontSize: 12 }}>{reason}</div>}{late && <Status tone="critical" plain>Predicted late</Status>}
                  </a>); })}
                {list.length > 40 && <p className="dim" style={{ padding: 8 }}>+{list.length - 40} more. Use Orders to see them all.</p>}
              </div>
            </section>); })}
        </div>))}
      {mode === 'board' && <p className="dim">The board shows each order's current stage from DecoNetwork and the engines. Moving cards by hand is not built yet, so stage changes happen through the real work (stock secured, scheduler, scans).</p>}

      {mode === 'schedule' && <ScheduleView queue={queue.rows} loading={queue.loading} error={queue.error} retry={() => void queue.refresh()} route={route} />}
      {mode === 'machines' && <MachinesView machines={machines.rows} queue={queue.rows} loading={machines.loading} />}
    </div>
  );
}

function Gantt({ rows }: { rows: QueueRow[] }) {
  const timed = rows.filter((r) => r.planned_start && r.planned_end && r.machine_code);
  if (timed.length === 0) return <EmptyState icon="production" title="No timed jobs yet">Re-plan production to build the machine timeline.</EmptyState>;
  const t0 = Math.min(...timed.map((r) => Date.parse(r.planned_start!))), t1 = Math.min(Math.max(...timed.map((r) => Date.parse(r.planned_end!))), t0 + 14 * 86400000), span = Math.max(t1 - t0, 3600000);
  const machines = [...new Set(timed.map((r) => r.machine_code!))].sort();
  const days: number[] = []; for (let d = new Date(new Date(t0).setHours(0, 0, 0, 0)).getTime(); d < t1; d += 86400000) days.push(d);
  return (
    <div style={{ overflowX: 'auto' }} role="img" aria-label="Machine timeline">
      <div style={{ minWidth: 760, position: 'relative' }}>
        <div className="row" style={{ marginLeft: 90, height: 22, position: 'relative' }}>{days.map((d) => <span key={d} className="dim" style={{ position: 'absolute', left: `${Math.max(0, ((d - t0) / span) * 100)}%`, fontSize: 10.5 }}>{new Date(d).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric' })}</span>)}</div>
        {machines.map((m) => (<div key={m} className="row" style={{ height: 34, borderTop: '1px solid var(--border)' }}><span className="mono dim" style={{ width: 90 }}>{m}</span>
          <div style={{ position: 'relative', flex: 1, height: 24 }}>{timed.filter((r) => r.machine_code === m).map((r) => { const l = ((Date.parse(r.planned_start!) - t0) / span) * 100, w = Math.max(0.6, ((Math.min(Date.parse(r.planned_end!), t1) - Date.parse(r.planned_start!)) / span) * 100);
            return <a key={r.step_id} href={href('orders/' + r.order_ref.replace('#', ''))} title={`${r.order_ref} · ${METHOD_LABEL[r.method_code] ?? r.method_code} · ${r.units} units · ${dateTime(r.planned_start!)} → ${dateTime(r.planned_end!)}${r.is_late ? ' · LATE' : ''}`} style={{ position: 'absolute', left: `${l}%`, width: `${w}%`, top: 2, height: 20, borderRadius: 5, background: r.is_late ? 'var(--critical)' : r.is_bottleneck ? 'var(--high)' : 'var(--accent)', opacity: 0.9, outline: r.is_overridden ? '2px solid #fff' : undefined, overflow: 'hidden' }} />; })}</div></div>))}
      </div>
      <p className="dim" style={{ marginTop: 6 }}>Blue = planned · orange = bottleneck · red = predicted late · white outline = manual override.</p>
    </div>
  );
}

function ScheduleView({ queue, loading, error, retry, route }: { queue: QueueRow[]; loading: boolean; error: string | null; retry: () => void; route: Route }) {
  const views: ViewDef<QueueRow>[] = [{ id: 'all', label: 'All steps', test: () => true }, { id: 'late', label: 'Predicted late', test: (q) => q.is_late }, { id: 'blocked', label: 'Blocked', test: (q) => q.status === 'blocked' || !!q.blocked_reason }, { id: 'over', label: 'Manually overridden', test: (q) => q.is_overridden }, { id: 'bottleneck', label: 'Bottleneck', test: (q) => q.is_bottleneck }];
  const cols: Column<QueueRow>[] = [
    { id: 'pos', header: '#', width: '56px', align: 'r', render: (q) => <Num v={q.sequence_position} />, sort: (q) => q.sequence_position, csv: (q) => q.sequence_position },
    { id: 'rec', header: 'System #', width: '100px', align: 'r', render: (q) => <span className={`num ${q.is_overridden ? 'warn' : 'dim'}`}>{q.recommended_position ?? '—'}</span>, sort: (q) => q.recommended_position, csv: (q) => q.recommended_position },
    { id: 'order', header: 'Order', width: '104px', render: (q) => <b className="mono">{q.order_ref}</b>, sort: (q) => q.order_ref, csv: (q) => q.order_ref },
    { id: 'cust', header: 'Customer', width: '190px', render: (q) => q.customer_name, csv: (q) => q.customer_name },
    { id: 'method', header: 'Method', width: '110px', render: (q) => METHOD_LABEL[q.method_code] ?? q.method_code, sort: (q) => q.method_code, csv: (q) => q.method_code },
    { id: 'machine', header: 'Machine', width: '100px', render: (q) => <span className="mono">{q.machine_code ?? '—'}</span>, sort: (q) => q.machine_code, csv: (q) => q.machine_code },
    { id: 'units', header: 'Units', width: '70px', align: 'r', render: (q) => <Num v={q.units} />, sort: (q) => q.units, csv: (q) => q.units },
    { id: 'start', header: 'Planned start', width: '130px', render: (q) => <span className="num">{q.planned_start ? dateTime(q.planned_start) : '—'}</span>, sort: (q) => q.planned_start, csv: (q) => q.planned_start },
    { id: 'end', header: 'Planned end', width: '130px', render: (q) => <span className="num">{q.planned_end ? dateTime(q.planned_end) : '—'}</span>, sort: (q) => q.planned_end, csv: (q) => q.planned_end },
    { id: 'due', header: 'Due', width: '90px', render: (q) => shortDate(q.due_date), sort: (q) => q.due_date, csv: (q) => q.due_date },
    { id: 'flags', header: 'Flags', width: '300px', render: (q) => <span className="row" style={{ gap: 4 }}>{q.is_late && <Status tone="critical" plain>Late</Status>}{q.is_bottleneck && <Status tone="high" plain>Bottleneck</Status>}{q.is_overridden && <Status tone="medium" plain>Overridden</Status>}{q.blocked_reason && <Status tone="high" plain>Blocked</Status>}</span>, csv: (q) => [q.is_late && 'late', q.is_bottleneck && 'bottleneck', q.is_overridden && 'overridden'].filter(Boolean).join(' ') },
    { id: 'why', header: 'Why this position', width: '520px', render: (q) => <span className="muted" title={q.reason ?? q.blocked_reason ?? ''}>{q.reason ?? q.blocked_reason ?? '—'}</span>, csv: (q) => q.reason }
  ];
  return (<>
    <Panel title="Machine timeline" icon="clock"><Gantt rows={queue} /></Panel>
    <Panel flush><DataTable<QueueRow> rows={queue} columns={cols} rowKey={(q) => q.step_id} loading={loading} error={error} onRetry={retry} views={views} storageKey="schedule" exportName="schedule" searchText={(q) => [q.order_ref, q.customer_name, q.method_code, q.machine_code, q.reason].join(' ')}
      onRowClick={(q) => navigate('orders/' + q.order_ref.replace('#', ''))} defaultSort={{ col: 'pos', dir: 1 }} initial={tableStateFromQuery(route)} rowTone={(q) => (q.is_late ? 'critical' : q.is_overridden ? 'medium' : '')} /></Panel>
  </>);
}
