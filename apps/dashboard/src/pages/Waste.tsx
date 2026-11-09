import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, EmptyState, Field, Panel, Segmented, Skeleton, Status } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { gbp, dateTime } from '../lib/format';
import { PARTIES, SOURCE_LABEL, STAGES, STATUS_LABEL, groupWaste, label, wasteAction, weekly, type Bucket, type WasteCause, type WasteRate, type WasteRow } from '../lib/waste';
import { OrderLink } from '../components/common';

type Mode = 'overview' | 'records';
const tone = (s: WasteRow['status']) => (s === 'approved' ? 'good' : s === 'rejected' ? 'low' : s === 'suggested' ? 'info' : 'high') as 'good' | 'low' | 'info' | 'high';
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

function Bars({ rows, unit = 'value' }: { rows: Bucket[]; unit?: 'value' | 'units' }) {
  const max = Math.max(1, ...rows.map((r) => r[unit]));
  if (!rows.length) return <p className="dim">Nothing approved yet.</p>;
  return <div className="stack" style={{ gap: 4 }}>{rows.slice(0, 8).map((r) => (
    <div key={r.key} className="row" style={{ gap: 8 }}>
      <span style={{ width: 150, flexShrink: 0 }} className="dim">{r.key}</span>
      <div className="grow" style={{ background: 'var(--surface-2, rgba(128,128,128,.15))', borderRadius: 4, height: 14 }}><div style={{ width: `${(100 * r[unit]) / max}%`, background: 'var(--accent, #4c8dff)', height: 14, borderRadius: 4 }} /></div>
      <span className="num" style={{ width: 130, textAlign: 'right' }}>{gbp(r.value)} · {r.units}</span>
    </div>))}</div>;
}

export function WastePage() {
  const ev = useView<WasteRow>('ui_waste_events'), rates = useView<WasteRate>('ui_waste_rates'); const { canAct, senior } = useCtx();
  const [mode, setMode] = useState<Mode>('overview'); const [dlg, setDlg] = useState<null | { k: 'new' } | { k: 'decide'; w: WasteRow } | { k: 'confirm'; w: WasteRow } | { k: 'recover'; w: WasteRow }>(null);
  const toast = useToast(); const [busy, setBusy] = useState(false);
  const rows = ev.rows; const approved = rows.filter((r) => r.status === 'approved');
  const pending = rows.filter((r) => r.status === 'pending_approval'); const suggested = rows.filter((r) => r.status === 'suggested');
  const since = Date.now() - 30 * 86400000; const last30 = approved.filter((r) => Date.parse(r.occurred_at) >= since);
  const tot = (l: WasteRow[]) => l.reduce((a, r) => ({ units: a.units + r.qty, value: a.value + Number(r.value), rec: a.rec + Number(r.recovered_value) }), { units: 0, value: 0, rec: 0 });
  const t30 = tot(last30);
  async function check() { setBusy(true); const r = await wasteAction('waste_suggest', {}); setBusy(false); if (r.ok === false) toast.push({ tone: 'bad', title: String(r.error ?? 'That did not work') }); else { toast.push({ tone: 'good', title: 'Checked. Anything found is under "Suggested".' }); void refreshAll(); } }

  const cols: Column<WasteRow>[] = [
    { id: 'ref', header: 'Record', width: '140px', render: (w) => <b className="mono">{w.waste_ref}</b>, sort: (w) => w.waste_ref, csv: (w) => w.waste_ref },
    { id: 'at', header: 'When', width: '110px', render: (w) => dateTime(w.occurred_at), sort: (w) => w.occurred_at, csv: (w) => w.occurred_at },
    { id: 'st', header: 'Stage', width: '150px', render: (w) => label(STAGES, w.stage), csv: (w) => w.stage },
    { id: 'ca', header: 'Cause', width: '190px', render: (w) => w.cause_label, csv: (w) => w.cause_label },
    { id: 'pa', header: 'Whose fault', width: '100px', render: (w) => label(PARTIES, w.party), csv: (w) => w.party },
    { id: 'o', header: 'Order', width: '100px', render: (w) => (w.order_ref ? <OrderLink r={w.order_ref} /> : <span className="dim">—</span>), csv: (w) => w.order_ref },
    { id: 'de', header: 'Decorator', width: '150px', render: (w) => w.producer_name ?? <span className="dim">—</span>, csv: (w) => w.producer_name },
    { id: 'sku', header: 'SKU', width: '130px', render: (w) => w.sku ?? <span className="dim">—</span>, csv: (w) => w.sku },
    { id: 'q', header: 'Units', width: '70px', align: 'r', render: (w) => <span className="num">{w.qty}</span>, sort: (w) => w.qty, csv: (w) => w.qty },
    { id: 'v', header: 'Cost', width: '90px', align: 'r', render: (w) => <span className="num" title={w.no_cost ? 'No stock cost for this SKU, so the cost is £0' : ''}>{w.no_cost ? '£0 ⚠' : gbp(w.value)}</span>, sort: (w) => Number(w.value), csv: (w) => w.value },
    { id: 'r', header: 'Recovered', width: '90px', align: 'r', render: (w) => <span className="num">{Number(w.recovered_value) ? gbp(w.recovered_value) : '—'}</span>, csv: (w) => w.recovered_value },
    { id: 's', header: 'Status', width: '130px', render: (w) => <Status tone={tone(w.status)}>{STATUS_LABEL[w.status]}</Status>, csv: (w) => w.status },
    { id: 'src', header: 'Source', width: '150px', render: (w) => SOURCE_LABEL[w.source] ?? w.source, csv: (w) => w.source },
    { id: 're', header: 'What happened', width: '320px', render: (w) => w.reason, csv: (w) => w.reason },
    { id: 'a', header: '', width: '200px', render: (w) => (
      <span className="row" style={{ gap: 6 }}>
        {w.status === 'suggested' && <Button size="sm" variant="primary" disabled={!canAct} onClick={(e) => { e.stopPropagation(); setDlg({ k: 'confirm', w }); }}>Review</Button>}
        {w.status === 'pending_approval' && <Button size="sm" variant="primary" disabled={!senior} title={senior ? '' : 'A manager or admin approves this'} onClick={(e) => { e.stopPropagation(); setDlg({ k: 'decide', w }); }}>Decide</Button>}
        {w.status === 'approved' && w.party !== 'us' && <Button size="sm" disabled={!senior} onClick={(e) => { e.stopPropagation(); setDlg({ k: 'recover', w }); }}>Recovery</Button>}
      </span>) },
  ];
  const views: ViewDef<WasteRow>[] = [{ id: 'todo', label: 'Needs action', test: (w) => w.status === 'suggested' || w.status === 'pending_approval' }, { id: 'ok', label: 'Approved', test: (w) => w.status === 'approved' }, { id: 'rej', label: 'Rejected', test: (w) => w.status === 'rejected' }, { id: 'all', label: 'All', test: () => true }];

  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Waste &amp; loss</h1><p>Everything that was lost, spoiled or written off, what it cost, who was responsible and what you got back. Kept apart from stock, which DecoNetwork overwrites.</p></div>
        <div className="row"><Button disabled={busy || !canAct} onClick={() => void check()}>Check for waste</Button><Button variant="primary" disabled={!canAct} onClick={() => setDlg({ k: 'new' })}>Record waste</Button></div></div>
      <Segmented<Mode> label="Waste view" value={mode} onChange={setMode} options={[{ id: 'overview', label: 'Overview' }, { id: 'records', label: `Records${pending.length + suggested.length ? ` (${pending.length + suggested.length} to do)` : ''}` }]} />

      {mode === 'overview' && (ev.loading ? <Skeleton h={200} /> : <>
        <div className="row wrap" style={{ gap: 18 }}>
          {([['Last 30 days', gbp(t30.value), `${t30.units} units`], ['Recovered (30 days)', gbp(t30.rec), t30.value ? `${Math.round((100 * t30.rec) / t30.value)}% of cost` : ''], ['Net loss (30 days)', gbp(t30.value - t30.rec), ''], ['Waiting for approval', String(pending.length), gbp(tot(pending).value)], ['Suggested by the system', String(suggested.length), 'needs a person to confirm']] as const).map(([k, v, s]) => (
            <div key={k} style={{ minWidth: 170 }}><div style={{ fontSize: 24, fontWeight: 600 }}>{v}</div><div className="dim">{k}</div><div className="dim">{s}</div></div>))}
        </div>
        <Panel title="Cost by week" icon="analytics"><Bars rows={weekly(rows).map((b) => ({ ...b, key: 'w/c ' + b.key.slice(5) }))} /></Panel>
        <div className="grid" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(340px, 1fr))', gap: 16 }}>
          <Panel title="By cause" icon="quality"><Bars rows={groupWaste(rows, (r) => r.cause_label)} /></Panel>
          <Panel title="By stage" icon="production"><Bars rows={groupWaste(rows, (r) => label(STAGES, r.stage))} /></Panel>
          <Panel title="By whose fault" icon="user"><Bars rows={groupWaste(rows, (r) => label(PARTIES, r.party))} /></Panel>
          <Panel title="By decorator" icon="producers"><Bars rows={groupWaste(rows, (r) => r.producer_name ?? '')} /></Panel>
          <Panel title="By customer order" icon="orders"><Bars rows={groupWaste(rows, (r) => r.order_ref ?? '')} /></Panel>
          <Panel title="By operator" icon="user"><Bars rows={groupWaste(rows, (r) => r.operator_name ?? '')} /></Panel>
          <Panel title="By machine" icon="production"><Bars rows={groupWaste(rows, (r) => r.machine_name ?? '')} /></Panel>
          <Panel title="By SKU" icon="stock"><Bars rows={groupWaste(rows, (r) => r.sku ?? '')} /></Panel>
        </div>
        <Panel title="Waste rate by decorator" icon="producers">
          <p className="dim" style={{ marginTop: 0 }}>Approved waste as a share of units sent, over the last 90 days. A decorator over the target raises an exception once at least 50 units have been sent. Change the target in Settings (key waste.targets).</p>
          {rates.rows.length === 0 ? <EmptyState icon="producers" title="Nothing sent to decorators yet" /> : <div className="stack" style={{ gap: 4 }}>{rates.rows.map((r) => (
            <div key={r.producer_id} className="row wrap" style={{ gap: 12 }}><b style={{ minWidth: 200 }}>{r.name}</b>
              <Status tone={r.over_target ? 'high' : 'good'} plain>{r.rate_pct == null ? 'no units' : `${r.rate_pct}% (target ${r.target_pct}%)`}</Status>
              <span className="dim">{r.waste_units} of {r.units_sent} units · {gbp(r.waste_value)} · recovered {gbp(r.recovered)}</span></div>))}</div>}
        </Panel>
      </>)}

      {mode === 'records' && (
        <DataTable<WasteRow> rows={rows} columns={cols} rowKey={(w) => w.id} loading={ev.loading} error={ev.error} onRetry={() => void refreshAll()} views={views} defaultTab="todo"
          searchText={(w) => [w.waste_ref, w.order_ref, w.sku, w.producer_name, w.cause_label, w.reason].filter(Boolean).join(' ')} searchPlaceholder="Search record, order, SKU, decorator…" storageKey="waste" exportName="waste"
          defaultSort={{ col: 'at', dir: -1 }} empty={<EmptyState icon="quality" title="No waste records here">Use Record waste, or Check for waste to look through quality, goods-in and courier records.</EmptyState>} />
      )}

      {dlg?.k === 'new' && <NewWasteDialog onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg?.k === 'confirm' && <ConfirmDialog w={dlg.w} onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg?.k === 'decide' && <DecideDialog w={dlg.w} onClose={() => { setDlg(null); void refreshAll(); }} />}
      {dlg?.k === 'recover' && <RecoverDialog w={dlg.w} onClose={() => { setDlg(null); void refreshAll(); }} />}
    </div>
  );
}

function WasteSummary({ w }: { w: WasteRow }) {
  return <div className="callout"><b>{w.waste_ref}</b> · {w.qty} × {w.sku ?? 'item'} · {w.no_cost ? 'no stock cost known' : gbp(w.value)}<br />{label(STAGES, w.stage)} · {w.cause_label} · {label(PARTIES, w.party)}{w.order_ref ? ` · order ${w.order_ref}` : ''}{w.producer_name ? ` · ${w.producer_name}` : ''}<br /><span className="dim">{w.reason}</span></div>;
}

function NewWasteDialog({ onClose }: { onClose: () => void }) {
  const causes = useView<WasteCause>('ui_waste_causes'); const toast = useToast();
  const [f, setF] = useState({ stage: 'warehouse', cause: '', party: '', qty: '', sku: '', order_ref: '', producer_code: '', reason: '', replacement: false });
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const set = (k: keyof typeof f, v: string | boolean) => setF((s) => ({ ...s, [k]: v }));
  const cause = causes.rows.find((c) => c.code === f.cause);
  async function go() {
    setBusy(true); setErr(null);
    const r = await wasteAction('waste_record', { ...f, qty: Number(f.qty), party: f.party || cause?.default_party || '' }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work')); return; }
    toast.push({ tone: 'good', title: r.needs_approval ? 'Recorded. It is over the limit, so a manager has to approve it.' : 'Recorded.' }); onClose();
  }
  return (
    <Modal open onClose={onClose} title="Record waste">
      <div className="stack">
        <div className="row wrap" style={{ gap: 12 }}>
          <Field label="Where did it happen?"><select className="input" value={f.stage} onChange={(e) => set('stage', e.target.value)}>{STAGES.map(([id, l]) => <option key={id} value={id}>{l}</option>)}</select></Field>
          <Field label="Cause"><select className="input" value={f.cause} onChange={(e) => { set('cause', e.target.value); set('party', ''); }}><option value="">Choose…</option>{causes.rows.map((c) => <option key={c.code} value={c.code}>{c.label}</option>)}</select></Field>
          <Field label="Whose fault"><select className="input" value={f.party || cause?.default_party || 'us'} onChange={(e) => set('party', e.target.value)}>{PARTIES.map(([id, l]) => <option key={id} value={id}>{l}</option>)}</select></Field>
        </div>
        <div className="row wrap" style={{ gap: 12 }}>
          <Field label="How many units"><input className="input" inputMode="numeric" value={f.qty} onChange={(e) => set('qty', e.target.value.replace(/\D/g, ''))} /></Field>
          <Field label="SKU (cost is looked up)"><input className="input" value={f.sku} onChange={(e) => set('sku', e.target.value)} /></Field>
          <Field label="Order (optional)"><input className="input" value={f.order_ref} onChange={(e) => set('order_ref', e.target.value)} placeholder="#123456" /></Field>
          <Field label="Decorator code (optional)"><input className="input" value={f.producer_code} onChange={(e) => set('producer_code', e.target.value)} /></Field>
        </div>
        <Field label="What happened (recorded in the audit trail)"><input className="input" value={f.reason} onChange={(e) => set('reason', e.target.value)} /></Field>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.replacement} onChange={(e) => set('replacement', e.target.checked)} /> This order needs replacement stock</label>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || !f.cause || !f.qty || f.reason.trim().length < 5} onClick={() => void go()}>{busy ? 'Saving…' : 'Record waste'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

function ConfirmDialog({ w, onClose }: { w: WasteRow; onClose: () => void }) {
  const toast = useToast(); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go(confirm: boolean) { setBusy(true); setErr(null); const r = await wasteAction('waste_confirm', { ref: w.waste_ref, confirm, reason: note }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work')); return; } toast.push({ tone: 'good', title: confirm ? 'Confirmed as waste.' : 'Dismissed.' }); onClose(); }
  return (
    <Modal open onClose={onClose} title="Suggested waste">
      <div className="stack"><p>The system found this in your records. It only counts as waste once you confirm it.</p><WasteSummary w={w} />
        <Field label="Note (needed if you dismiss it)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>{err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy} onClick={() => void go(true)}>Confirm as waste</Button><Button disabled={busy || note.trim().length < 5} onClick={() => void go(false)}>Not waste</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div>
    </Modal>
  );
}

function DecideDialog({ w, onClose }: { w: WasteRow; onClose: () => void }) {
  const toast = useToast(); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go(approve: boolean) { setBusy(true); setErr(null); const r = await wasteAction('waste_decide', { ref: w.waste_ref, approve, reason: note }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work')); return; } toast.push({ tone: 'good', title: approve ? 'Approved.' : 'Rejected.' }); onClose(); }
  async function repl() { setBusy(true); setErr(null); const r = await wasteAction('waste_replacement', { ref: w.waste_ref }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work')); return; } toast.push({ tone: 'good', title: 'Replacement requested.' }); onClose(); }
  return (
    <Modal open onClose={onClose} title="Approve waste">
      <div className="stack"><p>This is over the approval limit, so it needs a manager.</p><WasteSummary w={w} />
        <Field label="Note (needed if you reject it)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>{err && <Err m={err} />}
        <div className="row wrap"><Button variant="primary" disabled={busy} onClick={() => void go(true)}>Approve</Button><Button variant="danger" disabled={busy || note.trim().length < 5} onClick={() => void go(false)}>Reject</Button>
          {w.order_ref && !w.replacement_requested && <Button disabled={busy} onClick={() => void repl()}>Ask for replacement stock</Button>}<Button variant="ghost" onClick={onClose}>Cancel</Button></div></div>
    </Modal>
  );
}

function RecoverDialog({ w, onClose }: { w: WasteRow; onClose: () => void }) {
  const toast = useToast(); const [amount, setAmount] = useState(String(w.recovered_value || '')); const [claim, setClaim] = useState(w.claim_ref ?? ''); const [note, setNote] = useState(w.recovery_note ?? '');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r = await wasteAction('waste_recover', { ref: w.waste_ref, amount: Number(amount), claim, reason: note }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work')); return; } toast.push({ tone: 'good', title: 'Recovery recorded.' }); onClose(); }
  return (
    <Modal open onClose={onClose} title="Money recovered">
      <div className="stack"><p>Record what you got back from the {label(PARTIES, w.party).toLowerCase()}. It cannot be more than the cost ({gbp(w.value)}).</p><WasteSummary w={w} />
        <div className="row wrap" style={{ gap: 12 }}><Field label="Amount recovered (£)"><input className="input" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field><Field label="Courier claim reference (optional)"><input className="input" value={claim} onChange={(e) => setClaim(e.target.value)} placeholder="CLM-…" /></Field></div>
        <Field label="Where the money came from"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>{err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || amount === '' || note.trim().length < 5} onClick={() => void go()}>Save</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div>
    </Modal>
  );
}
