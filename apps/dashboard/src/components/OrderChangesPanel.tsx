import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { loadImpact, opsAction, PRIORITY_NAMES, type ChangeRow, type Impact } from '../lib/orderChanges';
import { ReasonDialog } from './WarehouseDialogs';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

// What changed in DecoNetwork after we started, what it touches, and the manual controls for this order: hold, release, priority.
export function OrderChangesPanel({ orderId, orderRef, status, priority }: { orderId: string; orderRef: string; status: string; priority: number }) {
  const changes = useView<ChangeRow>('ui_order_changes'); const { canAct, senior } = useCtx(); const toast = useToast();
  const mine = changes.rows.filter((c) => c.order_id === orderId).sort((a, b) => b.detected_at.localeCompare(a.detected_at));
  const open = mine.filter((c) => c.status === 'new'); const done = mine.filter((c) => c.status !== 'new');
  const [imp, setImp] = useState<Impact | null | undefined>(undefined); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const [dlg, setDlg] = useState<null | 'hold' | 'release' | 'priority'>(null); const [prio, setPrio] = useState(String(priority));
  useEffect(() => { let live = true; setImp(undefined); void loadImpact(orderId).then((x) => { if (live) setImp(x); }); return () => { live = false; }; }, [orderId, open.length]);
  const needsNote = open.some((c) => c.severity === 'high');
  async function review(st: 'accepted' | 'dismissed') {
    setBusy(true); setErr(null); const r = await opsAction('review_changes', { order_id: orderId, status: st, reason: note }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: 'Changes reviewed', body: 'Your note is in the audit trail.' }); setNote(''); void refreshAll();
  }
  return (
    <div className="stack" style={{ gap: 14 }}>
      <div className="callout soft stack" style={{ gap: 6 }}>
        <b>Manual controls</b>
        <p className="dim">Each needs a reason and is recorded with your name and the previous value. After a hold or priority change, re-plan production to apply it.</p>
        <div className="row wrap">
          {status === 'on_hold' ? <Button size="sm" variant="primary" disabled={!canAct} onClick={() => setDlg('release')}>Release hold</Button> : <Button size="sm" variant="danger" disabled={!canAct || status === 'dispatched'} title={canAct ? '' : 'Your role cannot hold orders'} onClick={() => setDlg('hold')}>Put on hold</Button>}
          <Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can change priority'} onClick={() => setDlg('priority')}>Change priority ({PRIORITY_NAMES[priority] ?? priority})</Button>
        </div>
        <p className="dim">Stock quantities and dispatch dates are not editable here: DecoNetwork is the source and would overwrite them on the next sync. Correct them in DecoNetwork.</p>
      </div>

      <h3>Changes since work began</h3>
      {open.length === 0 ? <p className="dim">Nothing waiting for review.</p> : <>
        <div className="stack" style={{ gap: 4 }}>{open.map((c) => <div key={c.id} className="row wrap" style={{ gap: 10 }}><Status tone={c.severity === 'high' ? 'critical' : c.severity === 'warning' ? 'medium' : 'good'} plain>{c.severity === 'high' ? 'work affected' : c.severity}</Status><b>{c.label}</b><span className="muted grow">{c.old_value ?? '—'} → {c.new_value ?? '—'}</span><span className="dim">{dateTime(c.detected_at)}</span></div>)}</div>
        {imp === undefined ? <p className="dim">Working out what this touches…</p> : imp && <div className="stack" style={{ gap: 4 }}>
          <p className="dim">Touches: {imp.allocated_units} unit(s) reserved · {imp.consignments.length} open consignment(s){imp.consignments.length ? ` (${imp.consignments.join(', ')})` : ''} · bin {imp.bins.join(', ') || 'none'} · {imp.printed_labels} printed label(s) · {imp.steps_in_progress} job step(s) running.</p>
          {imp.actions.length > 0 && <><h3>What to do</h3><ul className="plain">{imp.actions.map((a, i) => <li key={i}>{a}</li>)}</ul></>}</div>}
        {err && <Err m={err} />}
        <Field label={needsNote ? 'What did you do about it? (required: this hit work already under way)' : 'Note (optional)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        <div className="row"><Button variant="primary" disabled={!canAct || busy || (needsNote && note.trim().length < 5)} onClick={() => void review('accepted')}>{busy ? 'Saving…' : 'Mark as dealt with'}</Button><Button variant="ghost" disabled={!canAct || busy || (needsNote && note.trim().length < 5)} onClick={() => void review('dismissed')}>No action needed</Button></div>
        <p className="dim">While work-affecting changes are unreviewed, this order raises an "Order changed" exception that blocks dispatch.</p>
      </>}
      {done.length > 0 && <><h3>Reviewed</h3><div className="stack" style={{ gap: 2 }}>{done.slice(0, 10).map((c) => <div key={c.id} className="row wrap" style={{ gap: 10 }}><b>{c.label}</b><span className="muted grow">{c.old_value ?? '—'} → {c.new_value ?? '—'}</span><span className="dim">{c.status} by {c.reviewed_by ?? '—'}{c.review_note ? ` · ${c.review_note}` : ''}</span></div>)}</div></>}

      {dlg === 'hold' && <ReasonDialog path="operations" title={`Put ${orderRef} on hold`} intro="Production and dispatch planning will skip this order until you release it. Any job already running on the floor must be stopped first." confirm="Put on hold" action="hold" params={{ order_id: orderId }} presets={['Customer asked us to wait', 'Awaiting artwork approval', 'Payment issue', 'Stock problem under investigation']} onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg === 'release' && <ReasonDialog path="operations" title={`Release ${orderRef}`} intro="It returns to the stage it was in before the hold." confirm="Release" action="release" params={{ order_id: orderId }} presets={['Issue resolved', 'Customer confirmed']} onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg === 'priority' && <Modal open onClose={() => setDlg(null)} title={`Priority for ${orderRef}`}><PriorityForm orderId={orderId} current={priority} value={prio} setValue={setPrio} onClose={() => { setDlg(null); void refreshAll(); }} /></Modal>}
    </div>
  );
}

function PriorityForm({ orderId, current, value, setValue, onClose }: { orderId: string; current: number; value: string; setValue: (v: string) => void; onClose: () => void }) {
  const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r = await opsAction('priority', { order_id: orderId, priority: Number(value), reason }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title: 'Priority changed', body: 'Re-plan production to apply it.' }); onClose(); }
  return <div className="stack"><Field label="New priority"><select className="select" value={value} onChange={(e) => setValue(e.target.value)}>{PRIORITY_NAMES.map((n, i) => <option key={n} value={i}>{n}{i === current ? ' (current)' : ''}</option>)}</select></Field>
    <Field label="Why? (recorded in the audit trail)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || Number(value) === current || reason.trim().length < 5} onClick={() => void go()}>{busy ? 'Saving…' : 'Change priority'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div>;
}
