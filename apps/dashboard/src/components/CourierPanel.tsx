import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { money } from '../lib/domain';
import { COURIER_EVENTS, COURIER_LABEL, opsAction, type CourierClaim, type CourierEvent } from '../lib/orderChanges';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const BAD = ['lost', 'damaged', 'failed_attempt', 'wrong_address', 'delayed', 'partial'];

// Courier history for one consignment, entered by hand (no courier connection), plus any claims against the courier.
export function CourierPanel({ code }: { code: string }) {
  const ev = useView<CourierEvent>('ui_courier_events'); const cl = useView<CourierClaim>('ui_courier_claims'); const { canAct, senior } = useCtx();
  const evs = ev.rows.filter((e) => e.movement_code === code).sort((a, b) => b.at.localeCompare(a.at)); const claims = cl.rows.filter((c) => c.movement_code === code);
  const [dlg, setDlg] = useState<null | 'event' | 'claim' | { claim: CourierClaim }>(null); const close = () => { setDlg(null); void refreshAll(); };
  const last = evs.find((e) => e.event !== 'note');
  return (
    <section className="stack" aria-label="Courier">
      <div className="row wrap"><h3 className="grow">Courier</h3>{last && BAD.includes(last.event) && <Status tone="critical">{COURIER_LABEL[last.event]}</Status>}<Button size="sm" disabled={!canAct} title={canAct ? '' : 'Your role cannot record courier events'} onClick={() => setDlg('event')}>Record courier event</Button><Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can open claims'} onClick={() => setDlg('claim')}>Open claim</Button></div>
      {evs.length === 0 ? <p className="dim">Nothing recorded. Courier tracking is not connected: add events here as you hear from the courier.</p> : <ul className="plain">{evs.map((e) => <li key={e.id}><span className="dim">{dateTime(e.at)}</span> · <b>{COURIER_LABEL[e.event] ?? e.event}</b> <span className="dim">({e.direction})</span>{e.note ? ` · ${e.note}` : ''}</li>)}</ul>}
      {claims.map((c) => <div key={c.id} className="row wrap" style={{ gap: 10 }}><b className="mono">{c.claim_ref}</b><span className="muted grow">{c.kind} · {money(c.value_claimed)}{c.amount_recovered != null ? ` · recovered ${money(c.amount_recovered)}` : ''} · {c.status} ({c.age_days} d)</span>{['open', 'submitted'].includes(c.status) && <Button size="sm" disabled={!senior} onClick={() => setDlg({ claim: c })}>Update</Button>}</div>)}
      {dlg === 'event' && <EventDialog code={code} onClose={close} />}
      {dlg === 'claim' && <ClaimDialog code={code} onClose={close} />}
      {dlg && typeof dlg === 'object' && <ClaimUpdateDialog claim={dlg.claim} onClose={close} />}
    </section>
  );
}

function useAct(onClose: () => void, title: string) {
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function run(action: string, params: Record<string, unknown>) { setBusy(true); setErr(null); const r = await opsAction(action, params); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title, body: String(r.note ?? 'Saved.') }); onClose(); }
  return { busy, err, run };
}

function EventDialog({ code, onClose }: { code: string; onClose: () => void }) {
  const [event, setEvent] = useState('delivered'); const [direction, setDirection] = useState('outbound'); const [note, setNote] = useState(''); const a = useAct(onClose, 'Courier event recorded');
  const needs = !['collected', 'delivered'].includes(event);
  return <Modal open onClose={onClose} title={`Courier event for ${code}`}><div className="stack">
    <Field label="What happened"><select className="select" value={event} onChange={(e) => setEvent(e.target.value)}>{COURIER_EVENTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
    <Field label="Which leg"><select className="select" value={direction} onChange={(e) => setDirection(e.target.value)}><option value="outbound">To the producer</option><option value="return">Back from the producer</option><option value="customer">To the customer</option></select></Field>
    <Field label={needs ? 'What did the courier say? (required)' : 'Note (optional)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
    {a.err && <Err m={a.err} />}
    <div className="row"><Button variant="primary" disabled={a.busy || (needs && note.trim().length < 5)} onClick={() => void a.run('courier_event', { code, event, direction, note })}>{a.busy ? 'Saving…' : 'Record'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>;
}

function ClaimDialog({ code, onClose }: { code: string; onClose: () => void }) {
  const [kind, setKind] = useState('lost'); const [value, setValue] = useState(''); const [note, setNote] = useState(''); const a = useAct(onClose, 'Claim opened');
  return <Modal open onClose={onClose} title={`Claim against the courier for ${code}`}><div className="stack">
    <Field label="Kind"><select className="select" value={kind} onChange={(e) => setKind(e.target.value)}>{['lost', 'damaged', 'late', 'partial'].map((k) => <option key={k} value={k}>{k}</option>)}</select></Field>
    <Field label="Value claimed (£)"><input className="input" inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} /></Field>
    <Field label="What is being claimed for (required)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
    <p className="dim">This records the claim here so it is not forgotten. Submit it to the courier yourself, then mark it submitted.</p>
    {a.err && <Err m={a.err} />}
    <div className="row"><Button variant="primary" disabled={a.busy || !(Number(value) > 0) || note.trim().length < 5} onClick={() => void a.run('claim_open', { code, kind, value: Number(value), note })}>{a.busy ? 'Saving…' : 'Open claim'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>;
}

function ClaimUpdateDialog({ claim, onClose }: { claim: CourierClaim; onClose: () => void }) {
  const [status, setStatus] = useState('submitted'); const [rec, setRec] = useState(''); const [note, setNote] = useState(''); const a = useAct(onClose, 'Claim updated');
  const needsNote = status === 'rejected' || status === 'closed';
  return <Modal open onClose={onClose} title={`Update ${claim.claim_ref}`}><div className="stack">
    <Field label="New status"><select className="select" value={status} onChange={(e) => setStatus(e.target.value)}><option value="submitted">Submitted to the courier</option><option value="paid">Paid</option><option value="rejected">Rejected</option><option value="closed">Closed without payment</option></select></Field>
    {status === 'paid' && <Field label="Amount recovered (£)"><input className="input" inputMode="decimal" value={rec} onChange={(e) => setRec(e.target.value)} /></Field>}
    <Field label={needsNote ? 'Why? (required)' : 'Note (optional)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
    {a.err && <Err m={a.err} />}
    <div className="row"><Button variant="primary" disabled={a.busy || (status === 'paid' && rec === '') || (needsNote && note.trim().length < 5)} onClick={() => void a.run('claim_update', { claim: claim.claim_ref, status, recovered: rec === '' ? null : Number(rec), note })}>{a.busy ? 'Saving…' : 'Update'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>;
}
