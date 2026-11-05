import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { mvAction, type StepDef, RESOLUTIONS } from '../lib/movements';
import { whAction } from '../lib/warehouse';
import type { ProducerRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const num = (v: string) => Math.max(0, Math.floor(Number(v) || 0));
interface Sendable { order_line_id: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; sku: string | null; product_name: string | null; colour: string | null; size: string | null; decoration_methods: string[]; qty_needed: number; qty_sendable: number }

// Create an outbound consignment (or a direct-dispatch job) from lines that are secured and not already with a producer.
export function CreateMovementDialog({ onClose, presetOrders, presetProducer }: { onClose: () => void; presetOrders?: string[]; presetProducer?: string }) {
  const prods = useView<ProducerRow>('ui_producers'); const lines = useView<Sendable>('ui_tp_sendable_lines'); const toast = useToast();
  const [type, setType] = useState('outbound_to_producer'); const [producer, setProducer] = useState(presetProducer ?? ''); const [qty, setQty] = useState<Record<string, string>>({}); const [q, setQ] = useState(''); const [carrier, setCarrier] = useState(''); const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [done, setDone] = useState<Record<string, any> | null>(null);
  const prod = prods.rows.find((p) => p.id === producer); const preset = presetOrders ?? [];
  const shown = useMemo(() => lines.rows.filter((l) => (preset.length === 0 || preset.includes(l.order_ref)) && (!q || [l.order_ref, l.customer_name, l.sku, l.product_name].join(' ').toLowerCase().includes(q.toLowerCase())) && (!prod || prod.capable_methods.length === 0 || l.decoration_methods.length === 0 || l.decoration_methods.some((m) => prod.capable_methods.includes(m))))
    .sort((a, b) => (a.due_date ?? '9').localeCompare(b.due_date ?? '9') || a.order_ref.localeCompare(b.order_ref)).slice(0, 300), [lines.rows, preset, q, prod]);
  const chosen = shown.filter((l) => num(qty[l.order_line_id] ?? '') > 0); const total = chosen.reduce((t, l) => t + num(qty[l.order_line_id]), 0);
  const over = chosen.find((l) => num(qty[l.order_line_id]) > l.qty_sendable);
  async function go() {
    setBusy(true); setErr(null);
    const r: any = await mvAction('create_movement', { producer_id: producer, type, carrier, notes, items: chosen.map((l) => ({ order_line_id: l.order_line_id, qty: num(qty[l.order_line_id]) })) });
    setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not create the consignment.')); return; }
    void refreshAll(); setDone(r);
  }
  async function labels() { const r = await whAction('generate_labels', { type: 'producer', refs: [done?.movement_code] }); if (r.ok === false) toast.push({ tone: 'bad', title: 'Could not make labels', body: String(r.error) }); else { void refreshAll(); toast.push({ tone: 'good', title: 'Labels ready', body: 'Outbound, consignment and job-sheet labels are in the Labels page.', href: '#/labels?view=await', linkLabel: 'Open Labels' }); } }
  if (done) return (
    <Modal open onClose={onClose} title={`${done.movement_code} created`}>
      <div className="stack"><p>{chosen.length} line(s), {total} unit(s) reserved for <b>{prod?.name}</b>.{done.staging_bin ? <> Staging bin: <b className="mono">{done.staging_bin}</b>.</> : null}</p>
        {((done.warnings as string[] | undefined) ?? []).map((w) => <div key={w} className="callout" role="status">{w}</div>)}
        <p className="dim">Next: pick the goods, print the labels, pack, then dispatch. Each step is recorded from the consignment page.</p>
        <div className="row wrap"><Button variant="primary" onClick={() => { onClose(); location.hash = '#/producers/movement/' + done.movement_code; }}>Open consignment</Button><Button icon="labels" onClick={() => void labels()}>Generate labels</Button><Button variant="ghost" onClick={onClose}>Close</Button></div></div>
    </Modal>);
  return (
    <Modal open onClose={onClose} title="New producer movement">
      <div className="stack">
        <Field label="Type"><select className="select" value={type} onChange={(e) => setType(e.target.value)}><option value="outbound_to_producer">Send blanks to a producer (they come back to us)</option><option value="direct_dispatch_to_customer">Producer ships straight to the customer</option></select></Field>
        <Field label="Producer"><select className="select" value={producer} onChange={(e) => setProducer(e.target.value)}><option value="">Choose a producer…</option>{prods.rows.filter((p) => p.is_active && (type === 'outbound_to_producer' || p.can_direct_dispatch)).map((p) => <option key={p.id} value={p.id}>{p.name} · {p.turnaround_days} day turnaround</option>)}</select></Field>
        {prods.rows.length === 0 && !prods.loading && <div className="callout" role="status">No producers exist yet. Add one on the Producers page first.</div>}
        <Field label={`Lines to send (${total} unit(s) chosen)`}>
          <input className="input" placeholder="Filter by order, customer, SKU…" value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="panel" style={{ maxHeight: 260, overflow: 'auto', padding: 6, marginTop: 6 }}>
            {shown.length === 0 && <p className="dim" style={{ padding: 8 }}>No lines can be sent right now. A line needs secured stock and must not already be with a producer{prod && prod.capable_methods.length ? `; this producer only does ${prod.capable_methods.join(', ')}` : ''}.</p>}
            {shown.map((l) => <div key={l.order_line_id} className="row" style={{ padding: '4px 8px', gap: 10 }}><b className="mono" style={{ width: 70 }}>{l.order_ref}</b><span className="grow muted">{l.sku} · {[l.colour, l.size].filter(Boolean).join(' ')} <span className="dim">{l.customer_name}</span></span><span className="dim num">max {l.qty_sendable}</span>
              <input aria-label={`Quantity for ${l.sku}`} className="input" style={{ width: 70 }} type="number" min={0} max={l.qty_sendable} value={qty[l.order_line_id] ?? ''} onChange={(e) => setQty((x) => ({ ...x, [l.order_line_id]: e.target.value }))} /><button className="chip" onClick={() => setQty((x) => ({ ...x, [l.order_line_id]: String(l.qty_sendable) }))}>All</button></div>)}
          </div>
        </Field>
        <div className="row wrap"><Field label="Carrier / method"><select className="select" value={carrier} onChange={(e) => setCarrier(e.target.value)}><option value="">Producer default</option><option value="courier">Courier</option><option value="collection">Collection</option><option value="own_van">Own van</option><option value="post">Post</option></select></Field></div>
        <Field label="Notes for the producer / pack team"><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
        <p className="dim">Only secured stock can be sent, and never more than the order still needs. Nothing leaves the building until you record dispatch.</p>
        {over && <Err m={`${over.order_ref} ${over.sku}: only ${over.qty_sendable} can still be sent.`} />}{err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={!producer || chosen.length === 0 || !!over || busy} onClick={() => void go()}>{busy ? 'Creating…' : `Create consignment (${total} units)`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>);
}

// One lifecycle step (pick, pack, dispatch, producer receipt…), with the few fields that step needs.
export function StepDialog({ code, step, onClose }: { code: string; step: StepDef; onClose: () => void }) {
  const [vals, setVals] = useState<Record<string, string>>({}); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  const missing = (step.fields ?? []).some((f) => f.required && !vals[f.key]?.trim());
  async function go() { setBusy(true); setErr(null); const payload: Record<string, unknown> = { ...vals, note }; for (const f of step.fields ?? []) if (f.type === 'number' && vals[f.key]) payload[f.key] = Number(vals[f.key]); const r: any = await mvAction('scan', { code, event: step.event, payload }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That step was refused.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${code}: ${step.label.toLowerCase()}`, body: r.expected_return_date ? `Expected back ${r.expected_return_date}.` : undefined }); onClose(); }
  return (
    <Modal open onClose={onClose} title={`${code} · ${step.label}`}>
      <div className="stack"><p>{step.help}</p>{step.producerSide && <div className="callout" role="status">Normally the producer confirms this. If you record it for them, it is logged as entered by staff.</div>}
        {(step.fields ?? []).map((f) => <Field key={f.key} label={f.label + (f.required ? ' *' : '')}><input className="input" type={f.type ?? 'text'} value={vals[f.key] ?? ''} onChange={(e) => setVals((v) => ({ ...v, [f.key]: e.target.value }))} placeholder={f.placeholder} /></Field>)}
        <Field label="Note (optional)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || missing} onClick={() => void go()}>{busy ? 'Saving…' : step.label}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div>
    </Modal>);
}

interface Item { item_id: string; sku: string | null; colour: string | null; size: string | null; order_ref: string; qty_sent: number; qty_outstanding: number; qty_awaiting_check: number; qty_received_back: number; qty_damaged: number; qty_rejected: number }

// Book goods back in from the producer: good / damaged / wrong per line. Short deliveries open a discrepancy automatically.
export function ReturnDialog({ code, items, onClose }: { code: string; items: Item[]; onClose: () => void }) {
  const open = items.filter((i) => i.qty_outstanding > 0); const [v, setV] = useState<Record<string, { good: string; dam: string; rej: string }>>({}); const [ref, setRef] = useState(''); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  const get = (i: Item) => v[i.item_id] ?? { good: String(i.qty_outstanding), dam: '0', rej: '0' };
  const set = (i: Item, p: Partial<{ good: string; dam: string; rej: string }>) => setV((x) => ({ ...x, [i.item_id]: { ...get(i), ...p } }));
  const short = open.reduce((t, i) => { const g = get(i); return t + Math.max(i.qty_outstanding - num(g.good) - num(g.dam) - num(g.rej), 0); }, 0);
  async function go() {
    setBusy(true); setErr(null);
    const payload = rows(); const r: any = await mvAction('record_return', { code, items: payload, payload: { delivery_ref: ref || undefined, note: note || undefined } }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'Could not book the return in.')); return; }
    void refreshAll(); toast.push({ tone: r.discrepancies?.length || short ? 'info' : 'good', title: `${code}: return booked in`, body: short ? `${short} unit(s) still outstanding; the shortage is tracked as a discrepancy.` : 'Everything expected has come back. It now needs a goods-in check.' }); onClose();
  }
  const rows = () => open.map((i) => { const g = get(i); return { item_id: i.item_id, qty_received: num(g.good), qty_damaged: num(g.dam), qty_rejected: num(g.rej) }; }).filter((x) => x.qty_received + x.qty_damaged + x.qty_rejected > 0);
  return (
    <Modal open onClose={onClose} title={`${code} · book return in`}>
      <div className="stack">
        {open.length === 0 ? <p className="dim">Nothing is outstanding on this consignment.</p> : <div style={{ overflowX: 'auto' }}><table className="table" style={{ minWidth: 520 }}><thead><tr><th>Line</th><th className="r">Outstanding</th><th className="r">Good</th><th className="r">Damaged</th><th className="r">Wrong / poor</th></tr></thead><tbody>
          {open.map((i) => { const g = get(i); return <tr key={i.item_id}><td><b className="mono">{i.sku}</b><div className="dim">{i.order_ref} · {[i.colour, i.size].filter(Boolean).join(' ')}</div></td><td className="r num">{i.qty_outstanding}</td>
            {(['good', 'dam', 'rej'] as const).map((k) => <td key={k} className="r"><input aria-label={`${k} ${i.sku}`} className="input" style={{ width: 64 }} type="number" min={0} value={g[k]} onChange={(e) => set(i, { [k]: e.target.value })} /></td>)}</tr>; })}</tbody></table></div>}
        <Field label="Producer delivery note / tracking"><input className="input" value={ref} onChange={(e) => setRef(e.target.value)} /></Field>
        <Field label="Notes"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        {short > 0 && <div className="callout" role="status"><Status tone="high" plain>{short} short</Status> This is a partial delivery. The consignment stays open and the missing units are tracked until they arrive or are resolved.</div>}
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || open.length === 0 || rows().length === 0} onClick={() => void go()}>{busy ? 'Saving…' : 'Book return in'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>);
}

// Goods-in check of returned garments: good units are released to dispatch, failures become rejected discrepancies.
export function CheckDialog({ code, items, onClose }: { code: string; items: Item[]; onClose: () => void }) {
  const open = items.filter((i) => i.qty_awaiting_check > 0); const [v, setV] = useState<Record<string, { ok: string; rej: string }>>({}); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  const get = (i: Item) => v[i.item_id] ?? { ok: String(i.qty_awaiting_check), rej: '0' };
  async function go() {
    setBusy(true); setErr(null); const r: any = await mvAction('check_return', { code, items: open.map((i) => ({ item_id: i.item_id, qty_ok: num(get(i).ok), qty_rejected: num(get(i).rej) })), payload: { note: note || undefined } }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'Could not record the check.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${code}: check recorded`, body: 'Good units are released to dispatch.' }); onClose();
  }
  return (
    <Modal open onClose={onClose} title={`${code} · check returned goods`}>
      <div className="stack">
        {open.length === 0 ? <p className="dim">Nothing is waiting to be checked.</p> : <table className="table"><thead><tr><th>Line</th><th className="r">To check</th><th className="r">Pass</th><th className="r">Fail</th></tr></thead><tbody>{open.map((i) => { const g = get(i); return <tr key={i.item_id}><td><b className="mono">{i.sku}</b><div className="dim">{i.order_ref}</div></td><td className="r num">{i.qty_awaiting_check}</td>
          <td className="r"><input aria-label={`pass ${i.sku}`} className="input" style={{ width: 64 }} type="number" min={0} value={g.ok} onChange={(e) => setV((x) => ({ ...x, [i.item_id]: { ...g, ok: e.target.value } }))} /></td>
          <td className="r"><input aria-label={`fail ${i.sku}`} className="input" style={{ width: 64 }} type="number" min={0} value={g.rej} onChange={(e) => setV((x) => ({ ...x, [i.item_id]: { ...g, rej: e.target.value } }))} /></td></tr>; })}</tbody></table>}
        <Field label="Notes"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || open.length === 0} onClick={() => void go()}>{busy ? 'Saving…' : 'Record check'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>);
}

export function DirectDispatchDialog({ code, onClose }: { code: string; onClose: () => void }) {
  const [tracking, setTracking] = useState(''); const [carrier, setCarrier] = useState(''); const [pod, setPod] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r: any = await mvAction('direct_dispatch', { code, tracking, carrier, pod: pod ? { url: pod, name: 'Proof of delivery' } : {} }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not record it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${code}: dispatched to the customer` }); onClose(); }
  return (<Modal open onClose={onClose} title={`${code} · producer shipped to customer`}><div className="stack"><p>The producer sent the finished goods straight to the customer. A tracking reference is required, and the stock never returns to our warehouse.</p>
    <Field label="Tracking reference *"><input className="input" value={tracking} onChange={(e) => setTracking(e.target.value)} /></Field><Field label="Carrier"><input className="input" value={carrier} onChange={(e) => setCarrier(e.target.value)} /></Field>
    <Field label="Proof of delivery link (optional)"><input className="input" value={pod} onChange={(e) => setPod(e.target.value)} placeholder="https://…" /></Field>
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || !tracking.trim()} onClick={() => void go()}>{busy ? 'Saving…' : 'Confirm dispatch'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}

export function ResolveDialog({ id, label, onClose }: { id: string; label: string; onClose: () => void }) {
  const [res, setRes] = useState('received_later'); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r: any = await mvAction('resolve_discrepancy', { id, resolution: res, note }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not resolve it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: 'Discrepancy resolved', body: r.note }); onClose(); }
  return (<Modal open onClose={onClose} title={`Resolve: ${label}`}><div className="stack"><Field label="Outcome"><select className="select" value={res} onChange={(e) => setRes(e.target.value)}>{RESOLUTIONS.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}</select></Field>
    <Field label="Note (required, kept in the audit trail)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>{err && <Err m={err} />}
    <div className="row"><Button variant="primary" disabled={busy || note.trim().length < 3} onClick={() => void go()}>{busy ? 'Saving…' : 'Resolve'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}
