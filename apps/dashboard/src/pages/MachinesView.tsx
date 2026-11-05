import { useState } from 'react';
import { Button, EmptyState, Panel, Progress, Skeleton, Status, Tag } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { useRunner } from '../shell/useRunner';
import { WORKFLOWS } from '../lib/workflows';
import { href } from '../router';
import { METHOD_LABEL } from '../lib/domain';
import { dateTime } from '../lib/format';
import { KIND_LABEL, STATUS_LABEL, STATUS_TONE, type DowntimeRow, type MachineStatusRow } from '../lib/machines';
import { ImpactDialog, MachineDialog, ReportDowntimeDialog, ResolveDowntimeDialog, UpdateReturnDialog } from '../components/MachineDialogs';
import type { MachineRow, QueueRow } from '../data/types';

type Dlg = null | { k: 'report'; machine?: string } | { k: 'add' } | { k: 'edit'; id: string } | { k: 'impact'; m: MachineStatusRow } | { k: 'resolve'; d: DowntimeRow } | { k: 'update'; d: DowntimeRow };

// Machine cards with real status (operational, reduced capacity, maintenance, breakdown, offline), downtime reporting, impact and history.
export function MachinesView({ machines, queue, loading }: { machines: MachineRow[]; queue: QueueRow[]; loading: boolean }) {
  const status = useView<MachineStatusRow>('ui_machine_status'); const downtime = useView<DowntimeRow>('ui_machine_downtime'); const { canAct, senior } = useCtx(); const runner = useRunner();
  const [dlg, setDlg] = useState<Dlg>(null); const [tab, setTab] = useState<'cards' | 'history'>('cards');
  const schedulerWf = WORKFLOWS.find((w) => w.id === 'scheduler')!; const canReplan = canAct && runner.can(schedulerWf);
  const replan = () => { void runner.run(schedulerWf); };
  const max = Math.max(1, ...machines.map((m) => m.queued_minutes)); const down = status.rows.filter((s) => s.is_active && s.status !== 'operational'); const dtFor = (id: string | null) => downtime.rows.find((d) => d.id === id);
  const hviews: ViewDef<DowntimeRow>[] = [{ id: 'open', label: 'Open & scheduled', test: (d) => !d.ended_at }, { id: 'all', label: 'All', test: () => true }, { id: 'ended', label: 'Ended', test: (d) => !!d.ended_at }];
  const hcols: Column<DowntimeRow>[] = [
    { id: 'm', header: 'Machine', width: '100px', render: (d) => <b className="mono">{d.machine_code}</b>, sort: (d) => d.machine_code, csv: (d) => d.machine_code }, { id: 'k', header: 'Kind', width: '150px', render: (d) => KIND_LABEL[d.kind] ?? d.kind, csv: (d) => d.kind },
    { id: 's', header: 'State', width: '120px', render: (d) => d.ended_at ? <Status tone="good" plain>Ended</Status> : d.is_scheduled ? <Status tone="info">Scheduled</Status> : <Status tone={d.back_overdue ? 'critical' : 'high'}>{d.back_overdue ? 'Overdue back' : 'Down now'}</Status>, csv: (d) => (d.ended_at ? 'ended' : d.is_scheduled ? 'scheduled' : 'current') },
    { id: 'r', header: 'Reason', width: '260px', render: (d) => d.reason, csv: (d) => d.reason }, { id: 'st', header: 'From', width: '130px', render: (d) => dateTime(d.started_at), sort: (d) => d.started_at, csv: (d) => d.started_at },
    { id: 'e', header: 'Back', width: '130px', render: (d) => (d.ended_at ? dateTime(d.ended_at) : d.expected_back_at ? dateTime(d.expected_back_at) + ' (expected)' : '—'), csv: (d) => d.ended_at ?? d.expected_back_at },
    { id: 'h', header: 'Hours', width: '70px', align: 'r', render: (d) => <span className="num">{d.is_scheduled ? '—' : d.hours.toFixed(1)}</span>, sort: (d) => d.hours, csv: (d) => d.hours.toFixed(1) },
    { id: 'by', header: 'Reported by', width: '150px', render: (d) => <span className="dim">{d.reported_by?.replace('dashboard:', '') ?? '—'}</span>, csv: (d) => d.reported_by }, { id: 'n', header: 'Resolution', width: '220px', render: (d) => d.resolution_note ?? <span className="dim">—</span>, csv: (d) => d.resolution_note },
    { id: 'a', header: '', width: '170px', render: (d) => !d.ended_at ? <span className="row" style={{ gap: 6 }}><Button size="sm" disabled={!canAct} onClick={(e) => { e.stopPropagation(); setDlg({ k: 'resolve', d }); }}>{d.is_scheduled ? 'Cancel' : 'Back in service'}</Button></span> : null }
  ];
  if (loading || status.loading) return <Skeleton h={200} r={14} />;
  return (<div className="stack" style={{ gap: 14 }}>
    <div className="row wrap"><span className="muted grow">{down.length === 0 ? 'Every machine is operational.' : `${down.length} machine(s) not at full capacity: ${down.map((s) => s.code).join(', ')}.`}</span>
      <div className="row" style={{ gap: 4 }}><button className={`chip ${tab === 'cards' ? 'on' : ''}`} aria-pressed={tab === 'cards'} onClick={() => setTab('cards')}>Machines</button><button className={`chip ${tab === 'history' ? 'on' : ''}`} aria-pressed={tab === 'history'} onClick={() => setTab('history')}>Downtime history ({downtime.rows.length})</button></div>
      <Button icon="plus" variant="primary" disabled={!canAct} title={canAct ? '' : 'Your role cannot report downtime'} onClick={() => setDlg({ k: 'report' })}>Report downtime</Button><Button disabled={!senior} title={senior ? '' : 'Only a manager or admin can add machines'} onClick={() => setDlg({ k: 'add' })}>Add machine</Button></div>
    {tab === 'history' ? <Panel flush><DataTable<DowntimeRow> rows={downtime.rows} columns={hcols} rowKey={(d) => d.id} loading={downtime.loading} error={downtime.error} onRetry={() => void downtime.refresh()} views={hviews} storageKey="downtime" exportName="machine-downtime" searchText={(d) => [d.machine_code, d.reason, d.kind].join(' ')} defaultSort={{ col: 'st', dir: -1 }}
      empty={<EmptyState icon="production" title="No downtime recorded">Breakdowns, maintenance and reduced capacity appear here with how long each lasted.</EmptyState>} /></Panel>
    : <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(310px, 1fr))', gap: 12 }}>
      {status.rows.length === 0 && <EmptyState icon="production" title="No machines set up" action={senior ? <Button variant="primary" onClick={() => setDlg({ k: 'add' })}>Add a machine</Button> : undefined}>Add your machines so production can be planned and downtime tracked.</EmptyState>}
      {status.rows.map((s) => { const m = machines.find((x) => x.id === s.machine_id); const mine = queue.filter((q) => q.machine_code === s.code && q.status !== 'complete'); const affected = [...new Set(mine.filter((q) => q.is_late).map((q) => q.order_ref))]; const d = dtFor(s.downtime_id); const isDown = s.is_active && s.status !== 'operational'; return (
        <Panel key={s.machine_id} title={<span><span className="mono">{s.code}</span> · {s.name}</span>} actions={<Status tone={STATUS_TONE[s.status] ?? ''}>{STATUS_LABEL[s.status] ?? s.status}{s.status === 'limited' ? ` ${Math.round(s.capacity_factor * 100)}%` : ''}</Status>}>
          <div className="stack">
            <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">{METHOD_LABEL[s.method_code] ?? s.method_code}{s.machine_type ? ` · ${s.machine_type}` : ''}{s.location ? ` · ${s.location}` : ''}</span><span className="dim num">{s.units_per_hour ? `${s.units_per_hour} units/h` : 'rate not set'}</span></div>
            {isDown && <div className="callout" role="status"><b>{s.status_reason}</b><br /><span className="dim">Since {s.since ? dateTime(s.since) : '—'}{s.expected_back_at ? ` · expected back ${dateTime(s.expected_back_at)}` : ' · no return time given'}</span>{s.back_overdue && <> <Status tone="critical" plain>overdue back</Status></>}</div>}
            {s.next_planned_start && <div className="dim">Planned: {s.next_planned_reason} from {dateTime(s.next_planned_start)}</div>}
            {m && <div><div className="row" style={{ justifyContent: 'space-between', fontSize: 12 }}><span>Queue</span><span className="num">{m.queued_jobs + m.in_progress_jobs} jobs · {m.queued_units} units · {(m.queued_minutes / 60).toFixed(1)} h</span></div><Progress value={(m.queued_minutes / max) * 100} tone={m.late_jobs ? 'warn' : ''} /></div>}
            {m && <div className="row" style={{ justifyContent: 'space-between' }}><span className="muted">Predicted late jobs</span><span className={`num ${m.late_jobs ? 'bad' : ''}`}>{m.late_jobs}</span></div>}
            {affected.length > 0 && <div className="row wrap" style={{ gap: 4 }}>{affected.slice(0, 6).map((r) => <a key={r} className="tag mono" href={href('orders/' + r.replace('#', ''))}>{r}</a>)}</div>}
            {(s.backup_codes ?? []).length > 0 && <div className="row wrap" style={{ gap: 4 }}><span className="muted">Backup:</span>{(s.backup_codes ?? []).map((c) => <Tag key={c}>{c}</Tag>)}</div>}
            {s.notes && <p className="dim">{s.notes}</p>}
            <div className="row wrap" style={{ gap: 6 }}>
              {isDown && d ? <><Button size="sm" variant="primary" disabled={!canAct} onClick={() => setDlg({ k: 'resolve', d })}>Back in service</Button><Button size="sm" disabled={!canAct} onClick={() => setDlg({ k: 'update', d })}>Change return time</Button><Button size="sm" onClick={() => setDlg({ k: 'impact', m: s })}>View impact</Button></>
                : s.is_active ? <Button size="sm" disabled={!canAct} title={canAct ? '' : 'Your role cannot report downtime'} onClick={() => setDlg({ k: 'report', machine: s.machine_id })}>Report downtime</Button> : null}
              <Button size="sm" variant="ghost" disabled={!senior} title={senior ? '' : 'Only a manager or admin can edit machines'} onClick={() => setDlg({ k: 'edit', id: s.machine_id })}>Edit</Button></div>
          </div></Panel>); })}
      <Panel title="Not tracked yet" icon="info"><p className="muted">Operators, shift calendars per machine, and a planner that slows a machine down for reduced capacity are not built yet: reduced-capacity machines are shown but still planned at full speed. Cost and margin impact and customer messages for late orders are also not calculated.</p></Panel>
    </div>}
    {dlg?.k === 'report' && <ReportDowntimeDialog machine={dlg.machine} onClose={() => setDlg(null)} onReplan={replan} replanning={!!runner.running} />}
    {dlg?.k === 'add' && <MachineDialog onClose={() => setDlg(null)} />}{dlg?.k === 'edit' && <MachineDialog id={dlg.id} onClose={() => setDlg(null)} />}
    {dlg?.k === 'impact' && <ImpactDialog m={dlg.m} onClose={() => setDlg(null)} onReplan={replan} replanning={!!runner.running} />}
    {dlg?.k === 'resolve' && <ResolveDowntimeDialog d={dlg.d} onClose={() => setDlg(null)} onReplan={replan} replanning={!!runner.running} />}{dlg?.k === 'update' && <UpdateReturnDialog d={dlg.d} onClose={() => setDlg(null)} />}
    {!canReplan && canAct && <p className="dim">Your role cannot re-plan production; ask a manager to re-plan after downtime changes.</p>}
  </div>);
}
