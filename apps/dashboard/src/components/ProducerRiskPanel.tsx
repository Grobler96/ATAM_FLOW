import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { loadRecovery, prAction, RATING_TONE, type Recovery, type RiskRow } from '../lib/producerRisk';
import { ReasonDialog } from './WarehouseDialogs';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

// How risky is this producer, why, what do they hold of ours, and what to do about it. Suspending is a manager/admin decision.
export function ProducerRiskPanel({ id }: { id: string }) {
  const risk = useView<RiskRow>('ui_producer_risk'); const { senior, canAct } = useCtx(); const r = risk.rows.find((x) => x.producer_id === id);
  const [rec, setRec] = useState<Recovery | null | undefined>(undefined); const [dlg, setDlg] = useState<null | 'suspend' | 'resume' | 'contact' | 'limits'>(null);
  useEffect(() => { let live = true; setRec(undefined); void loadRecovery(id).then((x) => { if (live) setRec(x); }); return () => { live = false; }; }, [id, r?.risk_score, r?.is_suspended]);
  if (!r) return null;
  return (
    <section className="stack" aria-label="Risk and recovery">
      <div className="row wrap"><h3 className="grow">Risk and recovery</h3>{r.is_suspended && <Status tone="critical">Suspended</Status>}<Status tone={RATING_TONE[r.risk_rating] ?? 'good'}>{r.risk_rating} risk · {r.risk_score}</Status></div>
      {r.is_suspended && <div className="callout" role="status"><b>No new work can be sent.</b> {r.suspended_reason}{r.suspended_at ? ` (since ${dateTime(r.suspended_at)})` : ''}</div>}
      {r.reasons.length > 0 ? <ul className="plain">{r.reasons.map((x) => <li key={x}>{x}</li>)}</ul> : <p className="dim">Nothing is counting against this producer.</p>}
      <p className="dim">Holding {r.units_held} unit(s) (about £{Math.round(r.value_held)}), {r.open_movements} open consignment(s){r.max_concurrent_jobs ? `, limit ${r.max_concurrent_jobs}` : ''}. Last contact: {r.last_contact_at ? `${dateTime(r.last_contact_at)}${r.last_contact_note ? ` (${r.last_contact_note})` : ''}` : 'never recorded'}. Emergency contact: {r.emergency_contact ? `${r.emergency_contact}${r.emergency_phone ? ' ' + r.emergency_phone : ''}` : 'not recorded'}. Backups: {(r.backup_codes ?? []).join(', ') || 'none set'}.</p>
      {rec === undefined ? <p className="dim">Working out the recovery options…</p> : rec && <div className="stack" style={{ gap: 4 }}><h3>If they fail</h3><ul className="plain">{rec.options.map((o, i) => <li key={i}>{o.text}</li>)}</ul>{rec.held.length > 0 && <div className="stack" style={{ gap: 2 }}>{rec.held.map((h) => <div key={h.movement_code} className="row" style={{ gap: 10 }}><a className="mono" href={'#/producers/movement/' + h.movement_code}>{h.movement_code}</a><span className="muted grow">{h.units} unit(s) · {h.status.replace(/_/g, ' ')}</span>{h.is_overdue && <Status tone="critical" plain>overdue</Status>}</div>)}</div>}</div>}
      <div className="row wrap"><Button size="sm" disabled={!canAct} onClick={() => setDlg('contact')}>Record contact</Button><Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can change limits'} onClick={() => setDlg('limits')}>Limits and contacts</Button>
        {r.is_suspended ? <Button size="sm" variant="primary" disabled={!senior} title={senior ? '' : 'Only a manager or admin can resume a producer'} onClick={() => setDlg('resume')}>Allow work again</Button> : <Button size="sm" variant="danger" disabled={!senior} title={senior ? '' : 'Only a manager or admin can suspend a producer'} onClick={() => setDlg('suspend')}>Suspend</Button>}</div>
      {dlg === 'suspend' && <ReasonDialog path="producer-risk" title={`Suspend ${r.name}`} intro="No new consignments can be created for them until you allow work again. Goods they already hold are not affected: use the recovery options." confirm="Suspend" action="suspend" params={{ producer_id: id }} presets={['Lost or damaged goods', 'Repeatedly late', 'Not responding', 'Quality problems']} onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg === 'resume' && <ReasonDialog path="producer-risk" title={`Allow ${r.name} to take work again`} intro={`They were suspended for: ${r.suspended_reason ?? 'no reason recorded'}.`} confirm="Allow work" action="resume" params={{ producer_id: id }} presets={['Cause found and fixed', 'Agreed new process with them']} onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg === 'contact' && <ContactDialog id={id} onClose={() => setDlg(null)} />}{dlg === 'limits' && <LimitsDialog r={r} onClose={() => setDlg(null)} />}
    </section>);
}

function ContactDialog({ id, onClose }: { id: string; onClose: () => void }) {
  const toast = useToast(); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r: any = await prAction('record_contact', { producer_id: id, note }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not save it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: 'Contact recorded' }); onClose(); }
  return (<Modal open onClose={onClose} title="Record contact with the producer"><div className="stack"><Field label="What was said or agreed"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Spoke to Rita, back Friday" /></Field>{err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || note.trim().length < 3} onClick={() => void go()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}

function LimitsDialog({ r, onClose }: { r: RiskRow; onClose: () => void }) {
  const toast = useToast(); const [name, setName] = useState(r.emergency_contact ?? ''); const [phone, setPhone] = useState(r.emergency_phone ?? ''); const [backups, setBackups] = useState((r.backup_codes ?? []).join(', ')); const [max, setMax] = useState(r.max_concurrent_jobs ? String(r.max_concurrent_jobs) : ''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const res: any = await prAction('set_limits', { producer_id: r.producer_id, emergency_contact: name, emergency_phone: phone, backup_codes: backups.split(',').map((x) => x.trim()).filter(Boolean), max_jobs: max }); setBusy(false); if (res.ok === false) { setErr(String(res.error ?? 'Could not save it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: 'Limits and contacts saved' }); onClose(); }
  return (<Modal open onClose={onClose} title={`Limits and contacts: ${r.name}`}><div className="stack">
    <div className="row wrap"><Field label="Emergency contact"><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></Field><Field label="Emergency phone"><input className="input" value={phone} onChange={(e) => setPhone(e.target.value)} /></Field></div>
    <Field label="Backup producers (codes, comma separated)"><input className="input mono" value={backups} onChange={(e) => setBackups(e.target.value.toUpperCase())} placeholder="e.g. STW" /></Field>
    <Field label="Most open consignments at once (blank = no limit)"><input className="input" type="number" min={1} value={max} onChange={(e) => setMax(e.target.value)} /></Field>{err && <Err m={err} />}
    <div className="row"><Button variant="primary" disabled={busy} onClick={() => void go()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}
