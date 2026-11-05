import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { mvAction } from '../lib/movements';
import { METHOD_LABEL } from '../lib/domain';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
interface Full { id: string; code: string; name: string; contact_name: string | null; email: string | null; phone: string | null; address: string | null; default_method: string; is_active: boolean; capable_methods: string[]; weekly_capacity_units: number | null; turnaround_days: number; can_direct_dispatch: boolean; quality_notes: string | null; special_instructions: string | null }
export interface RateRow { id: string; producer_id: string; method: string; basis: string; unit_price: number; setup_fee: number; min_job_charge: number; notes: string | null }
const METHODS = Object.keys(METHOD_LABEL).length ? Object.keys(METHOD_LABEL) : ['embroidery', 'dtf', 'uv', 'dtg', 'screen_print', 'vinyl'];

// Add a producer, or edit one. Creating needs only a name; the rest can be filled in later.
export function ProducerDialog({ id, onClose }: { id?: string; onClose: () => void }) {
  const all = useView<Full>('ui_producers_all'); const cur = id ? all.rows.find((p) => p.id === id) : undefined; const toast = useToast();
  const [f, setF] = useState(() => ({ name: cur?.name ?? '', contact_name: cur?.contact_name ?? '', email: cur?.email ?? '', phone: cur?.phone ?? '', address: cur?.address ?? '', default_method: cur?.default_method ?? 'courier', turnaround_days: String(cur?.turnaround_days ?? 3),
    weekly: cur?.weekly_capacity_units ? String(cur.weekly_capacity_units) : '', direct: cur?.can_direct_dispatch ?? false, methods: cur?.capable_methods ?? [] as string[], quality: cur?.quality_notes ?? '', special: cur?.special_instructions ?? '', active: cur?.is_active ?? true }));
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const set = (p: Partial<typeof f>) => setF((x) => ({ ...x, ...p }));
  if (id && !cur && !all.loading) return <Modal open onClose={onClose} title="Producer"><p>Producer not found.</p></Modal>;
  async function go() {
    setBusy(true); setErr(null);
    const producer = { id, name: f.name, contact_name: f.contact_name, email: f.email, phone: f.phone, address: f.address, default_method: f.default_method, turnaround_days: f.turnaround_days, weekly_capacity_units: f.weekly, can_direct_dispatch: f.direct, capable_methods: f.methods, quality_notes: f.quality, special_instructions: f.special, ...(id ? { is_active: f.active } : {}) };
    const r: any = await mvAction('upsert_producer', { producer }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'Could not save the producer.')); return; }
    void refreshAll(); toast.push({ tone: 'good', title: r.created ? `${f.name} added` : `${f.name} saved`, body: r.created ? 'Add their rate card next so the selection engine can price them.' : undefined }); onClose();
  }
  return (
    <Modal open onClose={onClose} title={id ? `Edit ${cur?.name ?? 'producer'}` : 'Add a producer'}>
      <div className="stack">
        <Field label="Name *"><input className="input" value={f.name} onChange={(e) => set({ name: e.target.value })} /></Field>
        <div className="row wrap"><Field label="Contact"><input className="input" value={f.contact_name} onChange={(e) => set({ contact_name: e.target.value })} /></Field><Field label="Phone"><input className="input" value={f.phone} onChange={(e) => set({ phone: e.target.value })} /></Field></div>
        <Field label="Email (used for job sheets; nothing is sent automatically)"><input className="input" type="email" value={f.email} onChange={(e) => set({ email: e.target.value })} /></Field>
        <Field label="Address (printed on the consignment label)"><textarea className="input" rows={2} value={f.address} onChange={(e) => set({ address: e.target.value })} /></Field>
        <Field label="What they can decorate"><div className="row wrap">{METHODS.map((m) => <button key={m} type="button" className={`chip ${f.methods.includes(m) ? 'on' : ''}`} aria-pressed={f.methods.includes(m)} onClick={() => set({ methods: f.methods.includes(m) ? f.methods.filter((x) => x !== m) : [...f.methods, m] })}>{METHOD_LABEL[m] ?? m}</button>)}</div></Field>
        <div className="row wrap"><Field label="Turnaround (days from receipt)"><input className="input" type="number" min={0} max={60} value={f.turnaround_days} onChange={(e) => set({ turnaround_days: e.target.value })} /></Field>
          <Field label="Weekly capacity (units)"><input className="input" type="number" min={0} value={f.weekly} onChange={(e) => set({ weekly: e.target.value })} /></Field>
          <Field label="Usual delivery method"><select className="select" value={f.default_method} onChange={(e) => set({ default_method: e.target.value })}><option value="courier">Courier</option><option value="collection">Collection</option><option value="own_van">Own van</option><option value="post">Post</option></select></Field></div>
        <label className="check"><input type="checkbox" checked={f.direct} onChange={(e) => set({ direct: e.target.checked })} />Can ship finished orders straight to our customers</label>
        {id && <label className="check"><input type="checkbox" checked={f.active} onChange={(e) => set({ active: e.target.checked })} />Active (untick to stop sending them work)</label>}
        <Field label="Special instructions (printed on job sheets)"><textarea className="input" rows={2} value={f.special} onChange={(e) => set({ special: e.target.value })} /></Field>
        <Field label="Quality notes (internal)"><textarea className="input" rows={2} value={f.quality} onChange={(e) => set({ quality: e.target.value })} /></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || !f.name.trim()} onClick={() => void go()}>{busy ? 'Saving…' : 'Save producer'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>);
}

export function RateDialog({ producerId, rate, onClose }: { producerId: string; rate?: RateRow; onClose: () => void }) {
  const [f, setF] = useState({ method: rate?.method ?? 'embroidery', basis: rate?.basis ?? 'per_1000_stitches', price: rate ? String(rate.unit_price) : '', setup: rate ? String(rate.setup_fee) : '0', min: rate ? String(rate.min_job_charge) : '0', notes: rate?.notes ?? '' });
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r: any = await mvAction('set_rate', { producer_id: producerId, method: f.method, basis: f.basis, unit_price: f.price, setup_fee: f.setup, min_job_charge: f.min, notes: f.notes }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not save the rate.')); return; } void refreshAll(); toast.push({ tone: 'good', title: 'Rate saved', body: r.note }); onClose(); }
  return (<Modal open onClose={onClose} title={rate ? `Rate: ${rate.method}` : 'Add a rate'}><div className="stack">
    <Field label="Decoration method"><select className="select" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })} disabled={!!rate}>{METHODS.map((m) => <option key={m} value={m}>{METHOD_LABEL[m] ?? m}</option>)}</select></Field>
    <Field label="Charged"><select className="select" value={f.basis} onChange={(e) => setF({ ...f, basis: e.target.value })}><option value="per_1000_stitches">Per 1,000 stitches</option><option value="per_piece">Per piece, per decorated area</option></select></Field>
    <div className="row wrap"><Field label="Price (£)"><input className="input" type="number" step="0.0001" min={0} value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} /></Field><Field label="Setup fee per design (£)"><input className="input" type="number" min={0} step="0.01" value={f.setup} onChange={(e) => setF({ ...f, setup: e.target.value })} /></Field><Field label="Minimum job charge (£)"><input className="input" type="number" min={0} step="0.01" value={f.min} onChange={(e) => setF({ ...f, min: e.target.value })} /></Field></div>
    <Field label="Notes"><input className="input" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></Field>
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || f.price === ''} onClick={() => void go()}>{busy ? 'Saving…' : 'Save rate'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}
