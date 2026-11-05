import { useState } from 'react';
import { Button, EmptyState, Panel, Segmented, Status, Tag } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { Drawer } from '../ui/overlay';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { dateTime } from '../lib/format';
import { gateLabel, humanise, type CriterionRow, type QcCheckRow, type QcQueueRow, type ReworkRow } from '../lib/quality';
import { OrderLink, DueCell } from '../components/common';
import { CriterionDialog, OpenReworkDialog, RecordCheckDialog, ReworkStepDialog, type ReworkStep } from '../components/QualityDialogs';

type Mode = 'queue' | 'rework' | 'checks' | 'checklist';
const rwTone = (s: string) => (s === 'complete' ? 'good' : s === 'cancelled' ? 'low' : s === 'in_progress' ? 'info' : 'high') as 'good' | 'low' | 'info' | 'high';
const replLabel: Record<string, string> = { not_needed: '—', needed: 'Needed', ordered: 'Ordered', received: 'Received' };

export function QualityPage({ route }: { route: Route }) {
  const queue = useView<QcQueueRow>('ui_qc_queue'), rework = useView<ReworkRow>('ui_rework_jobs'), checks = useView<QcCheckRow>('ui_qc_checks'), crit = useView<CriterionRow>('ui_qc_criteria'); const { canAct, senior } = useCtx();
  const mode = (route.query.get('view') as Mode) || 'queue'; const setMode = (m: Mode) => navigate('quality', { view: m });
  const [dlg, setDlg] = useState<null | { k: 'check'; orderId?: string; pending?: QcCheckRow } | { k: 'rework' } | { k: 'step'; job: ReworkRow; step: ReworkStep } | { k: 'crit'; item?: CriterionRow }>(null);
  const openRw = rework.rows.filter((r) => ['open', 'in_progress'].includes(r.status)); const replacements = rework.rows.filter((r) => ['needed', 'ordered'].includes(r.replacement_status) && r.status !== 'cancelled'); const pendingChecks = checks.rows.filter((c) => c.status === 'pending');
  const detail = route.path[1] ? rework.rows.find((r) => r.rework_ref === decodeURIComponent(route.path[1])) : null;

  const qcols: Column<QcQueueRow>[] = [
    { id: 'o', header: 'Order', width: '110px', render: (q) => <OrderLink r={q.order_ref} />, sort: (q) => q.order_ref, csv: (q) => q.order_ref }, { id: 'c', header: 'Customer', width: '220px', render: (q) => q.customer_name, csv: (q) => q.customer_name },
    { id: 'd', header: 'Due', width: '170px', render: (q) => <DueCell days={q.due_date ? Math.ceil((Date.parse(q.due_date) - Date.now()) / 86400000) : null} date={q.due_date} />, sort: (q) => q.due_date, csv: (q) => q.due_date },
    { id: 's', header: 'Stage', width: '150px', render: (q) => humanise(q.order_status), csv: (q) => q.order_status }, { id: 'u', header: 'Units', width: '70px', align: 'r', render: (q) => <span className="num">{q.total_units}</span>, csv: (q) => q.total_units },
    { id: 'p', header: 'Checks waiting', width: '120px', align: 'r', render: (q) => <span className="num">{q.pending_checks || '—'}</span>, csv: (q) => q.pending_checks },
    { id: 'r', header: 'Last result', width: '110px', render: (q) => q.last_result ? <Status tone={q.last_result === 'passed' ? 'good' : 'critical'} plain>{q.last_result}</Status> : <span className="dim">none yet</span>, csv: (q) => q.last_result },
    { id: 'w', header: 'Open rework', width: '110px', align: 'r', render: (q) => (q.open_rework ? <Status tone="high">{q.open_rework}</Status> : <span className="dim">—</span>), csv: (q) => q.open_rework },
    { id: 'rp', header: 'Replacements', width: '120px', align: 'r', render: (q) => (q.replacements_open ? <Status tone="high">{q.replacements_open}</Status> : <span className="dim">—</span>), csv: (q) => q.replacements_open },
    { id: 'a', header: '', width: '120px', render: (q) => <Button size="sm" variant="primary" disabled={!canAct} onClick={(e) => { e.stopPropagation(); setDlg({ k: 'check', orderId: q.order_id }); }}>Record check</Button> }
  ];
  const rviews: ViewDef<ReworkRow>[] = [{ id: 'open', label: 'Open', test: (r) => ['open', 'in_progress'].includes(r.status) }, { id: 'repl', label: 'Replacements', test: (r) => ['needed', 'ordered'].includes(r.replacement_status) && r.status !== 'cancelled' }, { id: 'done', label: 'Finished', test: (r) => r.status === 'complete' }, { id: 'all', label: 'All', test: () => true }];
  const rcols: Column<ReworkRow>[] = [
    { id: 'ref', header: 'Rework', width: '130px', render: (r) => <b className="mono">{r.rework_ref}</b>, sort: (r) => r.rework_ref, csv: (r) => r.rework_ref }, { id: 'o', header: 'Order', width: '110px', render: (r) => <OrderLink r={r.order_ref} />, csv: (r) => r.order_ref },
    { id: 'c', header: 'Customer', width: '180px', render: (r) => r.customer_name, csv: (r) => r.customer_name }, { id: 'u', header: 'Units', width: '60px', align: 'r', render: (r) => <span className="num">{r.units}</span>, csv: (r) => r.units },
    { id: 'df', header: 'Problem', width: '140px', render: (r) => humanise(r.defect_type), csv: (r) => r.defect_type }, { id: 'ca', header: 'Cause', width: '110px', render: (r) => humanise(r.cause), csv: (r) => r.cause },
    { id: 's', header: 'Status', width: '120px', render: (r) => <Status tone={rwTone(r.status)}>{humanise(r.status)}</Status>, csv: (r) => r.status }, { id: 'oc', header: 'Needs', width: '150px', render: (r) => humanise(r.outcome), csv: (r) => r.outcome },
    { id: 'rp', header: 'Replacement', width: '110px', render: (r) => replLabel[r.replacement_status] ?? r.replacement_status, csv: (r) => r.replacement_status }, { id: 'as', header: 'Assigned', width: '110px', render: (r) => r.assigned_to?.replace('dashboard:', '') ?? <span className="dim">—</span>, csv: (r) => r.assigned_to },
    { id: 'age', header: 'Age', width: '80px', align: 'r', render: (r) => <span className="num dim">{r.age_hours < 48 ? Math.round(r.age_hours) + ' h' : Math.round(r.age_hours / 24) + ' d'}</span>, sort: (r) => r.age_hours, csv: (r) => Math.round(r.age_hours) }
  ];
  const cviews: ViewDef<QcCheckRow>[] = [{ id: 'all', label: 'All', test: () => true }, { id: 'pending', label: 'Waiting', test: (c) => c.status === 'pending' }, { id: 'failed', label: 'Failed', test: (c) => c.status === 'failed' }, { id: 'passed', label: 'Passed', test: (c) => c.status === 'passed' }];
  const ccols: Column<QcCheckRow>[] = [
    { id: 'ref', header: 'Check', width: '130px', render: (c) => <b className="mono">{c.check_ref}</b>, sort: (c) => c.check_ref, csv: (c) => c.check_ref }, { id: 'o', header: 'Order', width: '110px', render: (c) => <OrderLink r={c.order_ref} />, csv: (c) => c.order_ref },
    { id: 'g', header: 'Stage', width: '190px', render: (c) => gateLabel(c.gate) + (c.checkpoint_pct ? ` (${c.checkpoint_pct}%)` : ''), csv: (c) => c.gate }, { id: 's', header: 'Result', width: '110px', render: (c) => <Status tone={c.status === 'passed' ? 'good' : c.status === 'failed' ? 'critical' : c.is_overdue ? 'critical' : 'medium'}>{c.is_overdue ? 'overdue' : c.status}</Status>, csv: (c) => c.status },
    { id: 'u', header: 'Checked / failed', width: '120px', align: 'r', render: (c) => (c.units_checked != null ? `${c.units_checked} / ${c.units_failed ?? 0}` : '—'), csv: (c) => c.units_checked }, { id: 'df', header: 'Problem', width: '140px', render: (c) => (c.defect_type ? humanise(c.defect_type) : <span className="dim">—</span>), csv: (c) => c.defect_type },
    { id: 'pr', header: 'Producer', width: '150px', render: (c) => c.producer_name ?? <span className="dim">in-house</span>, csv: (c) => c.producer_name }, { id: 'by', header: 'Checked by', width: '140px', render: (c) => <span className="dim">{c.checked_by?.replace('dashboard:', '') ?? '—'}</span>, csv: (c) => c.checked_by },
    { id: 'at', header: 'When', width: '130px', render: (c) => <span className="dim">{c.checked_at ? dateTime(c.checked_at) : c.due_by ? 'due ' + dateTime(c.due_by) : '—'}</span>, sort: (c) => c.checked_at ?? c.created_at, csv: (c) => c.checked_at },
    { id: 'a', header: '', width: '110px', render: (c) => c.status === 'pending' ? <Button size="sm" variant="primary" disabled={!canAct} onClick={(e) => { e.stopPropagation(); setDlg({ k: 'check', pending: c }); }}>Do check</Button> : null }
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Quality</h1><p>{queue.rows.length} order(s) need a quality decision · {openRw.length} rework job(s) open · {replacements.length} replacement(s) outstanding · {pendingChecks.length} check(s) waiting.</p></div>
        <div className="row wrap"><Segmented label="Quality section" value={mode} options={[{ id: 'queue', label: `To check (${queue.rows.length})` }, { id: 'rework', label: `Rework (${openRw.length})` }, { id: 'checks', label: 'Checks' }, { id: 'checklist', label: 'Checklist' }]} onChange={setMode} />
          <Button variant="primary" icon="check" disabled={!canAct} title={canAct ? '' : 'Your role cannot record checks'} onClick={() => setDlg({ k: 'check' })}>Record check</Button><Button disabled={!canAct} onClick={() => setDlg({ k: 'rework' })}>Open rework</Button></div></div>
      {mode === 'queue' && <Panel flush><DataTable<QcQueueRow> rows={queue.rows} columns={qcols} rowKey={(q) => q.order_id} loading={queue.loading} error={queue.error} onRetry={() => void queue.refresh()} storageKey="qc-queue" exportName="quality-queue" searchText={(q) => [q.order_ref, q.customer_name].join(' ')} defaultSort={{ col: 'd', dir: 1 }}
        empty={<EmptyState icon="check" title="Nothing waiting for a quality decision">Orders appear here when they reach quality check, have a check waiting, or have rework or replacements outstanding. You can also record a check on any order.</EmptyState>} /></Panel>}
      {mode === 'rework' && <Panel flush><DataTable<ReworkRow> rows={rework.rows} columns={rcols} rowKey={(r) => r.id} loading={rework.loading} error={rework.error} onRetry={() => void rework.refresh()} views={rviews} defaultTab="open" storageKey="rework" exportName="rework" searchText={(r) => [r.rework_ref, r.order_ref, r.customer_name, r.defect_type, r.cause].join(' ')} onRowClick={(r) => navigate('quality/' + r.rework_ref, { view: 'rework' })} activeKey={detail?.id} defaultSort={{ col: 'age', dir: -1 }} initial={tableStateFromQuery(route)}
        empty={<EmptyState icon="check" title="No rework jobs">A failed check opens one automatically. Each job tracks the units until they are fixed and re-checked, or scrapped and replaced.</EmptyState>} /></Panel>}
      {mode === 'checks' && <Panel flush><DataTable<QcCheckRow> rows={checks.rows} columns={ccols} rowKey={(c) => c.id} loading={checks.loading} error={checks.error} onRetry={() => void checks.refresh()} views={cviews} storageKey="qc-checks" exportName="quality-checks" searchText={(c) => [c.check_ref, c.order_ref, c.defect_type, c.producer_name].join(' ')} defaultSort={{ col: 'at', dir: -1 }}
        empty={<EmptyState icon="check" title="No quality checks yet">Every check is recorded here with who did it, the units checked and failed, and the checklist.</EmptyState>} /></Panel>}
      {mode === 'checklist' && <Panel title="What gets checked" actions={<Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can change the checklist'} onClick={() => setDlg({ k: 'crit' })}>Add item</Button>}><div className="stack">
        <p className="dim">These are starter items: replace them with your real standards for each method. They appear as pass / fail ticks when a check is recorded.</p>
        {crit.rows.length === 0 ? <p className="dim">No checklist items yet.</p> : crit.rows.sort((a, b) => (a.method_code ?? '').localeCompare(b.method_code ?? '') || a.sort_order - b.sort_order).map((c) => <div key={c.id} className="row wrap" style={{ gap: 10, opacity: c.is_active ? 1 : 0.5 }}><Tag>{c.method_code ? humanise(c.method_code) : 'all methods'}</Tag><b>{c.name}</b><span className="muted grow">{c.description}</span>{!c.is_active && <Status tone="low" plain>not in use</Status>}<Button size="sm" variant="ghost" disabled={!senior} onClick={() => setDlg({ k: 'crit', item: c })}>Edit</Button></div>)}</div></Panel>}
      {detail && <Drawer open onClose={() => navigate('quality', { view: 'rework' })} title={<span className="mono">{detail.rework_ref}</span>} subtitle={<>{detail.order_ref} · {detail.customer_name} · <Status tone={rwTone(detail.status)}>{humanise(detail.status)}</Status></>}>
        <div className="stack">
          <dl className="facts">{([['Units', detail.units], ['Problem', humanise(detail.defect_type)], ['Likely cause', humanise(detail.cause)], ['Needs', humanise(detail.outcome)], ['SKU', detail.sku], ['Producer', detail.producer_name], ['Movement', detail.movement_code], ['From check', detail.check_ref], ['Assigned to', detail.assigned_to?.replace('dashboard:', '')], ['Fixed / scrapped', detail.status === 'complete' ? `${detail.units_fixed} / ${detail.units_scrapped}` : null], ['Replacement', detail.replacement_status !== 'not_needed' ? replLabel[detail.replacement_status] : null], ['Opened', dateTime(detail.created_at)], ['Finished', detail.completed_at ? dateTime(detail.completed_at) : null]] as [string, unknown][]).filter(([, v]) => v !== null && v !== undefined && v !== '').map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{String(v)}</dd></div>)}</dl>
          {detail.notes && <p className="muted">{detail.notes}</p>}{detail.replacement_note && <p className="muted">Replacement: {detail.replacement_note}</p>}{detail.cancel_reason && <p className="muted">Cancelled: {detail.cancel_reason}</p>}
          <div className="row wrap">{detail.status === 'open' && <Button variant="primary" disabled={!canAct} onClick={() => setDlg({ k: 'step', job: detail, step: 'start' })}>Start</Button>}{['open', 'in_progress'].includes(detail.status) && <><Button variant="primary" disabled={!canAct} onClick={() => setDlg({ k: 'step', job: detail, step: 'complete' })}>Finish</Button><Button variant="danger" disabled={!canAct} onClick={() => setDlg({ k: 'step', job: detail, step: 'cancel' })}>Cancel</Button></>}
            {['needed', 'ordered'].includes(detail.replacement_status) && <Button disabled={!canAct} onClick={() => setDlg({ k: 'step', job: detail, step: 'replacement' })}>Update replacement</Button>}</div>
        </div></Drawer>}
      {dlg?.k === 'check' && <RecordCheckDialog orderId={dlg.orderId} pending={dlg.pending} onClose={() => setDlg(null)} />}{dlg?.k === 'rework' && <OpenReworkDialog onClose={() => setDlg(null)} />}{dlg?.k === 'step' && <ReworkStepDialog job={dlg.job} step={dlg.step} onClose={() => setDlg(null)} />}{dlg?.k === 'crit' && <CriterionDialog item={dlg.item} onClose={() => setDlg(null)} />}
    </div>
  );
}
