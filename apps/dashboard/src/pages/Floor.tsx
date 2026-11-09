import { useEffect, useState } from 'react';
import { useToast } from '../ui/overlay';
import { Skeleton } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { useCtx } from '../data/context';
import { ScopeBanner } from '../components/ScopeBanner';
import { METHOD_LABEL } from '../lib/domain';
import { clock, crewAction, type TimeRow, type Worker } from '../lib/crew';
import type { QueueRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)', fontSize: 18 }} role="alert">{m}</div>;
const big = { minHeight: 64, fontSize: 20, padding: '0 24px' } as const;
const KEY = 'atamflow.floor.worker';

// Tablet screen for the shop floor: pick your name, see your jobs, tap Start, tap Finished. Real times feed the suggestions.
export function FloorPage() {
  const { canAct } = useCtx(); const toast = useToast(); const ws = useView<Worker>('ui_operators'); const queue = useView<QueueRow>('ui_production_queue'); const times = useView<TimeRow>('ui_job_time');
  const [me, setMe] = useState<string | null>(() => { try { return localStorage.getItem(KEY); } catch { return null; } });
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [finish, setFinish] = useState<QueueRow | null>(null); const [units, setUnits] = useState(''); const [note, setNote] = useState(''); const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 30_000); return () => clearInterval(t); }, []);
  const choose = (id: string | null) => { setMe(id); setErr(null); try { if (id) localStorage.setItem(KEY, id); else localStorage.removeItem(KEY); } catch { /* private window */ } };
  const worker = ws.rows.find((w) => w.id === me) ?? null;
  const mine = queue.rows.filter((q) => q.operator_id === me && ['pending', 'ready', 'in_progress'].includes(q.status)).sort((a, b) => (a.planned_start ?? '').localeCompare(b.planned_start ?? ''));
  const running = mine.find((q) => q.status === 'in_progress') ?? null; const next = mine.filter((q) => q.status !== 'in_progress');
  const spare = queue.rows.filter((q) => !q.operator_id && ['pending', 'ready'].includes(q.status) && !q.blocked_reason).sort((a, b) => (a.planned_start ?? '').localeCompare(b.planned_start ?? '')).slice(0, 6);
  async function run(action: string, params: Record<string, unknown>, ok: string) { setBusy(true); setErr(null); const r = await crewAction(action, params); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return false; } toast.push({ tone: 'good', title: ok, body: '' }); void refreshAll(); return true; }
  const elapsed = (q: QueueRow) => { const t = times.rows.find((x) => x.step_id === q.step_id); if (!t?.started_at) return ''; const m = Math.max(0, Math.round((Date.now() - Date.parse(t.started_at)) / 60000)); return `Started ${clock(t.started_at)} · ${m} min`; };
  if (!worker) return (
    <div className="stack" style={{ gap: 16 }}><ScopeBanner /><h1 style={{ fontSize: 28 }}>Who are you?</h1>
      {ws.loading ? <Skeleton h={80} /> : <div className="row wrap" style={{ gap: 12 }}>{ws.rows.filter((w) => w.is_active).map((w) => <button key={w.id} className="btn primary" style={{ ...big, minWidth: 180 }} onClick={() => choose(w.id)}>{w.name}</button>)}</div>}
      {!ws.loading && ws.rows.length === 0 && <p className="dim">No workers are set up yet. A manager adds them on the Crew page.</p>}</div>);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <ScopeBanner />
      <div className="row wrap" style={{ gap: 12 }}><h1 className="grow" style={{ fontSize: 28, margin: 0 }}>{worker.name}</h1><button className="btn" style={{ minHeight: 48 }} onClick={() => choose(null)}>Not you? Switch</button></div>
      {err && <Err m={err} />}
      {!canAct && <div className="callout" role="status">Your login can look but not start jobs. Ask a manager.</div>}
      {running && <div className="panel stack" style={{ padding: 20, gap: 10, borderColor: 'var(--good, #2fb171)' }} aria-label="Running job">
        <div className="row wrap" style={{ gap: 12 }}><b style={{ fontSize: 24 }} className="mono">{running.order_ref}</b><span style={{ fontSize: 18 }}>{running.customer_name}</span><span className="grow" /><span style={{ fontSize: 18 }}>RUNNING</span></div>
        <div style={{ fontSize: 18 }}>{METHOD_LABEL[running.method_code] ?? running.method_code} on {running.machine_code ?? 'machine'} · {running.units} unit(s) planned · {elapsed(running)}</div>
        {finish?.step_id === running.step_id ? <div className="stack" style={{ gap: 10 }}>
          <label className="stack" style={{ gap: 4, fontSize: 18 }}><span>How many did you finish?</span><input className="input" style={{ fontSize: 24, height: 56 }} inputMode="numeric" value={units} onChange={(e) => setUnits(e.target.value)} aria-label="Units finished" /></label>
          {units !== '' && Number(units) < running.units && <label className="stack" style={{ gap: 4, fontSize: 18 }}><span>Fewer than planned: why?</span><input className="input" style={{ fontSize: 20, height: 56 }} value={note} onChange={(e) => setNote(e.target.value)} aria-label="Why fewer" /></label>}
          <div className="row wrap" style={{ gap: 12 }}><button className="btn primary" style={big} disabled={busy || units === '' || (Number(units) < running.units && note.trim().length < 5)} onClick={() => void run('floor_stop', { step_id: running.step_id, units: Number(units), finished: true, note }, 'Job finished').then((ok) => { if (ok) { setFinish(null); setUnits(''); setNote(''); } })}>Confirm finished</button><button className="btn" style={big} onClick={() => setFinish(null)}>Back</button></div></div>
          : <div className="row wrap" style={{ gap: 12 }}><button className="btn primary" style={big} disabled={!canAct || busy} onClick={() => { setFinish(running); setUnits(String(running.units)); setNote(''); }}>Finished</button><button className="btn" style={big} disabled={!canAct || busy} onClick={() => void run('floor_stop', { step_id: running.step_id, units: null, finished: false, note: '' }, 'Stopped for now')}>Stop for now</button></div>}
      </div>}
      <h2 style={{ margin: 0 }}>Your jobs</h2>
      {next.length === 0 ? <p className="dim" style={{ fontSize: 18 }}>{running ? 'Nothing else is lined up for you.' : 'Nothing is assigned to you right now.'}</p> : next.map((q) => (
        <div key={q.step_id} className="panel row wrap" style={{ padding: 16, gap: 12 }}><div className="grow"><b style={{ fontSize: 20 }} className="mono">{q.order_ref}</b> <span style={{ fontSize: 16 }}>{q.customer_name}</span><div className="dim" style={{ fontSize: 16 }}>{METHOD_LABEL[q.method_code] ?? q.method_code} · {q.machine_code ?? 'no machine'} · {q.units} unit(s) · {clock(q.planned_start)}</div></div>
          <button className="btn primary" style={big} disabled={!canAct || busy || !!running} title={running ? 'Finish or stop your running job first' : ''} onClick={() => void run('floor_start', { step_id: q.step_id, operator_id: worker.id }, 'Job started')}>Start</button></div>))}
      {spare.length > 0 && <><h2 style={{ margin: 0 }}>Jobs nobody has yet</h2>{spare.map((q) => (
        <div key={q.step_id} className="panel row wrap" style={{ padding: 12, gap: 12 }}><div className="grow"><b className="mono">{q.order_ref}</b> {q.customer_name}<div className="dim">{METHOD_LABEL[q.method_code] ?? q.method_code} · {q.machine_code ?? 'no machine'} · {clock(q.planned_start)}</div></div>
          <button className="btn" style={{ minHeight: 52, fontSize: 18 }} disabled={!canAct || busy || !!running} onClick={() => void run('floor_start', { step_id: q.step_id, operator_id: worker.id }, 'Job started')}>Take it and start</button></div>))}</>}
    </div>
  );
}
