import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, EmptyState, Field, Panel, Segmented, Skeleton, Status } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { useRpcList } from '../data/useRpcList';
import { useCtx } from '../data/context';
import { ScopeBanner } from '../components/ScopeBanner';
import { AssignDialog, RecCard } from '../components/CrewParts';
import { METHOD_LABEL } from '../lib/domain';
import { crewAction, clock, LEVEL_LABEL, localDay, WEEKDAYS, ymd, type Away, type CrewDay, type HistoryRow, type QualityRow, type RecPlanRow, type Shift, type Skill, type Worker } from '../lib/crew';
import type { MachineRow, QueueRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

export function CrewPage() {
  const [mode, setMode] = useState<'day' | 'workers'>('day');
  return (
    <div className="stack" style={{ gap: 16 }}>
      <ScopeBanner />
      <div className="page-head"><div><h1>Crew</h1><p>Who does what, on which machine. Suggestions come from skill, past work, speed, quality, who is free and who is away. You always decide.</p></div>
        <Segmented label="Crew view" value={mode} options={[{ id: 'day', label: 'Day board' }, { id: 'workers', label: 'Workers' }]} onChange={setMode} /></div>
      {mode === 'day' ? <DayBoard /> : <Workers />}
    </div>
  );
}

function DayBoard() {
  const { canAct } = useCtx(); const toast = useToast(); const queue = useView<QueueRow>('ui_production_queue');
  const [day, setDay] = useState(ymd(new Date())); const crew = useRpcList<CrewDay>('ui_crew_day', { p_day: day }, [day], 30_000);
  const [plan, setPlan] = useState<RecPlanRow[] | null>(null); const [planBusy, setPlanBusy] = useState(false); const [assign, setAssign] = useState<QueueRow | null>(null); const [sel, setSel] = useState<Record<string, boolean>>({}); const [err, setErr] = useState<string | null>(null);
  const open = useMemo(() => queue.rows.filter((q) => !q.operator_id && ['pending', 'ready'].includes(q.status) && !q.blocked_reason && localDay(q.planned_start) === day).sort((a, b) => (a.planned_start ?? '').localeCompare(b.planned_start ?? '')), [queue.rows, day]);
  async function suggestAll() { setPlanBusy(true); setErr(null); const { supabase } = await import('../lib/api'); const { data, error } = await supabase.rpc('ui_rec_plan', { p_day: day }); setPlanBusy(false); if (error) { setErr(error.message); return; } const rows = (data ?? []) as RecPlanRow[]; setPlan(rows); setSel(Object.fromEntries(rows.filter((r) => r.best).map((r) => [r.step_id, true]))); }
  async function applySelected() {
    if (!plan) return; setPlanBusy(true); setErr(null); let n = 0;
    for (const r of plan) { if (!sel[r.step_id] || !r.best) continue; const q = queue.rows.find((x) => x.step_id === r.step_id); if (!q) continue;
      const res = await crewAction('assign_job', { order_id: q.order_id, method: q.method_code, operator_id: r.best.operator_id, recommended_id: r.best.operator_id, reason: '' }); if (res.ok === false) { setErr(`${r.order_ref}: ${String(res.error)}`); break; } n += 1; }
    setPlanBusy(false); if (n) toast.push({ tone: 'good', title: `${n} job(s) assigned`, body: 'You can change any of them.' }); setPlan(null); void refreshAll(); crew.reload();
  }
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="row wrap" style={{ gap: 12 }}><Field label="Day"><input className="input" type="date" value={day} onChange={(e) => { setDay(e.target.value); setPlan(null); }} /></Field>
        <Button disabled={!canAct || planBusy || open.length === 0} title={open.length === 0 ? 'No open jobs that day' : ''} onClick={() => void suggestAll()}>{planBusy ? 'Working…' : `Suggest for all ${open.length} open job(s)`}</Button></div>
      {err && <Err m={err} />}
      {plan && <Panel title="Suggested for the day" icon="production">
        {plan.length === 0 ? <p className="dim">Nothing to suggest.</p> : <div className="stack" style={{ gap: 10 }}>
          {plan.map((r) => <div key={r.step_id} className="panel stack" style={{ padding: 10, gap: 6 }}>
            <div className="row wrap" style={{ gap: 10 }}><label className="row" style={{ gap: 6 }}><input type="checkbox" checked={!!sel[r.step_id]} disabled={!r.best} onChange={(e) => setSel((p) => ({ ...p, [r.step_id]: e.target.checked }))} aria-label={`Use suggestion for ${r.order_ref}`} /><b className="mono">{r.order_ref}</b></label><span className="muted">{r.customer} · {METHOD_LABEL[r.method_code] ?? r.method_code} · {clock(r.planned_start)}</span></div>
            {r.best ? <RecCard o={r.best} customer={r.customer} job={{ order_ref: r.order_ref, method_code: r.method_code }} top onPick={() => setSel((p) => ({ ...p, [r.step_id]: true }))} /> : <p className="dim">Nobody is available for this job. Check skills, shifts and time away.</p>}
          </div>)}
          <div className="row"><Button variant="primary" disabled={planBusy || !Object.values(sel).some(Boolean)} onClick={() => void applySelected()}>Assign the ticked suggestions</Button><Button variant="ghost" onClick={() => setPlan(null)}>Close</Button></div></div>}
      </Panel>}
      <Panel title="Workers today" icon="user">
        {crew.loading ? <Skeleton h={90} /> : crew.rows.length === 0 ? <EmptyState icon="user" title="No workers yet">Add them on the Workers tab.</EmptyState> : <div className="row wrap" style={{ gap: 12, alignItems: 'stretch' }}>
          {crew.rows.map((w) => { const pct = w.capacity > 0 ? Math.min(100, Math.round((w.booked / w.capacity) * 100)) : 0; return (
            <div key={w.operator_id} className="panel stack" style={{ padding: 12, gap: 6, minWidth: 220, flex: '1 1 220px', opacity: w.away ? 0.6 : 1 }}>
              <div className="row" style={{ gap: 8 }}><b className="grow">{w.name}</b>{w.away ? <Status tone="low" plain>Away{w.away_reason ? `: ${w.away_reason}` : ''}</Status> : w.capacity === 0 ? <Status tone="low" plain>Not on shift</Status> : <span className="dim">{w.booked} of {w.capacity} min</span>}</div>
              {w.capacity > 0 && <div style={{ height: 6, borderRadius: 3, background: 'var(--border)' }} aria-label={`${pct}% booked`}><div style={{ width: pct + '%', height: 6, borderRadius: 3, background: w.booked > w.capacity ? 'var(--critical, #e5484d)' : 'var(--accent, #4f8dff)' }} /></div>}
              {w.jobs.length === 0 ? <span className="dim">Nothing assigned.</span> : w.jobs.map((j) => <div key={j.step_id} className="row wrap" style={{ gap: 6 }}><span className="mono">{j.order_ref}</span><span className="muted grow">{METHOD_LABEL[j.method_code] ?? j.method_code} · {j.machine ?? 'no machine'}</span><span className="dim">{clock(j.planned_start)} · {j.minutes} min</span></div>)}
            </div>); })}
        </div>}
      </Panel>
      <Panel title={`Jobs nobody has yet (${open.length})`} icon="orders">
        {open.length === 0 ? <p className="dim">Every planned job that day has someone. Planned jobs appear here once production is planned.</p> : <div className="stack" style={{ gap: 4 }}>
          {open.map((q) => <div key={q.step_id} className="row wrap" style={{ gap: 10 }}><b className="mono">{q.order_ref}</b><span className="muted grow">{q.customer_name} · {METHOD_LABEL[q.method_code] ?? q.method_code} · {q.machine_code ?? 'no machine'}</span><span className="dim">{clock(q.planned_start)} · {Math.round((q.est_minutes ?? 0) + (q.setup_minutes ?? 0))} min</span><Button size="sm" disabled={!canAct} onClick={() => setAssign(q)}>Assign…</Button></div>)}</div>}
      </Panel>
      {assign && <AssignDialog step={assign} onClose={() => { setAssign(null); void refreshAll(); crew.reload(); }} />}
    </div>
  );
}

function Workers() {
  const { senior } = useCtx(); const ws = useView<Worker>('ui_operators'); const skills = useView<Skill>('ui_operator_skills'); const shifts = useView<Shift>('ui_operator_shifts'); const away = useView<Away>('ui_operator_absence'); const machines = useView<MachineRow>('ui_machines');
  const hist = useRpcList<HistoryRow>('ui_operator_history', {}, [], 0); const qual = useRpcList<QualityRow>('ui_operator_quality', {}, [], 0);
  const [id, setId] = useState<string | null>(null); const [add, setAdd] = useState(false); const w = ws.rows.find((x) => x.id === id) ?? null;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="row"><span className="muted grow">Workers, what they can run, their hours and time away. Skills start from what the production records show; please check them.</span><Button disabled={!senior} title={senior ? '' : 'Only a manager or admin can add workers'} onClick={() => setAdd(true)}>Add a worker</Button></div>
      <div className="row wrap" style={{ gap: 12, alignItems: 'flex-start' }}>
        <div className="stack" style={{ gap: 6, minWidth: 220, flex: '0 0 240px' }}>
          {ws.rows.map((x) => <button key={x.id} className={`chip ${x.id === id ? 'on' : ''}`} style={{ justifyContent: 'flex-start' }} onClick={() => setId(x.id)}>{x.name}{!x.is_active ? ' (off)' : ''}</button>)}
        </div>
        <div className="stack grow" style={{ gap: 14, minWidth: 300 }}>
          {!w ? <p className="dim">Choose a worker.</p> : <WorkerDetail w={w} skills={skills.rows.filter((s) => s.operator_id === w.id)} shifts={shifts.rows.filter((s) => s.operator_id === w.id)} away={away.rows.filter((s) => s.operator_id === w.id)} hist={hist.rows.filter((h) => h.operator_id === w.id)} qual={qual.rows.filter((h) => h.operator_id === w.id)} machines={machines.rows.filter((m) => m.is_active)} senior={senior} />}
        </div>
      </div>
      {add && <WorkerForm onClose={() => { setAdd(false); void refreshAll(); }} />}
    </div>
  );
}

function WorkerDetail({ w, skills, shifts, away, hist, qual, machines, senior }: { w: Worker; skills: Skill[]; shifts: Shift[]; away: Away[]; hist: HistoryRow[]; qual: QualityRow[]; machines: MachineRow[]; senior: boolean }) {
  const toast = useToast(); const { canAct } = useCtx(); const [err, setErr] = useState<string | null>(null); const [edit, setEdit] = useState(false); const [awayDlg, setAwayDlg] = useState(false);
  const methods = Object.keys(METHOD_LABEL);
  const level = (kind: string, ref: string) => skills.find((s) => s.kind === kind && s.ref === ref)?.level ?? -1;
  async function setLevel(kind: 'method' | 'machine', ref: string, v: string) { setErr(null); const r = v === '' ? await crewAction('worker_skill_clear', { operator_id: w.id, kind, ref }) : await crewAction('worker_skill', { operator_id: w.id, kind, ref, level: Number(v) }); if (r.ok === false) setErr(String(r.error ?? 'That did not work.')); else void refreshAll(); }
  async function setShift(d: number, start: string, end: string) { setErr(null); const r = await crewAction('worker_shift', { operator_id: w.id, weekday: d, start: start || null, end: end || null }); if (r.ok === false) setErr(String(r.error ?? 'That did not work.')); else { toast.push({ tone: 'good', title: 'Shift saved', body: '' }); void refreshAll(); } }
  return (
    <div className="stack" style={{ gap: 14 }}>
      <div className="row wrap" style={{ gap: 10 }}><h2 style={{ margin: 0 }}>{w.name}</h2>{!w.is_active && <Status tone="low">Switched off</Status>}<span className="dim grow">History name: {w.history_name ?? w.name}</span><Button size="sm" disabled={!senior} onClick={() => setEdit(true)}>Edit worker</Button></div>
      {err && <Err m={err} />}
      <Panel title="What they can run">
        <div className="stack" style={{ gap: 6 }}>
          {methods.map((m) => { const h = hist.find((x) => x.method_code === m); const q = qual.find((x) => x.method_code === m); return (
            <div key={m} className="row wrap" style={{ gap: 10 }}><b style={{ minWidth: 120 }}>{METHOD_LABEL[m]}</b>
              <select className="select" aria-label={`${w.name} ${METHOD_LABEL[m]}`} disabled={!senior} value={level('method', m) < 0 ? '' : String(level('method', m))} onChange={(e) => void setLevel('method', m, e.target.value)}><option value="">Not set</option>{LEVEL_LABEL.map((l, i) => <option key={l} value={i}>{l}</option>)}</select>
              <span className="dim grow">{h ? `${h.records} past records, ${h.units} units, last ${h.last_done ?? '—'}` : 'No past records'}{q && q.fail_pct != null ? ` · ${q.fail_pct}% of checked units failed (${q.checks} checks)` : ''}</span></div>); })}
          {machines.length > 0 && <h3 style={{ marginTop: 8 }}>Machines</h3>}
          {machines.map((m) => <div key={m.id} className="row wrap" style={{ gap: 10 }}><b style={{ minWidth: 120 }}>{m.name}</b><select className="select" aria-label={`${w.name} ${m.name}`} disabled={!senior} value={level('machine', m.id) < 0 ? '' : String(level('machine', m.id))} onChange={(e) => void setLevel('machine', m.id, e.target.value)}><option value="">Not set</option>{LEVEL_LABEL.map((l, i) => <option key={l} value={i}>{l}</option>)}</select></div>)}
        </div>
        <p className="dim">"Not set" for a process means they are not offered that work once any skill is recorded. "Not allowed" blocks it. Levels start from their past production records.</p>
      </Panel>
      <Panel title="Hours">
        <p className="dim" style={{ marginTop: 0 }}>{shifts.length === 0 ? 'No personal hours set: the standard working hours apply.' : 'Personal hours set. Days left blank are days off.'}</p>
        <div className="stack" style={{ gap: 4 }}>{WEEKDAYS.map((d, i) => { const s = shifts.find((x) => x.weekday === i + 1); return <ShiftRow key={d + (s?.id ?? '')} label={d} start={s?.start_time?.slice(0, 5) ?? ''} end={s?.end_time?.slice(0, 5) ?? ''} disabled={!senior} onSave={(a, b) => void setShift(i + 1, a, b)} />; })}</div>
      </Panel>
      <Panel title="Time away" actions={<Button size="sm" disabled={!canAct} onClick={() => setAwayDlg(true)}>Record time away</Button>}>
        {away.length === 0 ? <p className="dim">None recorded.</p> : <div className="stack" style={{ gap: 4 }}>{away.map((a) => <div key={a.id} className="row wrap" style={{ gap: 10 }}><span>{a.from_date} to {a.to_date}</span><span className="muted grow">{a.reason}</span><Button size="sm" variant="ghost" disabled={!canAct} onClick={() => void crewAction('worker_absence_remove', { id: a.id }).then(() => refreshAll())}>Remove</Button></div>)}</div>}
      </Panel>
      {edit && <WorkerForm worker={w} onClose={() => { setEdit(false); void refreshAll(); }} />}
      {awayDlg && <AwayForm w={w} onClose={() => { setAwayDlg(false); void refreshAll(); }} />}
    </div>
  );
}

function ShiftRow({ label, start, end, disabled, onSave }: { label: string; start: string; end: string; disabled: boolean; onSave: (a: string, b: string) => void }) {
  const [a, setA] = useState(start); const [b, setB] = useState(end); const dirty = a !== start || b !== end;
  return <div className="row wrap" style={{ gap: 8 }}><b style={{ width: 40 }}>{label}</b><input className="input" type="time" aria-label={`${label} start`} style={{ width: 110 }} value={a} disabled={disabled} onChange={(e) => setA(e.target.value)} /><span>to</span><input className="input" type="time" aria-label={`${label} end`} style={{ width: 110 }} value={b} disabled={disabled} onChange={(e) => setB(e.target.value)} />{dirty && <Button size="sm" disabled={disabled || (!!a !== !!b)} onClick={() => onSave(a, b)}>Save</Button>}</div>;
}

function WorkerForm({ worker, onClose }: { worker?: Worker; onClose: () => void }) {
  const toast = useToast(); const [name, setName] = useState(worker?.name ?? ''); const [hist, setHist] = useState(worker?.history_name ?? ''); const [active, setActive] = useState(worker?.is_active ?? true); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r = await crewAction('worker_save', { id: worker?.id ?? null, name, history_name: hist, active }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title: 'Worker saved', body: name }); onClose(); }
  return <Modal open onClose={onClose} title={worker ? `Edit ${worker.name}` : 'Add a worker'}><div className="stack">
    <Field label="Name"><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></Field>
    <Field label="Name used in DecoNetwork's production records (to find their past work)"><input className="input" value={hist} onChange={(e) => setHist(e.target.value)} placeholder={name} /></Field>
    {worker && <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} /> Working here (untick when they leave)</label>}
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || name.trim().length < 2} onClick={() => void go()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>;
}

function AwayForm({ w, onClose }: { w: Worker; onClose: () => void }) {
  const toast = useToast(); const [from, setFrom] = useState(ymd(new Date())); const [to, setTo] = useState(ymd(new Date())); const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r = await crewAction('worker_absence', { operator_id: w.id, from, to, reason }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title: 'Time away recorded', body: 'Check their jobs on those days.' }); onClose(); }
  return <Modal open onClose={onClose} title={`Time away for ${w.name}`}><div className="stack"><div className="row wrap" style={{ gap: 10 }}><Field label="First day"><input className="input" type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field><Field label="Last day"><input className="input" type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field></div>
    <Field label="Reason (optional)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>{err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || !from || !to} onClick={() => void go()}>Save</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>;
}
