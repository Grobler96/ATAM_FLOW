import { useEffect, useMemo, useState } from 'react';
import { Button, Chip, Facts, Field, Kpi, Panel, Skeleton, Status, Tag } from '../ui/primitives';
import { DataTable, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { Drawer, Modal } from '../ui/overlay';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { exceptionAction, findOrderId, loadHistory } from '../lib/api';
import { VIEWS, AGE_BUCKETS } from '../lib/filters';
import { ACTION_LABEL, BLOCK_LABEL, STATUS_LABEL, ageText, dateTime, deadlineText, gbp } from '../lib/format';
import { OrderTags } from '../components/common';
import { useRunner } from '../shell/useRunner';
import { WORKFLOWS } from '../lib/workflows';
import { useToast } from '../ui/overlay';
import type { ExceptionRow, HistoryRow } from '../types';
import { useFocus } from '../data/focus';
import { FocusBar } from '../components/FocusBar';
import { ExceptionDigest } from '../components/ExceptionDigest';

const STATUSES = ['open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer'];
const METHODS: [string, string][] = [['fixed', 'Fixed'], ['replacement_received', 'Replacement received'], ['credit_issued', 'Credit issued'], ['rework_complete', 'Rework complete'], ['rerouted', 'Re-routed'], ['customer_agreed', 'Customer agreed new date'], ['supplier_resolved', 'Supplier resolved'], ['producer_resolved', 'Producer resolved'], ['no_action_needed', 'No action needed'], ['other', 'Other']];
const tone = (s: string) => s as 'critical' | 'high' | 'medium' | 'low';

export function ExceptionsPage({ route }: { route: Route }) {
  const ex = useView<ExceptionRow>('ui_exceptions'); const { canAct, email } = useCtx(); const runner = useRunner(); const toast = useToast();
  const [raising, setRaising] = useState(false); const chk = WORKFLOWS.find((w) => w.id === 'exceptions')!;
  const open = route.path[1]; const focus = useFocus();
  const rows = useMemo(() => ex.rows.filter((e) => !focus.hideException(e.order_refs)), [ex.rows, focus]); const hiddenCount = ex.rows.length - rows.length;
  const views: ViewDef<ExceptionRow>[] = VIEWS.map((v) => ({ id: v.id, label: v.label, test: v.match }));
  const filters: FilterDef<ExceptionRow>[] = [
    { id: 'sev', label: 'Severity', options: ['critical', 'high', 'medium', 'low'].map((v) => ({ value: v, label: v })), test: (e, v) => e.severity === v },
    { id: 'status', label: 'Status', options: Object.entries(STATUS_LABEL).map(([v, l]) => ({ value: v, label: l })), test: (e, v) => e.status === v },
    { id: 'age', label: 'Age', options: AGE_BUCKETS.map((v) => ({ value: v, label: v })), test: (e, v) => e.age_bucket === v },
    { id: 'flags', label: 'Flags', options: [{ value: 'overdue', label: 'Overdue' }, { value: 'blocking', label: 'Blocking' }, { value: 'unowned', label: 'No owner' }, { value: 'mine', label: 'Mine' }], test: (e, v) => v === 'overdue' ? e.is_overdue : v === 'blocking' ? e.is_blocking : v === 'unowned' ? e.needs_owner : e.owner?.toLowerCase() === email?.toLowerCase() }
  ];
  const cols: Column<ExceptionRow>[] = [
    { id: 'sev', header: 'Severity', width: '100px', render: (e) => <Status tone={tone(e.severity)}>{e.severity}</Status>, sort: (e) => e.severity_rank, csv: (e) => e.severity },
    { id: 'type', header: 'Type', width: '210px', render: (e) => <span title={e.type_label}>{e.type_label}</span>, sort: (e) => e.type_label, csv: (e) => e.type_label },
    { id: 'desc', header: 'What is wrong', width: '440px', render: (e) => <span className="muted" title={e.description}>{e.description}</span>, csv: (e) => e.description },
    { id: 'status', header: 'Status', width: '150px', render: (e) => <span>{STATUS_LABEL[e.status]}</span>, sort: (e) => e.status, csv: (e) => e.status },
    { id: 'orders', header: 'Orders', width: '190px', render: (e) => <OrderTags refs={e.order_refs} max={2} />, csv: (e) => e.order_refs },
    { id: 'age', header: 'Age', width: '90px', render: (e) => <span className="dim">{ageText(e.age_hours).replace(' old', '')}</span>, sort: (e) => e.age_hours, csv: (e) => e.age_hours },
    { id: 'owner', header: 'Owner', width: '170px', render: (e) => e.owner ?? <span className="warn">No owner · {e.owner_role}</span>, sort: (e) => e.owner, csv: (e) => e.owner },
    { id: 'impact', header: 'Impact', width: '100px', align: 'r', render: (e) => <span className="num">{gbp(e.financial_impact)}</span>, sort: (e) => e.financial_impact, csv: (e) => e.financial_impact },
    { id: 'deadline', header: 'Respond by', width: '150px', render: (e) => <span className={e.is_overdue ? 'bad' : 'dim'}>{deadlineText(e.response_deadline, e.is_overdue)}</span>, sort: (e) => Date.parse(e.response_deadline), csv: (e) => e.response_deadline },
    { id: 'block', header: 'Blocks', width: '170px', render: (e) => <span className="row" style={{ gap: 4 }}>{e.blocks.map((b) => <Tag key={b} block>{b}</Tag>)}</span>, csv: (e) => e.blocks },
    { id: 'rec', header: 'Recommended action', width: '420px', render: (e) => <span className="dim" title={e.recommended_action ?? ''}>{e.recommended_action}</span>, csv: (e) => e.recommended_action }
  ];
  const k = useMemo(() => ({ open: rows.length, critical: rows.filter((e) => e.severity === 'critical').length, overdue: rows.filter((e) => e.is_overdue).length, blocking: rows.filter((e) => e.is_blocking).length, unowned: rows.filter((e) => e.needs_owner).length, money: rows.reduce((t, e) => t + (e.financial_impact ?? 0), 0) }), [rows]);
  const sel = open ? ex.rows.find((e) => e.exc_ref === open) : null;   // a link to a hidden exception still opens
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Exceptions</h1><p>Everything wrong, late, missing or unknown, with an owner and a next step.</p></div>
        <div className="row">{canAct && <Button variant="primary" icon="plus" onClick={() => setRaising(true)}>Raise an issue</Button>}<Button icon="refresh" disabled={!runner.can(chk) || !!runner.running} onClick={() => void runner.run(chk)}>Check now</Button></div></div>
      <FocusBar focus={focus} hidden={[{ n: hiddenCount, noun: 'exception' }]} />
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 12 }}>
        <Kpi label="Open" value={k.open} /><Kpi label="Critical" value={k.critical} tone={k.critical ? 'critical' : ''} /><Kpi label="Overdue" value={k.overdue} tone={k.overdue ? 'high' : ''} /><Kpi label="Blocking work" value={k.blocking} tone={k.blocking ? 'high' : ''} /><Kpi label="No owner" value={k.unowned} tone={k.unowned ? 'medium' : ''} /><Kpi label="At stake" text={gbp(k.money)} />
      </div>
      <ExceptionDigest hide={focus.hideException} email={email ?? null} />
      <Panel flush><DataTable<ExceptionRow> rows={rows} columns={cols} rowKey={(e) => e.exc_ref} loading={ex.loading} error={ex.error} onRetry={() => void ex.refresh()} views={views} filters={filters} storageKey="exceptions" exportName="exceptions"
        searchText={(e) => [e.exc_ref, e.type_label, e.description, e.owner, ...e.order_refs, ...e.skus, ...e.po_refs, ...e.movement_refs, ...e.producers].join(' ')} searchPlaceholder="Search issue, order, SKU, PO, person…"
        onRowClick={(e) => navigate('exceptions/' + e.exc_ref)} activeKey={open} rowTone={(e) => (e.severity === 'critical' || e.severity === 'high' || e.severity === 'medium' ? e.severity : '')} defaultSort={{ col: 'sev', dir: 1 }} initial={tableStateFromQuery(route)} /></Panel>
      {open && (sel ? <ExceptionDrawer e={sel} onClose={() => navigate('exceptions')} onChanged={async (m) => { toast.push({ tone: 'good', title: m }); await ex.refresh(); }} /> : <Drawer open onClose={() => navigate('exceptions')} title={open}>{ex.loading ? <Skeleton h={120} /> : <p className="muted">This issue is no longer open (it was resolved or cleared).</p>}</Drawer>)}
      <RaiseDialog open={raising} me={email} onClose={() => setRaising(false)} onDone={async () => { setRaising(false); toast.push({ tone: 'good', title: 'Issue raised' }); await ex.refresh(); }} />
    </div>
  );
}

type Panel_ = null | 'assign' | 'note' | 'resolve' | 'cancel' | 'write_off' | 'reopen';
function ExceptionDrawer({ e, onClose, onChanged }: { e: ExceptionRow; onClose: () => void; onChanged: (m: string) => Promise<void> }) {
  const { canAct, senior, email } = useCtx();
  const [hist, setHist] = useState<HistoryRow[] | null>(null); const [panel, setPanel] = useState<Panel_>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const [owner, setOwner] = useState(e.owner ?? email ?? ''); const [note, setNote] = useState(''); const [method, setMethod] = useState('fixed'); const [amount, setAmount] = useState(e.financial_impact != null ? String(e.financial_impact) : ''); const [isAction, setIsAction] = useState(true);
  useEffect(() => { let alive = true; setHist(null); loadHistory(e.id).then((h) => alive && setHist(h)).catch(() => alive && setHist([])); return () => { alive = false; }; }, [e.id, e.status, e.owner, e.escalation_level]);
  async function run(action: string, params: Record<string, unknown>, ok: string) {
    setBusy(true); setErr(null); const r = await exceptionAction(action, { exception_id: e.id, ...params }); setBusy(false);
    if (r.ok === false) { setErr(r.error ?? 'That did not work.'); return; }
    setPanel(null); setNote(''); await onChanged(ok + (r.note ? ' ' + r.note : ''));
  }
  const form = (title: string, submit: string, body: React.ReactNode, fn: () => void, disabled: boolean, danger?: boolean) => (
    <form className="panel" style={{ padding: 14, display: 'grid', gap: 10, marginTop: 10 }} onSubmit={(ev) => { ev.preventDefault(); if (!disabled && !busy) fn(); }}><h3>{title}</h3>{body}{err && <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{err}</div>}
      <div className="row"><Button variant={danger ? 'danger' : 'primary'} disabled={disabled || busy}>{busy ? 'Saving…' : submit}</Button><Button type="button" variant="ghost" onClick={() => setPanel(null)}>Back</Button></div></form>);
  return (
    <Drawer open onClose={onClose} wide title={<span className="row wrap" style={{ gap: 10 }}><Status tone={tone(e.severity)}>{e.severity}</Status>{e.type_label}{e.is_overdue && <Status tone="critical">Overdue</Status>}</span>} subtitle={<span className="mono">{e.exc_ref}</span>}>
      <div className="stack" style={{ gap: 16 }}>
        <p style={{ fontSize: 16 }}>{e.description}</p>
        {e.recommended_action && <div className="callout"><b>Recommended action</b>{e.recommended_action}</div>}
        {e.customer_impact && <div className="callout soft"><b>Customer impact</b>{e.customer_impact}</div>}
        {canAct ? <section aria-label="Actions"><h3>What would you like to do?</h3>
          <div className="row wrap" style={{ marginTop: 8 }}>
            <Button variant="primary" onClick={() => { setPanel('assign'); setOwner(email ?? ''); }}>{e.owner ? 'Reassign' : 'Take it / assign'}</Button>
            <select className="select" aria-label="Change status" style={{ width: 'auto' }} value="" disabled={busy} onChange={(ev) => ev.target.value && void run('status', { status: ev.target.value }, 'Status updated.')}><option value="">Set status…</option>{STATUSES.filter((s) => s !== e.status).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}</select>
            <Button onClick={() => setPanel('note')}>Add note / action taken</Button><Button variant="good" onClick={() => setPanel('resolve')}>Resolve</Button>
            {senior && <Button onClick={() => setPanel('cancel')}>Not a real issue</Button>}{senior && <Button variant="danger" onClick={() => setPanel('write_off')}>Write off</Button>}</div>
          {panel === 'assign' && form('Assign an owner', 'Assign', <><Field label="Owner (name or email)"><input className="input" value={owner} onChange={(ev) => setOwner(ev.target.value)} /></Field><Field label="Note (optional)"><input className="input" value={note} onChange={(ev) => setNote(ev.target.value)} /></Field></>, () => void run('assign', { owner, note: note || undefined }, 'Assigned.'), !owner.trim())}
          {panel === 'note' && form('Add to the record', 'Save', <><Field label="What happened?"><textarea className="textarea" rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} placeholder="e.g. Phoned the supplier, replacement promised Friday" /></Field><label className="check"><input type="checkbox" checked={isAction} onChange={(ev) => setIsAction(ev.target.checked)} />This is an action I took (not just a note)</label></>, () => void run('note', { note, is_action: isAction }, 'Saved.'), !note.trim())}
          {panel === 'resolve' && form('Resolve', 'Mark resolved', <><Field label="How was it resolved?"><select className="select" value={method} onChange={(ev) => setMethod(ev.target.value)}>{METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field><Field label="Note (required)"><textarea className="textarea" rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} /></Field><p className="dim">If the underlying problem is still there, the next check reopens this.</p></>, () => void run('resolve', { method, note }, 'Resolved.'), !note.trim())}
          {panel === 'cancel' && form('Not a real issue', 'Cancel this issue', <><Field label="Why? (required)"><textarea className="textarea" rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} /></Field><p className="dim">It will not be raised again for 30 days.</p></>, () => void run('cancel', { reason: note }, 'Cancelled.'), !note.trim())}
          {panel === 'write_off' && form('Write off', 'Write off', <><Field label="Amount written off (£)"><input className="input" inputMode="decimal" value={amount} onChange={(ev) => setAmount(ev.target.value)} /></Field><Field label="Reason (required)"><textarea className="textarea" rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} /></Field></>, () => void run('write_off', { reason: note, financial_impact: Number(amount) }, 'Written off.'), !note.trim() || amount.trim() === '' || isNaN(Number(amount)), true)}
          {panel === null && err && <div className="callout" role="alert" style={{ marginTop: 8, borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{err}</div>}</section> : <p className="muted">You have view-only access.</p>}
        <Facts items={[['Status', STATUS_LABEL[e.status]], ['Owner', e.owner ?? `Nobody yet (${e.owner_role} is responsible)`], ['Respond by', `${dateTime(e.response_deadline)} · ${deadlineText(e.response_deadline, e.is_overdue)}`], ['Escalation', e.escalation_level ? `Level ${e.escalation_level}` : 'Not escalated'], ['Detected', `${dateTime(e.detected_at)} by ${e.detected_by.replace('_', ' ')}`], ['Root cause', e.root_cause?.replace('_', ' ')],
          ['Financial impact', gbp(e.financial_impact)], ['Blocks', e.blocks.map((b) => BLOCK_LABEL[b] ?? b).join(', ')]]} />
        <section className="stack"><h3>Linked records</h3><div className="row wrap"><OrderTags refs={e.order_refs} max={20} />{[...e.skus, ...e.po_refs, ...e.movement_refs, ...e.producers].map((x) => <Tag key={x}>{x}</Tag>)}</div></section>
        <section className="stack"><h3>History</h3>{!hist ? <Skeleton h={60} /> : <ul className="timeline">{hist.map((h, i) => <li key={i}><b>{ACTION_LABEL[h.action] ?? h.action}</b><span className="dim"> · {h.actor ?? 'system'} · {dateTime(h.at)}</span>{h.note && <div className="muted">{h.note}</div>}</li>)}</ul>}</section>
      </div>
    </Drawer>
  );
}

function RaiseDialog({ open, me, onClose, onDone }: { open: boolean; me: string | null; onClose: () => void; onDone: () => Promise<void> }) {
  const [category, setCategory] = useState('other'); const [severity, setSeverity] = useState('medium'); const [description, setDescription] = useState(''); const [orderRef, setOrderRef] = useState(''); const [owner, setOwner] = useState(me ?? ''); const [deadline, setDeadline] = useState(''); const [blocks, setBlocks] = useState<string[]>([]); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function submit() {
    setBusy(true); setErr(null); const links: unknown[] = [];
    if (orderRef.trim()) { const id = await findOrderId(orderRef.startsWith('#') ? orderRef : '#' + orderRef); if (!id) { setBusy(false); setErr(`No order called ${orderRef.trim()} was found.`); return; } links.push({ type: 'order', id }); }
    const r = await exceptionAction('raise', { category, severity, description, links, owner: owner.trim() || undefined, deadline: deadline ? new Date(deadline).toISOString() : undefined, blocks });
    setBusy(false); if (r.ok === false) { setErr(r.error ?? 'That did not work.'); return; } setDescription(''); await onDone();
  }
  return (
    <Modal open={open} onClose={onClose} title="Raise an issue">
      <div className="stack">
        <Field label="What is wrong?"><textarea className="textarea" rows={3} value={description} onChange={(e) => setDescription(e.target.value)} placeholder="e.g. Customer reports faded print on order #636220" /></Field>
        <div className="row"><Field label="Type"><select className="select" value={category} onChange={(e) => setCategory(e.target.value)}>{['stock', 'purchasing', 'producer', 'artwork', 'production', 'quality', 'logistics', 'order', 'other'].map((c) => <option key={c}>{c}</option>)}</select></Field>
          <Field label="How serious?"><select className="select" value={severity} onChange={(e) => setSeverity(e.target.value)}>{['low', 'medium', 'high', 'critical'].map((c) => <option key={c}>{c}</option>)}</select></Field></div>
        <div className="row"><Field label="Order number (optional)"><input className="input" value={orderRef} onChange={(e) => setOrderRef(e.target.value)} placeholder="636220" /></Field><Field label="Owner"><input className="input" value={owner} onChange={(e) => setOwner(e.target.value)} /></Field></div>
        <Field label="Respond by (optional)"><input type="datetime-local" className="input" value={deadline} onChange={(e) => setDeadline(e.target.value)} /></Field>
        <div className="row wrap"><span className="muted">Stops the order from</span>{['completion', 'dispatch', 'production'].map((b) => <Chip key={b} on={blocks.includes(b)} onClick={() => setBlocks((x) => (x.includes(b) ? x.filter((y) => y !== b) : [...x, b]))}>{b === 'completion' ? 'being completed' : b === 'dispatch' ? 'being dispatched' : 'going into production'}</Chip>)}</div>
        {err && <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{err}</div>}
        <div className="row"><Button variant="primary" disabled={busy || !description.trim()} onClick={() => void submit()}>{busy ? 'Saving…' : 'Raise issue'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
