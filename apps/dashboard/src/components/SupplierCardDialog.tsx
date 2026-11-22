import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { supabase } from '../lib/api';
import { ORDER_METHODS, cardGaps, emptyShippingForm, emptySupplierForm, formFromCard, formFromOption, isAutomatic, optionWords, optionsFor, orderMethodHint, shippingPayload, shippingProblem, supplierPayload, supplierProblem, type ShippingForm, type ShippingOptionRow, type SupplierCardRow, type SupplierForm } from '../lib/supplierCards';

// One supplier's card: details, how we order from them, and the delivery options. The database checks the role and every value. The API or EDI keys are never
// kept here: the notes only say where to find them.
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
type Result = { ok?: boolean; error?: string; id?: string };

function ShippingDialog({ supplierId, option, first, onClose }: { supplierId: string; option: ShippingOptionRow | null; first: boolean; onClose: () => void }) {
  const toast = useToast(); const [f, setF] = useState<ShippingForm>(option ? formFromOption(option) : emptyShippingForm(first)); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const set = (p: Partial<ShippingForm>) => setF((x) => ({ ...x, ...p }));
  async function save() {
    const bad = shippingProblem(f); if (bad) { setErr(bad); return; }
    setBusy(true); setErr(null); const { data, error } = await supabase.rpc('supplier_shipping_save', { p_supplier: supplierId, p_option: option?.id ?? null, p_f: shippingPayload(f) }); setBusy(false);
    const r = (data ?? {}) as Result; if (error || r.ok === false) { setErr(error?.message ?? r.error ?? 'That did not save.'); return; }
    toast.push({ tone: 'good', title: option ? 'Delivery option saved' : 'Delivery option added', body: f.name.trim() }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={option ? `Delivery option: ${option.name}` : 'Add a delivery option'}>
      <div className="stack">
        <Field label="Name (for example Standard, Next day, Pallet)"><input className="input" value={f.name} onChange={(e) => set({ name: e.target.value })} aria-label="Option name" /></Field>
        <div className="row wrap"><Field label="Cost (£, 0 for free)"><input className="input" inputMode="decimal" value={f.cost} onChange={(e) => set({ cost: e.target.value })} aria-label="Option cost" /></Field>
          <Field label="Free over (£, optional)"><input className="input" inputMode="decimal" value={f.free_over} onChange={(e) => set({ free_over: e.target.value })} aria-label="Free over" /></Field></div>
        <div className="row wrap"><Field label="Days to arrive (optional)"><input className="input" inputMode="decimal" value={f.lead_time_days} onChange={(e) => set({ lead_time_days: e.target.value })} aria-label="Option days" /></Field>
          <Field label="Order by (time, optional, like 14:30)"><input className="input" value={f.cut_off_time} onChange={(e) => set({ cut_off_time: e.target.value })} placeholder="14:30" aria-label="Cut-off time" /></Field></div>
        <Field label="Notes (optional)"><input className="input" value={f.notes} onChange={(e) => set({ notes: e.target.value })} aria-label="Option notes" /></Field>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.is_default} disabled={option?.is_default} onChange={(e) => set({ is_default: e.target.checked, ...(e.target.checked ? { is_active: true } : {}) })} /> The one we usually use (the default)</label>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.is_active} disabled={f.is_default} onChange={(e) => set({ is_active: e.target.checked })} /> Offer this option</label>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

export function SupplierCardDialog({ supplier, canEdit, onClose, onCreated }: { supplier: SupplierCardRow | null; canEdit: boolean; onClose: () => void; onCreated: (id: string) => void }) {
  const toast = useToast(); const shipping = useView<ShippingOptionRow>('ui_supplier_shipping'); const [f, setF] = useState<SupplierForm>(supplier ? formFromCard(supplier) : emptySupplierForm());
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [opt, setOpt] = useState<ShippingOptionRow | 'new' | null>(null);
  const set = (p: Partial<SupplierForm>) => setF((x) => ({ ...x, ...p }));
  const opts = supplier ? optionsFor(shipping.rows, supplier.id) : []; const gaps = supplier ? cardGaps({ ...supplier, order_method: f.order_method, email: f.email || null, is_active: f.is_active }, opts) : [];
  async function save() {
    const bad = supplierProblem(f); if (bad) { setErr(bad); return; }
    setBusy(true); setErr(null); const { data, error } = await supabase.rpc('supplier_save', { p_id: supplier?.id ?? null, p_f: supplierPayload(f) }); setBusy(false);
    const r = (data ?? {}) as Result; if (error || r.ok === false) { setErr(error?.message ?? r.error ?? 'That did not save.'); return; }
    toast.push({ tone: 'good', title: supplier ? 'Supplier saved' : 'Supplier added', body: f.name.trim() }); void refreshAll();
    if (!supplier && r.id) onCreated(r.id); else onClose();
  }
  const ro = !canEdit;
  return (
    <Modal open onClose={onClose} title={supplier ? `Supplier: ${supplier.name}` : 'Add a supplier'}>
      <div className="stack">
        {ro && <span className="dim">You can look at this card. Managers and admins change suppliers.</span>}
        {gaps.length > 0 && <div className="callout" role="status" data-testid="supplier-gaps"><b>Still to fill in</b>{gaps.map((g) => <div key={g}>{g}</div>)}</div>}
        <Field label="Supplier name"><input className="input" value={f.name} disabled={ro} onChange={(e) => set({ name: e.target.value })} aria-label="Supplier name" /></Field>
        <div className="row wrap"><Field label="Contact"><input className="input" value={f.contact_name} disabled={ro} onChange={(e) => set({ contact_name: e.target.value })} aria-label="Contact" /></Field>
          <Field label="Phone"><input className="input" value={f.phone} disabled={ro} onChange={(e) => set({ phone: e.target.value })} aria-label="Phone" /></Field></div>
        <Field label="Email (orders are sent here when we order by email)"><input className="input" value={f.email} disabled={ro} onChange={(e) => set({ email: e.target.value })} aria-label="Email" /></Field>
        <div className="row wrap"><Field label="Our account number"><input className="input" value={f.account_number} disabled={ro} onChange={(e) => set({ account_number: e.target.value })} aria-label="Account number" /></Field>
          <Field label="Website"><input className="input" value={f.website} disabled={ro} onChange={(e) => set({ website: e.target.value })} aria-label="Website" /></Field></div>
        <Field label="Address"><textarea className="input" rows={2} value={f.address} disabled={ro} onChange={(e) => set({ address: e.target.value })} aria-label="Address" /></Field>
        <div className="row wrap"><Field label="Payment terms"><input className="input" value={f.payment_terms} disabled={ro} onChange={(e) => set({ payment_terms: e.target.value })} aria-label="Payment terms" /></Field>
          <Field label="Usual days to deliver"><input className="input" inputMode="decimal" value={f.lead_time_days} disabled={ro} onChange={(e) => set({ lead_time_days: e.target.value })} aria-label="Lead time days" /></Field>
          <Field label="Minimum order (£, optional)"><input className="input" inputMode="decimal" value={f.min_order_value} disabled={ro} onChange={(e) => set({ min_order_value: e.target.value })} aria-label="Minimum order" /></Field></div>
        <Field label="How we order from them"><select className="select" value={f.order_method} disabled={ro} onChange={(e) => set({ order_method: e.target.value })} aria-label="How we order">{ORDER_METHODS.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}</select></Field>
        <span className="dim">{orderMethodHint(f.order_method)}{isAutomatic(f.order_method) ? ' Flow never stores API or EDI keys or passwords.' : ''}</span>
        <Field label="Notes on ordering (for example where the API details are kept)"><textarea className="input" rows={2} value={f.order_method_notes} disabled={ro} onChange={(e) => set({ order_method_notes: e.target.value })} aria-label="Ordering notes" /></Field>
        <Field label="Other notes"><textarea className="input" rows={2} value={f.notes} disabled={ro} onChange={(e) => set({ notes: e.target.value })} aria-label="Notes" /></Field>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.can_deliver_to_producer} disabled={ro} onChange={(e) => set({ can_deliver_to_producer: e.target.checked })} /> Can deliver straight to a decorator</label>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={f.is_active} disabled={ro} onChange={(e) => set({ is_active: e.target.checked })} /> Use this supplier (untick to hide it from buying)</label>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || ro} onClick={() => void save()}>{busy ? 'Saving…' : supplier ? 'Save' : 'Add the supplier'}</Button><Button variant="ghost" onClick={onClose}>Close</Button></div>
        {supplier && <div className="stack" style={{ gap: 6 }} data-testid="shipping-options"><div className="row wrap" style={{ justifyContent: 'space-between' }}><b>Delivery options</b><Button disabled={ro} onClick={() => setOpt('new')}>Add a delivery option</Button></div>
          {opts.length === 0 && <span className="dim">None yet. Add the ways this supplier delivers and what they cost, for example Standard and Next day.</span>}
          {opts.map((o) => <div key={o.id} className="row wrap" style={{ gap: 8, opacity: o.is_active ? 1 : 0.55 }}><span className="grow">{optionWords(o)}</span>{o.is_default && o.is_active && <Status tone="good">Default</Status>}{!o.is_active && <Status tone="medium">Switched off</Status>}<Button size="sm" disabled={ro} onClick={() => setOpt(o)}>Change</Button></div>)}</div>}
      </div>
      {supplier && opt && <ShippingDialog supplierId={supplier.id} option={opt === 'new' ? null : opt} first={!opts.some((o) => o.is_active)} onClose={() => setOpt(null)} />}
    </Modal>
  );
}
