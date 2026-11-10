import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { CAUSES, DEFECTS, GATES, OUTCOMES, humanise, qcAction, applicableItems, checklistProblem, type CriterionRow, type QcCheckRow, type ReworkRow } from '../lib/quality';
import { QC_MAX_FILES, QC_TYPES, qcPhotoProblem, uploadQcPhoto, type QcEvidence } from '../lib/qcPhotos';
import type { OrderLineRow, OrderRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const num = (v: string) => Math.max(0, Math.floor(Number(v) || 0));

// Record a quality check: how many units, the checklist, and (if any failed) what is wrong and why. Failed units open a rework job automatically.
export function RecordCheckDialog({ orderId, pending, onClose }: { orderId?: string; pending?: QcCheckRow; onClose: () => void }) {
  const orders = useView<OrderRow>('ui_orders'); const lines = useView<OrderLineRow>('ui_order_lines'); const crit = useView<CriterionRow>('ui_qc_criteria'); const toast = useToast();
  const [oid, setOid] = useState(pending?.order_id ?? orderId ?? ''); const [gate, setGate] = useState(pending?.gate ?? 'final'); const [line, setLine] = useState(pending?.order_line_id ?? ''); const [checked, setChecked] = useState(pending?.units_checked ? String(pending.units_checked) : ''); const [failed, setFailed] = useState('0');
  const [ticks, setTicks] = useState<Record<string, boolean>>({}); const [itemNotes, setItemNotes] = useState<Record<string, string>>({}); const [defect, setDefect] = useState(''); const [cause, setCause] = useState(''); const [notes, setNotes] = useState(''); const [evidence, setEvidence] = useState(''); const [pct, setPct] = useState('');
  const [files, setFiles] = useState<File[]>([]); const [uploaded, setUploaded] = useState<QcEvidence[]>([]); const [fileErr, setFileErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [done, setDone] = useState<Record<string, any> | null>(null);
  const order = orders.rows.find((o) => o.id === oid); const myLines = lines.rows.filter((l) => l.order_id === oid); const methods = Array.from(new Set((line ? myLines.filter((l) => l.id === line) : myLines).flatMap((l) => l.decoration_methods ?? [])));
  const list = useMemo(() => applicableItems(crit.rows, gate, methods), [crit.rows, gate, methods.join(',')]);
  const evidenceLinks = evidence.split(/\s+/).filter((u) => /^https?:\/\//.test(u)); const problem = checklistProblem(list, ticks, itemNotes, notes, evidenceLinks.length + files.length + uploaded.length > 0);
  const failedCount = num(failed); const anyFailedTick = list.some((c) => ticks[c.id] === false);
  function addFiles(picked: FileList | null) {
    const next = [...files]; const problems: string[] = [];
    for (const f of Array.from(picked ?? [])) { const bad = qcPhotoProblem(f); if (bad) problems.push(bad); else if (next.length + uploaded.length >= QC_MAX_FILES) { problems.push(`Only ${QC_MAX_FILES} files can be added to one check.`); break; } else next.push(f); }
    setFiles(next); setFileErr(problems.length ? problems.join(' ') : null);
  }
  async function go() {
    setBusy(true); setErr(null);
    // upload first, one at a time; a file that went up is kept (and not sent again) if a later one fails
    const done = [...uploaded]; const left = [...files];
    while (left.length) {
      const up = await uploadQcPhoto(left[0], order?.order_ref ?? '');
      if (!up.ok) { setUploaded(done); setFiles(left); setBusy(false); setErr(up.error); return; }
      done.push(up.evidence); left.shift();
    }
    setUploaded(done); setFiles([]);
    const results = list.filter((c) => c.id in ticks).map((c) => ({ criterion_id: c.id, passed: ticks[c.id], ...(itemNotes[c.id]?.trim() ? { note: itemNotes[c.id].trim() } : {}) }));
    const r: any = await qcAction('record_check', { check_id: pending?.id, order_id: oid, gate, order_line_id: line || undefined, units_checked: num(checked), units_failed: failedCount, results, defect_type: defect, cause, notes, checkpoint_pct: pct || undefined, evidence: [...done, ...evidenceLinks.map((url) => ({ url, name: 'Quality evidence' }))] });
    setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not record the check.')); return; }
    void refreshAll(); toast.push({ tone: r.status === 'failed' ? 'info' : 'good', title: `${r.check_ref}: ${r.status}`, body: r.rework_ref ? `Rework job ${r.rework_ref} opened for ${failedCount} unit(s).` : undefined }); setDone(r);
  }
  if (done) return (<Modal open onClose={onClose} title={`${done.check_ref}: ${done.status === 'passed' ? 'passed' : 'failed'}`}><div className="stack"><p>{done.status === 'passed' ? `${done.order_ref} passed this check.` : `${failedCount} unit(s) failed. Rework job ${done.rework_ref} is open: fix the units, then they are re-checked before the order can finish.`}</p><div className="row">{done.rework_id && <a className="btn" href="#/quality?view=rework">Open rework jobs</a>}<Button variant="primary" onClick={onClose}>Done</Button></div></div></Modal>);
  return (
    <Modal open onClose={onClose} title={pending ? `Complete ${pending.check_ref}` : 'Record a quality check'}>
      <div className="stack">
        {!pending && <Field label="Order"><select className="select" value={oid} onChange={(e) => { setOid(e.target.value); setLine(''); }}><option value="">Choose an order…</option>{orders.rows.filter((o) => !o.shipped_at).sort((a, b) => (a.order_status === 'quality_check' ? -1 : 0) - (b.order_status === 'quality_check' ? -1 : 0)).slice(0, 400).map((o) => <option key={o.id} value={o.id}>{o.order_ref} · {o.customer_name}{o.order_status === 'quality_check' ? ' (in quality check)' : ''}</option>)}</select></Field>}
        {order && <p className="muted">{order.order_ref} · {order.customer_name} · {order.total_units} units</p>}
        <div className="row wrap"><Field label="Stage"><select className="select" value={gate} disabled={!!pending} onChange={(e) => setGate(e.target.value)}>{GATES.map((g) => <option key={g.id} value={g.id}>{g.label}</option>)}</select></Field>
          {myLines.length > 0 && <Field label="Line (optional)"><select className="select" value={line} onChange={(e) => setLine(e.target.value)}><option value="">Whole order</option>{myLines.map((l) => <option key={l.id} value={l.id}>{l.sku} · {[l.colour, l.size].filter(Boolean).join(' ')}</option>)}</select></Field>}
          {gate === 'in_line' && <Field label="At % of the run"><select className="select" value={pct} onChange={(e) => setPct(e.target.value)}><option value="">—</option><option value="10">10%</option><option value="50">50%</option><option value="90">90%</option></select></Field>}</div>
        <div className="row wrap"><Field label="Units checked"><input className="input" type="number" min={1} value={checked} onChange={(e) => setChecked(e.target.value)} /></Field><Field label="Units that failed"><input className="input" type="number" min={0} value={failed} onChange={(e) => setFailed(e.target.value)} /></Field></div>
        <Field label="Checklist (tick what is right; cross what is wrong)">
          <div className="panel" style={{ padding: 8 }}>{list.length === 0 ? <p className="dim">No checklist items apply to this method and stage. A manager can add them on the Checklist tab.</p> : list.map((c) => <div key={c.id} className="stack" style={{ gap: 2, padding: '3px 0' }}><div className="row" style={{ gap: 8 }}><span className="grow">{c.name}{c.is_critical && <> <Status tone="high" plain>critical</Status></>}{c.is_required && <span className="dim"> · required</span>}{c.needs_photo && <span className="dim"> · photo if it fails</span>}</span>
            <button type="button" className={`chip ${ticks[c.id] === true ? 'on' : ''}`} aria-pressed={ticks[c.id] === true} aria-label={`${c.name}: pass`} onClick={() => setTicks((t) => ({ ...t, [c.id]: true }))}>Pass</button>
            <button type="button" className={`chip ${ticks[c.id] === false ? 'on' : ''}`} aria-pressed={ticks[c.id] === false} aria-label={`${c.name}: fail`} onClick={() => { setTicks((t) => ({ ...t, [c.id]: false })); if (failedCount === 0) setFailed('1'); }}>Fail</button></div>
            {c.description && <span className="dim">{c.description}</span>}
            {ticks[c.id] === false && <input className="input" aria-label={`Note for ${c.name}`} placeholder="What is wrong?" value={itemNotes[c.id] ?? ''} onChange={(e) => setItemNotes((n) => ({ ...n, [c.id]: e.target.value }))} />}</div>)}</div></Field>
        {(failedCount > 0 || anyFailedTick) && <div className="stack"><div className="callout" role="status"><Status tone="high" plain>{failedCount} failed</Status> A rework job will be opened for these units, and the order cannot complete until they are fixed and re-checked.</div>
          <div className="row wrap"><Field label="What is wrong"><select className="select" value={defect} onChange={(e) => setDefect(e.target.value)}><option value="">Choose…</option>{DEFECTS.map((d) => <option key={d} value={d}>{humanise(d)}</option>)}</select></Field><Field label="Likely cause"><select className="select" value={cause} onChange={(e) => setCause(e.target.value)}><option value="">Choose…</option>{CAUSES.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select></Field></div></div>}
        <div className="stack" style={{ gap: 4 }}>
          <Field label="Photo files from this device (optional)"><input type="file" accept={QC_TYPES.join(',')} multiple onChange={(e) => { addFiles(e.target.files); e.target.value = ''; }} /></Field>
          {(uploaded.length > 0 || files.length > 0) && <ul className="dim" style={{ margin: 0, paddingLeft: 18 }}>{uploaded.map((u, i) => <li key={'u' + i}>{u.name} (uploaded)</li>)}{files.map((f, i) => <li key={f.name + i}>{f.name} <button type="button" className="btn ghost sm" aria-label={`Remove ${f.name}`} onClick={() => setFiles(files.filter((_, j) => j !== i))}>Remove</button></li>)}</ul>}
          {fileErr && <span className="bad" role="alert">{fileErr}</span>}</div>
        <Field label="Photos (paste links, optional)"><input className="input" value={evidence} onChange={(e) => setEvidence(e.target.value)} placeholder="https://…" /></Field>
        <Field label="Notes"><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        {problem && <p className="dim" role="status">{problem}</p>}{err && <Err m={err} />}
        <div className="row"><Button variant={failedCount > 0 ? 'danger' : 'primary'} disabled={busy || !!problem || !oid || num(checked) < 1 || (failedCount > 0 && (!defect || !cause))} onClick={() => void go()}>{busy ? 'Saving…' : failedCount > 0 ? 'Record failure and open rework' : 'Record pass'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>);
}

// Open a rework job without a check (for example a customer complaint after dispatch, or a producer return problem).
export function OpenReworkDialog({ onClose }: { onClose: () => void }) {
  const orders = useView<OrderRow>('ui_orders'); const lines = useView<OrderLineRow>('ui_order_lines'); const toast = useToast();
  const [oid, setOid] = useState(''); const [line, setLine] = useState(''); const [units, setUnits] = useState(''); const [defect, setDefect] = useState(''); const [cause, setCause] = useState(''); const [outcome, setOutcome] = useState('redo'); const [notes, setNotes] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const myLines = lines.rows.filter((l) => l.order_id === oid);
  async function go() { setBusy(true); setErr(null); const r: any = await qcAction('open_rework', { order_id: oid, order_line_id: line || undefined, units: num(units), defect_type: defect, cause, outcome, notes }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not open it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${r.rework_ref} opened`, body: r.note }); onClose(); }
  return (<Modal open onClose={onClose} title="Open a rework job"><div className="stack">
    <Field label="Order"><select className="select" value={oid} onChange={(e) => { setOid(e.target.value); setLine(''); }}><option value="">Choose an order…</option>{orders.rows.slice(0, 500).map((o) => <option key={o.id} value={o.id}>{o.order_ref} · {o.customer_name}</option>)}</select></Field>
    {myLines.length > 0 && <Field label="Line (optional)"><select className="select" value={line} onChange={(e) => setLine(e.target.value)}><option value="">Whole order</option>{myLines.map((l) => <option key={l.id} value={l.id}>{l.sku} · {[l.colour, l.size].filter(Boolean).join(' ')}</option>)}</select></Field>}
    <div className="row wrap"><Field label="Units"><input className="input" type="number" min={1} value={units} onChange={(e) => setUnits(e.target.value)} /></Field><Field label="What is wrong"><select className="select" value={defect} onChange={(e) => setDefect(e.target.value)}><option value="">Choose…</option>{DEFECTS.map((d) => <option key={d} value={d}>{humanise(d)}</option>)}</select></Field></div>
    <div className="row wrap"><Field label="Likely cause"><select className="select" value={cause} onChange={(e) => setCause(e.target.value)}><option value="">Choose…</option>{CAUSES.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select></Field><Field label="What is needed"><select className="select" value={outcome} onChange={(e) => setOutcome(e.target.value)}>{OUTCOMES.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select></Field></div>
    <Field label="Notes"><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>{err && <Err m={err} />}
    <div className="row"><Button variant="primary" disabled={busy || !oid || num(units) < 1 || !defect || !cause} onClick={() => void go()}>{busy ? 'Opening…' : 'Open rework job'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}

export type ReworkStep = 'start' | 'complete' | 'cancel' | 'replacement';
// Move a rework job along: start, complete (fixed + scrapped), cancel (reason), or update its replacement garments.
export function ReworkStepDialog({ job, step, onClose }: { job: ReworkRow; step: ReworkStep; onClose: () => void }) {
  const { senior } = useCtx(); const toast = useToast(); const [assigned, setAssigned] = useState(job.assigned_to ?? ''); const [fixed, setFixed] = useState(String(job.units)); const [scrap, setScrap] = useState('0'); const [noRepl, setNoRepl] = useState(false); const [note, setNote] = useState(''); const [reason, setReason] = useState(''); const [rstat, setRstat] = useState(job.replacement_status === 'needed' ? 'ordered' : 'received');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const payload = step === 'start' ? { assigned_to: assigned } : step === 'complete' ? { units_fixed: num(fixed), units_scrapped: num(scrap), no_replacement: noRepl, note } : step === 'cancel' ? { reason } : { status: rstat, note };
  async function go() { setBusy(true); setErr(null); const r: any = await qcAction('rework', { id: job.id, step, payload }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${job.rework_ref}: ${step === 'complete' ? 'finished' : step === 'start' ? 'started' : step === 'cancel' ? 'cancelled' : 'replacement updated'}`, body: r.recheck_ref ? `${r.recheck_ref} is waiting: re-check the fixed units.` : undefined }); onClose(); }
  const title = { start: `Start ${job.rework_ref}`, complete: `Finish ${job.rework_ref}`, cancel: `Cancel ${job.rework_ref}`, replacement: `Replacement garments for ${job.rework_ref}` }[step];
  const ready = step === 'start' ? true : step === 'complete' ? num(fixed) + num(scrap) === job.units && (!(num(scrap) > 0 && noRepl) || note.trim().length >= 3) : step === 'cancel' ? reason.trim().length >= 3 : rstat !== 'not_needed' || note.trim().length >= 3;
  return (<Modal open onClose={onClose} title={title}><div className="stack">
    <p className="muted">{job.order_ref} · {job.units} unit(s) · {humanise(job.defect_type)} · {humanise(job.cause)}</p>
    {step === 'start' && <Field label="Who is doing it?"><input className="input" value={assigned} onChange={(e) => setAssigned(e.target.value)} placeholder="Name" /></Field>}
    {step === 'complete' && <><div className="row wrap"><Field label="Fixed"><input className="input" type="number" min={0} value={fixed} onChange={(e) => setFixed(e.target.value)} /></Field><Field label="Scrapped (beyond repair)"><input className="input" type="number" min={0} value={scrap} onChange={(e) => setScrap(e.target.value)} /></Field></div>
      <p className="dim">Fixed plus scrapped must equal {job.units}. Fixed units go back for a re-check. Scrapped units need replacement garments unless you say otherwise.</p>
      {num(scrap) > 0 && <label className="check"><input type="checkbox" checked={noRepl} disabled={!senior} onChange={(e) => setNoRepl(e.target.checked)} />No replacement needed{!senior ? ' (manager or admin only)' : ''}</label>}
      <Field label={noRepl ? 'Why no replacement is needed (required)' : 'Notes (optional)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field></>}
    {step === 'cancel' && <Field label="Why is it being cancelled?"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. customer accepted as is" /></Field>}
    {step === 'replacement' && <><Field label="Replacement garments"><select className="select" value={rstat} onChange={(e) => setRstat(e.target.value)}><option value="ordered">Ordered, not here yet</option><option value="received">Received</option>{senior && <option value="not_needed">Not needed</option>}</select></Field><Field label={rstat === 'not_needed' ? 'Why not needed (required)' : 'Note (for example the PO number)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field></>}
    {err && <Err m={err} />}<div className="row"><Button variant={step === 'cancel' ? 'danger' : 'primary'} disabled={busy || !ready} onClick={() => void go()}>{busy ? 'Saving…' : title.split(' ')[0]}</Button><Button variant="ghost" onClick={onClose}>Close</Button></div></div></Modal>);
}

export function CriterionDialog({ item, onClose }: { item?: CriterionRow; onClose: () => void }) {
  const toast = useToast(); const [name, setName] = useState(item?.name ?? ''); const [method, setMethod] = useState(item?.method_code ?? ''); const [desc, setDesc] = useState(item?.description ?? ''); const [active, setActive] = useState(item?.is_active ?? true);
  const [gates, setGates] = useState<string[]>(item?.gates ?? []); const [required, setRequired] = useState(item?.is_required ?? true); const [critical, setCritical] = useState(item?.is_critical ?? false); const [photo, setPhoto] = useState(item?.needs_photo ?? false);
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r: any = await qcAction('set_criterion', { id: item?.id, method, name, description: desc, active, gates, required, critical, needs_photo: photo }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not save it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: 'Checklist updated' }); onClose(); }
  return (<Modal open onClose={onClose} title={item ? 'Edit checklist item' : 'Add a checklist item'}><div className="stack">
    {item?.is_placeholder && <div className="callout" role="status">This is a starter item, not your standard yet. Saving it makes it yours.</div>}
    <Field label="What to check"><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Backing trimmed" /></Field>
    <Field label="Applies to"><select className="select" value={method} disabled={!!item} onChange={(e) => setMethod(e.target.value)}><option value="">Every method</option>{['embroidery', 'dtf', 'dtg', 'uv', 'heat_press'].map((m) => <option key={m} value={m}>{humanise(m)}</option>)}</select></Field>
    <Field label="Stages (none ticked = every stage)"><div className="row wrap">{GATES.map((g) => <label key={g.id} className="check"><input type="checkbox" checked={gates.includes(g.id)} onChange={(e) => setGates((cur) => e.target.checked ? [...cur, g.id] : cur.filter((x) => x !== g.id))} />{g.label}</label>)}</div></Field>
    <Field label="What good looks like"><input className="input" value={desc} onChange={(e) => setDesc(e.target.value)} /></Field>
    <div className="row wrap"><label className="check"><input type="checkbox" checked={required} onChange={(e) => setRequired(e.target.checked)} />Must be answered</label><label className="check"><input type="checkbox" checked={critical} onChange={(e) => setCritical(e.target.checked)} />Critical</label><label className="check"><input type="checkbox" checked={photo} onChange={(e) => setPhoto(e.target.checked)} />Photo needed if it fails</label></div>
    {item && <label className="check"><input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />In use</label>}{err && <Err m={err} />}
    <div className="row"><Button variant="primary" disabled={busy || name.trim().length < 3} onClick={() => void go()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}
