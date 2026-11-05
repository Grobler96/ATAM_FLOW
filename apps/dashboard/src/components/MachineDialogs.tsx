import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { dateTime } from '../lib/format';
import { href } from '../router';
import { KIND_LABEL, loadImpact, mcAction, type DowntimeRow, type Impact, type MachineStatusRow } from '../lib/machines';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const isoLocal = (s: string) => (s ? new Date(s).toISOString() : null);

// What the downtime puts at risk, and what can be done about it. Shown after reporting and from the machine card.
export function ImpactPanel({ impact, onReplan, replanning }: { impact: Impact; onReplan?: () => void; replanning?: boolean }) {
  return (
    <div className="stack" style={{ gap: 10 }}>
      <div className="row wrap" style={{ gap: 14 }}><b>{impact.steps.length} job(s)</b><span className="muted">{impact.units} units · {(impact.minutes / 60).toFixed(1)} h of work</span>{impact.at_risk > 0 && <Status tone="critical">{impact.at_risk} at risk</Status>}</div>
      {impact.steps.length > 0 && <div style={{ maxHeight: 180, overflow: 'auto' }}><table className="table"><thead><tr><th>Order</th><th>Due</th><th className="r">Units</th><th>Planned</th></tr></thead><tbody>{impact.steps.map((s) => <tr key={s.step_id}><td><a className="mono" href={href('orders/' + s.order_ref.replace('#', ''))}>{s.order_ref}</a> <span className="dim">{s.customer}</span>{s.at_risk && <> <Status tone={s.already_late ? 'critical' : 'high'} plain>{s.already_late ? 'late' : 'at risk'}</Status></>}</td>
        <td>{s.due_date ? new Date(s.due_date).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }) : '—'}</td><td className="r num">{s.units ?? '—'}</td><td className="dim">{s.planned_start ? dateTime(s.planned_start) : 'not planned'}</td></tr>)}</tbody></table></div>}
      <h3>What you can do</h3>
      <ul className="plain">{impact.options.map((o, i) => <li key={i}>{o.text}</li>)}</ul>
      <p className="dim">Not calculated yet: {impact.not_calculated.join(' and ')}.</p>
      {onReplan && <div className="row"><Button variant="primary" icon="production" disabled={replanning} onClick={onReplan}>{replanning ? 'Re-planning…' : 'Re-plan production now'}</Button><a className="btn" href="#/exceptions">See the issue raised</a></div>}
    </div>);
}

// Report a breakdown, planned maintenance, reduced capacity or a machine taken offline.
export function ReportDowntimeDialog({ machine, onClose, onReplan, replanning }: { machine?: string; onClose: () => void; onReplan: () => void; replanning: boolean }) {
  const machines = useView<MachineStatusRow>('ui_machine_status'); const toast = useToast();
  const [mid, setMid] = useState(machine ?? ''); const [kind, setKind] = useState('breakdown'); const [reason, setReason] = useState(''); const [started, setStarted] = useState(''); const [back, setBack] = useState(''); const [pct, setPct] = useState('50');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [res, setRes] = useState<Record<string, any> | null>(null);
  const m = machines.rows.find((x) => x.machine_id === mid);
  async function go() {
    setBusy(true); setErr(null);
    const r: any = await mcAction('report_downtime', { machine_id: mid, kind, reason, started: started ? isoLocal(started) : '', expected_back: back ? isoLocal(back) : '', capacity_factor: kind === 'limited' ? Number(pct) / 100 : 0 });
    setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not record the downtime.')); return; }
    void refreshAll(); toast.push({ tone: 'good', title: `${r.machine_code}: ${r.current ? 'downtime recorded' : 'maintenance scheduled'}`, body: r.replan_needed ? 'Production needs re-planning to move work off this machine.' : undefined }); setRes(r);
  }
  if (res) return (
    <Modal open onClose={onClose} title={`${res.machine_code}: ${res.current ? 'impact of the downtime' : 'maintenance scheduled'}`}>
      <div className="stack">{res.impact?.ok !== false && res.impact ? <ImpactPanel impact={res.impact as Impact} onReplan={res.replan_needed ? onReplan : undefined} replanning={replanning} /> : <p className="dim">Impact could not be worked out.</p>}
        {!res.replan_needed && res.current && <p className="dim">This machine is still plannable (reduced capacity is shown but the planner still schedules it at full speed), so re-planning is not forced.</p>}
        <div className="row"><Button variant="ghost" onClick={onClose}>Close</Button></div></div>
    </Modal>);
  return (
    <Modal open onClose={onClose} title="Report machine downtime">
      <div className="stack">
        <Field label="Machine"><select className="select" value={mid} onChange={(e) => setMid(e.target.value)}><option value="">Choose a machine…</option>{machines.rows.filter((x) => x.is_active).map((x) => <option key={x.machine_id} value={x.machine_id}>{x.code} · {x.name}{x.status !== 'operational' ? ` (${x.status})` : ''}</option>)}</select></Field>
        <Field label="What is happening"><select className="select" value={kind} onChange={(e) => setKind(e.target.value)}>{Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
        {kind === 'limited' && <Field label={`Running at ${pct}% of normal speed`}><input type="range" min={10} max={90} step={5} value={pct} onChange={(e) => setPct(e.target.value)} /></Field>}
        <Field label="Reason"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. main motor failed, scheduled service" /></Field>
        <div className="row wrap"><Field label="Started (blank = now; a future time schedules it)"><input className="input" type="datetime-local" value={started} onChange={(e) => setStarted(e.target.value)} /></Field><Field label="Expected back (optional)"><input className="input" type="datetime-local" value={back} onChange={(e) => setBack(e.target.value)} /></Field></div>
        {m && m.status !== 'operational' && started === '' && <div className="callout" role="status">{m.code} already shows as {m.status}. Update or end that downtime first.</div>}
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || !mid || reason.trim().length < 3} onClick={() => void go()}>{busy ? 'Saving…' : 'Record and show impact'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>);
}

// End a downtime ("back in service") or cancel a scheduled one, with a note of what was done.
export function ResolveDowntimeDialog({ d, onClose, onReplan, replanning }: { d: DowntimeRow; onClose: () => void; onReplan: () => void; replanning: boolean }) {
  const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [res, setRes] = useState<Record<string, any> | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r: any = await mcAction('resolve_downtime', { id: d.id, reason: note }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not end the downtime.')); return; } void refreshAll(); toast.push({ tone: 'good', title: r.was_current ? `${d.machine_code} is back in service` : 'Scheduled maintenance cancelled' }); setRes(r); }
  if (res) return <Modal open onClose={onClose} title={`${d.machine_code} saved`}><div className="stack"><p>{res.replan_needed ? 'Production was planned without this machine. Re-plan so it can take work again.' : 'Nothing else needs doing.'}</p><div className="row">{res.replan_needed && <Button variant="primary" disabled={replanning} onClick={onReplan}>{replanning ? 'Re-planning…' : 'Re-plan production now'}</Button>}<Button variant="ghost" onClick={onClose}>Close</Button></div></div></Modal>;
  return (<Modal open onClose={onClose} title={d.is_current ? `${d.machine_code}: back in service` : `Cancel scheduled ${d.kind} on ${d.machine_code}`}><div className="stack">
    <p>{KIND_LABEL[d.kind]}: {d.reason}. {d.is_current ? `Down for ${d.hours.toFixed(1)} h.` : ''}</p>
    <div className="row wrap">{(d.is_current ? ['Repaired, test run OK', 'Service complete', 'Part fitted'] : ['Service rescheduled', 'No longer needed']).map((p) => <button key={p} className="chip" onClick={() => setNote(p)}>{p}</button>)}</div>
    <Field label="What was done (kept in the audit trail)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>{err && <Err m={err} />}
    <div className="row"><Button variant="primary" disabled={busy || note.trim().length < 3} onClick={() => void go()}>{busy ? 'Saving…' : d.is_current ? 'Back in service' : 'Cancel it'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}

export function UpdateReturnDialog({ d, onClose }: { d: DowntimeRow; onClose: () => void }) {
  const [back, setBack] = useState(d.expected_back_at ? new Date(d.expected_back_at).toISOString().slice(0, 16) : ''); const [why, setWhy] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [impact, setImpact] = useState<Impact | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r: any = await mcAction('update_downtime', { id: d.id, expected_back: back ? isoLocal(back) : '', reason: why }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not update it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${d.machine_code}: return time updated` }); setImpact(r.impact ?? null); }
  if (impact) return <Modal open onClose={onClose} title={`${d.machine_code}: updated impact`}><div className="stack"><ImpactPanel impact={impact} /><div className="row"><Button variant="ghost" onClick={onClose}>Close</Button></div></div></Modal>;
  return (<Modal open onClose={onClose} title={`${d.machine_code}: change return time`}><div className="stack"><Field label="Expected back"><input className="input" type="datetime-local" value={back} onChange={(e) => setBack(e.target.value)} /></Field>
    <Field label="Why is it changing?"><input className="input" value={why} onChange={(e) => setWhy(e.target.value)} placeholder="e.g. part delayed" /></Field>{err && <Err m={err} />}
    <div className="row"><Button variant="primary" disabled={busy || why.trim().length < 3} onClick={() => void go()}>{busy ? 'Saving…' : 'Update and show impact'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}

// Impact of a downtime that is already recorded.
export function ImpactDialog({ m, onClose, onReplan, replanning }: { m: MachineStatusRow; onClose: () => void; onReplan: () => void; replanning: boolean }) {
  const dts = useView<DowntimeRow>('ui_machine_downtime'); const [imp, setImp] = useState<Impact | null | undefined>(undefined);
  const d = dts.rows.find((x) => x.id === m.downtime_id);
  useEffect(() => { let live = true; void loadImpact(m.machine_id, d?.started_at ?? null, d?.expected_back_at ?? null, m.capacity_factor).then((r) => { if (live) setImp(r); }); return () => { live = false; }; }, [m.machine_id, d?.started_at, d?.expected_back_at, m.capacity_factor]);
  return (<Modal open onClose={onClose} title={`${m.code}: impact`}><div className="stack">{imp === undefined ? <p className="dim">Working it out…</p> : imp === null ? <p className="dim" role="alert">The impact could not be worked out.</p> : <ImpactPanel impact={imp} onReplan={m.capacity_factor === 0 ? onReplan : undefined} replanning={replanning} />}<div className="row"><Button variant="ghost" onClick={onClose}>Close</Button></div></div></Modal>);
}

// Add a machine or edit one; retiring needs a reason.
export function MachineDialog({ id, onClose }: { id?: string; onClose: () => void }) {
  const all = useView<MachineStatusRow>('ui_machine_status'); const cur = id ? all.rows.find((x) => x.machine_id === id) : undefined; const toast = useToast();
  const [f, setF] = useState(() => ({ code: cur?.code ?? '', name: cur?.name ?? '', method: cur?.method_code ?? 'embroidery', uph: cur?.units_per_hour ? String(cur.units_per_hour) : '', location: cur?.location ?? '', type: cur?.machine_type ?? '', notes: cur?.notes ?? '', backups: (cur?.backup_codes ?? []).join(', '), active: cur?.is_active ?? true, reason: '' }));
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const set = (p: Partial<typeof f>) => setF((x) => ({ ...x, ...p }));
  async function go() {
    setBusy(true); setErr(null);
    const machine = { id, code: f.code, name: f.name, method_code: f.method, units_per_hour: f.uph, location: f.location, machine_type: f.type, notes: f.notes, backup_codes: f.backups.split(',').map((s) => s.trim()).filter(Boolean), ...(id ? { is_active: f.active, reason: f.reason } : {}) };
    const r: any = await mcAction('upsert_machine', { machine }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not save the machine.')); return; }
    void refreshAll(); toast.push({ tone: 'good', title: r.created ? `${f.code.toUpperCase()} added` : `${r.code} saved`, body: r.replan_needed ? 'Re-plan production so the planner uses the change.' : undefined, href: undefined }); onClose();
  }
  return (<Modal open onClose={onClose} title={id ? `Edit ${cur?.code ?? 'machine'}` : 'Add a machine'}><div className="stack">
    <div className="row wrap"><Field label="Code"><input className="input mono" value={f.code} disabled={!!id} onChange={(e) => set({ code: e.target.value.toUpperCase() })} placeholder="EMB-2" /></Field><Field label="Name"><input className="input" value={f.name} onChange={(e) => set({ name: e.target.value })} /></Field></div>
    <div className="row wrap"><Field label="Decoration method"><select className="select" value={f.method} disabled={!!id} onChange={(e) => set({ method: e.target.value })}>{['embroidery', 'dtf', 'dtg', 'uv', 'heat_press', 'packing'].map((m) => <option key={m} value={m}>{m.replace('_', ' ')}</option>)}</select></Field><Field label="Units per hour"><input className="input" type="number" min={1} value={f.uph} onChange={(e) => set({ uph: e.target.value })} /></Field></div>
    <div className="row wrap"><Field label="Location"><input className="input" value={f.location} onChange={(e) => set({ location: e.target.value })} /></Field><Field label="Type / model"><input className="input" value={f.type} onChange={(e) => set({ type: e.target.value })} /></Field></div>
    <Field label="Backup machines (codes, comma separated)"><input className="input mono" value={f.backups} onChange={(e) => set({ backups: e.target.value.toUpperCase() })} placeholder="EMB-2" /></Field>
    <Field label="Notes"><input className="input" value={f.notes} onChange={(e) => set({ notes: e.target.value })} /></Field>
    {id && <label className="check"><input type="checkbox" checked={f.active} onChange={(e) => set({ active: e.target.checked })} />In service (untick to retire it)</label>}
    {id && !f.active && cur?.is_active && <Field label="Why is it being retired?"><input className="input" value={f.reason} onChange={(e) => set({ reason: e.target.value })} /></Field>}
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || !f.name.trim() || (!id && !f.code.trim())} onClick={() => void go()}>{busy ? 'Saving…' : 'Save machine'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}
