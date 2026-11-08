import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Skeleton, Status } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { METHOD_LABEL } from '../lib/domain';
import { exceptionActionTo } from '../lib/api';
import { crewAction, loadMachines, loadOptions, sayIt, type MachineOpt, type RecOption } from '../lib/crew';
import type { QueueRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

// One suggestion: who, how strong, and why, in plain words. Accepting it needs no reason; choosing someone else does.
export function RecCard({ o, job, top, onPick, busy, customer }: { o: RecOption; job: { order_ref: string; method_code: string }; top: boolean; onPick: () => void; busy?: boolean; customer?: string | null }) {
  const standard = sayIt(o, job); const [text, setText] = useState(standard); const [asking, setAsking] = useState(false); const [note, setNote] = useState<string | null>(null);
  // Optional: have the wording rewritten in a more natural voice. If that is not available the standard wording stays and nothing breaks.
  async function again() {
    setAsking(true); setNote(null);
    const r = await exceptionActionTo('crew-wording', 'reword', { order_ref: job.order_ref, process: job.method_code, worker: o.name, reasons: o.reasons, warnings: o.warnings, customer: customer ?? '', fallback: standard });
    setAsking(false); const t = (r as { text?: string }).text;
    if (r.ok !== false && t) setText(t); else setNote('Could not reword that just now.');
  }
  return (
    <div className="panel stack" style={{ padding: 12, gap: 6, borderColor: top ? 'var(--accent, #4f8dff)' : undefined, opacity: o.eligible ? 1 : 0.7 }}>
      <div className="row wrap" style={{ gap: 8 }}><b className="grow">{o.name}</b>{top && o.eligible && <Status tone="good" plain>Suggested</Status>}{!o.eligible && <Status tone="low" plain>Not available</Status>}<span className="dim">score {o.score}</span></div>
      <p style={{ margin: 0 }}>{text}</p>
      {o.reasons.length > 0 && <ul className="plain dim" style={{ margin: 0 }}>{o.reasons.map((r, i) => <li key={i}>{r}</li>)}</ul>}
      {o.warnings.length > 0 && <ul className="plain" style={{ margin: 0, color: 'var(--high, #d98a00)' }}>{o.warnings.map((w, i) => <li key={i}>{w}</li>)}</ul>}
      <div className="row wrap" style={{ gap: 8 }}><Button size="sm" variant={top ? 'primary' : ''} disabled={busy || !o.eligible} onClick={onPick}>{top ? 'Use this suggestion' : `Choose ${o.name.split(' ')[0]} instead`}</Button>
        {o.eligible && <Button size="sm" variant="ghost" disabled={asking} onClick={() => void again()}>{asking ? 'Rewording…' : 'Say it another way'}</Button>}{note && <span className="dim">{note}</span>}</div>
    </div>
  );
}

// Assign a job: see the suggestions, take one, or choose someone else (with a reason), and optionally pick the machine.
export function AssignDialog({ step, onClose }: { step: QueueRow; onClose: () => void }) {
  const toast = useToast(); const queue = useView<QueueRow>('ui_production_queue');
  const [opts, setOpts] = useState<RecOption[] | null>(null); const [machines, setMachines] = useState<MachineOpt[]>([]); const [reason, setReason] = useState(''); const [pick, setPick] = useState<RecOption | null>(null);
  const [mach, setMach] = useState(step.assigned_machine_id ?? ''); const [mreason, setMreason] = useState(step.assignment_reason ?? ''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const cur = queue.rows.find((q) => q.step_id === step.step_id) ?? step;
  useEffect(() => { let live = true; void loadOptions(step.step_id).then((o) => { if (live) setOpts(o); }); void loadMachines(step.step_id).then((m) => { if (live) setMachines(m); }); return () => { live = false; }; }, [step.step_id]);
  const best = opts?.find((o) => o.eligible) ?? null; const job = { order_ref: step.order_ref, method_code: step.method_code };
  async function assign(o: RecOption | null) {
    setBusy(true); setErr(null);
    const r = await crewAction('assign_job', { order_id: step.order_id, method: step.method_code, operator_id: o?.operator_id ?? null, recommended_id: best?.operator_id ?? null, reason });
    setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); if (r.needs_reason) setPick(o); return; }
    toast.push({ tone: 'good', title: o ? `${o.name} assigned` : 'Worker cleared', body: `${step.order_ref} · ${step.method_code.replace(/_/g, ' ')}` }); setPick(null); setReason(''); void refreshAll();
  }
  async function saveMachine() {
    setBusy(true); setErr(null); const r = await crewAction('assign_machine', { order_id: step.order_id, method: step.method_code, machine_id: mach || null, reason: mreason }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title: 'Machine choice saved', body: 'Re-plan production to apply it.' }); void refreshAll();
  }
  const chosenElsewhere = (o: RecOption) => !!best && o.operator_id !== best.operator_id;
  return (
    <Modal open onClose={onClose} title={`${step.order_ref} · ${METHOD_LABEL[step.method_code] ?? step.method_code}`}>
      <div className="stack" style={{ gap: 12 }}>
        <p className="muted">{cur.operator_name ? `Now assigned to ${cur.operator_name}.` : 'Nobody is assigned yet.'} Suggestions use who can run it, who has done it before, who is free and who is away.</p>
        {opts === null ? <Skeleton h={120} /> : opts.length === 0 ? <p className="dim">No workers are set up yet. Add them on the Crew page.</p> : <div className="stack" style={{ gap: 8 }}>{opts.map((o) => <RecCard key={o.operator_id} o={o} job={job} customer={step.customer_name} top={!!best && o.operator_id === best.operator_id} busy={busy} onPick={() => (chosenElsewhere(o) ? setPick(o) : void assign(o))} />)}</div>}
        {pick && <div className="callout stack" style={{ gap: 6 }}><b>Why {pick.name.split(' ')[0]} instead of {best?.name.split(' ')[0]}?</b><input className="input" aria-label="Why a different person" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="For example: needed on the rush order" /><div className="row"><Button variant="primary" disabled={busy || reason.trim().length < 5} onClick={() => void assign(pick)}>Assign {pick.name.split(' ')[0]}</Button><Button variant="ghost" onClick={() => { setPick(null); setReason(''); }}>Cancel</Button></div></div>}
        {cur.operator_id && <div><Button size="sm" variant="ghost" disabled={busy} onClick={() => void assign(null)}>Clear the assignment</Button></div>}
        <h3>Machine</h3>
        {machines.length === 0 ? <p className="dim">No machine does this process.</p> : <div className="stack" style={{ gap: 6 }}>
          <Field label="Run it on"><select className="select" value={mach} onChange={(e) => setMach(e.target.value)}><option value="">Let the planner choose</option>{machines.map((m) => <option key={m.machine_id} value={m.machine_id} disabled={!m.available}>{m.name}{m.planned_pick ? ' (planner pick)' : ''}{!m.available ? ` — ${m.status.replace(/_/g, ' ')}` : ` — ${m.load_minutes} min booked that day`}</option>)}</select></Field>
          {mach !== (cur.assigned_machine_id ?? '') && mach && <Field label="Why this machine? (recorded)"><input className="input" value={mreason} onChange={(e) => setMreason(e.target.value)} /></Field>}
          <div><Button size="sm" disabled={busy || mach === (cur.assigned_machine_id ?? '') || (!!mach && mreason.trim().length < 5)} onClick={() => void saveMachine()}>Save machine choice</Button></div></div>}
        {err && <Err m={err} />}
        <div className="row"><Button variant="ghost" onClick={onClose}>Done</Button></div>
      </div>
    </Modal>
  );
}
