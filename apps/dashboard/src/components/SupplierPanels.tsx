import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status, Tag } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { shortDate } from '../lib/domain';
import { ACTION_LABEL, loadAdvice, spAction, type Advice, type AltRow, type OfferRow } from '../lib/suppliers';
import { ReasonDialog } from './WarehouseDialogs';
import type { StockLocRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const TONE: Record<string, 'good' | 'info' | 'high' | 'critical' | 'medium'> = { wait: 'info', substitute: 'medium', reorder: 'good', split: 'high', tell_customer: 'critical' };

// What to do about a shortage on this SKU, and why: wait for the PO, substitute, reorder, split, or tell the customer.
export function ShortageAdvice({ sku }: { sku: string }) {
  const [a, setA] = useState<Advice | null | undefined>(undefined); const alts = useView<AltRow>('ui_approved_alternatives'); const offers = useView<OfferRow>('ui_supplier_offers');
  useEffect(() => { let live = true; setA(undefined); void loadAdvice(sku).then((r) => { if (live) setA(r); }); return () => { live = false; }; }, [sku, alts.rows.length, offers.rows.length]);
  if (a === undefined) return <p className="dim">Working out what to do about the shortage…</p>;
  if (a === null) return null;
  return (
    <section className="stack" aria-label="Shortage advice">
      <div className="row"><h3 className="grow">What to do about the shortage</h3><Status tone="critical">{a.units_short} short</Status></div>
      <div className="callout" role="status"><Status tone={TONE[a.recommendation.action] ?? 'info'}>{ACTION_LABEL[a.recommendation.action] ?? a.recommendation.action}</Status> {a.recommendation.text}</div>
      <p className="dim">{a.orders_affected} order(s) affected, earliest due {a.earliest_due ? shortDate(a.earliest_due) : '—'}{a.days_to_due != null ? ` (${a.days_to_due} day${a.days_to_due === 1 ? '' : 's'})` : ''}. {a.on_hand} on hand, {a.on_order} on order.</p>
      {a.incoming.length > 0 && <div className="stack" style={{ gap: 2 }}>{a.incoming.map((i) => <div key={i.po_id + i.po_ref} className="row" style={{ gap: 10 }}><a className="mono" href={'#/purchasing/' + i.po_id}>{i.po_ref}</a><span className="muted grow">{i.supplier} · {i.qty} due {i.expected_date ? shortDate(i.expected_date) : '—'}</span>{i.is_late ? <Status tone="critical" plain>late</Status> : !i.before_due ? <Status tone="high" plain>after due date</Status> : i.on_time_rate != null && i.on_time_rate < 70 ? <Status tone="high" plain>unreliable ({Math.round(i.on_time_rate)}%)</Status> : <Status tone="good" plain>in time</Status>}</div>)}</div>}
    </section>);
}

export function AlternativesSection({ sku }: { sku: string }) {
  const alts = useView<AltRow>('ui_approved_alternatives'); const { senior } = useCtx(); const [dlg, setDlg] = useState<null | 'add' | { remove: AltRow }>(null);
  const mine = alts.rows.filter((a) => a.sku === sku);
  return (<section className="stack"><div className="row"><h3 className="grow">Approved alternatives ({mine.length})</h3><Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can approve alternatives'} onClick={() => setDlg('add')}>Approve an alternative</Button></div>
    {mine.length === 0 ? <p className="dim">No alternative is approved for this SKU. Approve one so a shortage can be covered by something else the customer would accept.</p> : mine.map((a) => <div key={a.id} className="row wrap" style={{ gap: 10 }}><a className="mono" href={'#/stock/' + encodeURIComponent(a.alt_sku)}>{a.alt_sku}</a><span className="muted grow">{[a.alt_product, a.alt_colour, a.alt_size].filter(Boolean).join(' · ')} · {a.alt_on_hand ?? 0} on hand{a.notes ? ` · ${a.notes}` : ''}</span>{a.needs_customer_ok ? <Tag>customer must agree</Tag> : <Tag>no customer OK needed</Tag>}<Button size="sm" variant="ghost" disabled={!senior} onClick={() => setDlg({ remove: a })}>Withdraw</Button></div>)}
    {dlg === 'add' && <AddAlternative sku={sku} onClose={() => setDlg(null)} />}
    {dlg && dlg !== 'add' && <ReasonDialog path="suppliers" title={`Withdraw ${dlg.remove.alt_sku} as an alternative`} intro="It stops being offered as a stand-in for this SKU. History is kept." confirm="Withdraw" action="remove_alternative" params={{ id: dlg.remove.id }} presets={['Quality complaint', 'Discontinued', 'Customer will not accept it']} onClose={() => { setDlg(null); void refreshAll(); }} />}
  </section>);
}

function AddAlternative({ sku, onClose }: { sku: string; onClose: () => void }) {
  const stock = useView<StockLocRow>('ui_stock_locations'); const toast = useToast(); const [alt, setAlt] = useState(''); const [ok, setOk] = useState(true); const [notes, setNotes] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r: any = await spAction('add_alternative', { sku, alt_sku: alt, needs_customer_ok: ok, notes }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not approve it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: `${alt} approved as an alternative to ${sku}` }); onClose(); }
  return (<Modal open onClose={onClose} title={`Approve an alternative to ${sku}`}><div className="stack">
    <Field label="Alternative SKU"><input className="input mono" list="alt-options" value={alt} onChange={(e) => setAlt(e.target.value)} placeholder="Start typing a SKU" /><datalist id="alt-options">{stock.rows.filter((s) => s.sku !== sku).slice(0, 400).map((s) => <option key={s.sku} value={s.sku}>{[s.product_name, s.colour, s.size].filter(Boolean).join(' ')}</option>)}</datalist></Field>
    <label className="check"><input type="checkbox" checked={ok} onChange={(e) => setOk(e.target.checked)} />The customer must agree before we swap</label>
    <Field label="Notes (for example how it differs)"><input className="input" value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || !alt.trim()} onClick={() => void go()}>{busy ? 'Saving…' : 'Approve'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}

export function OffersSection({ sku }: { sku: string }) {
  const offers = useView<OfferRow>('ui_supplier_offers'); const { senior } = useCtx(); const [dlg, setDlg] = useState<null | { offer?: OfferRow }>(null);
  const mine = offers.rows.filter((o) => o.sku === sku);
  return (<section className="stack"><div className="row"><h3 className="grow">Who can supply it ({mine.length})</h3><Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can change supplier offers'} onClick={() => setDlg({})}>Add a supplier</Button></div>
    {mine.length === 0 ? <p className="dim">No supplier is recorded as able to supply this SKU, so the system cannot recommend a reorder. Add the supplier, cost and lead time.</p> : mine.map((o) => <div key={o.id} className="row wrap" style={{ gap: 10 }}><b>{o.supplier}</b><span className="muted grow">{o.unit_cost != null ? `£${o.unit_cost}` : 'no price'} · {o.lead_days ?? '—'} day lead time · min {o.min_qty}{o.stock_available != null ? ` · ${o.stock_available} in their stock` : ''}</span><Button size="sm" variant="ghost" disabled={!senior} onClick={() => setDlg({ offer: o })}>Edit</Button></div>)}
    {dlg && <OfferDialog sku={sku} offer={dlg.offer} onClose={() => setDlg(null)} />}</section>);
}

interface Sup { id: string; name: string }
function OfferDialog({ sku, offer, onClose }: { sku: string; offer?: OfferRow; onClose: () => void }) {
  const sups = useView<Sup>('ui_suppliers'); const toast = useToast(); const [f, setF] = useState({ supplier: offer?.supplier_id ?? '', cost: offer?.unit_cost != null ? String(offer.unit_cost) : '', lead: offer?.lead_days != null ? String(offer.lead_days) : '', min: String(offer?.min_qty ?? 1), stock: offer?.stock_available != null ? String(offer.stock_available) : '', ssku: offer?.supplier_sku ?? '' });
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go() { setBusy(true); setErr(null); const r: any = await spAction('set_offer', { supplier_id: f.supplier, sku, unit_cost: f.cost, lead_days: f.lead, min_qty: f.min, stock: f.stock, supplier_sku: f.ssku }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not save it.')); return; } void refreshAll(); toast.push({ tone: 'good', title: 'Supplier offer saved', body: r.note }); onClose(); }
  return (<Modal open onClose={onClose} title={`Who can supply ${sku}`}><div className="stack">
    <Field label="Supplier"><select className="select" value={f.supplier} disabled={!!offer} onChange={(e) => setF({ ...f, supplier: e.target.value })}><option value="">Choose a supplier…</option>{sups.rows.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
    <div className="row wrap"><Field label="Unit cost (£)"><input className="input" type="number" min={0} step="0.01" value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value })} /></Field><Field label="Lead time (days)"><input className="input" type="number" min={0} max={99} value={f.lead} onChange={(e) => setF({ ...f, lead: e.target.value })} /></Field></div>
    <div className="row wrap"><Field label="Minimum order qty"><input className="input" type="number" min={1} value={f.min} onChange={(e) => setF({ ...f, min: e.target.value })} /></Field><Field label="In their stock (blank = unknown, 0 = out)"><input className="input" type="number" min={0} value={f.stock} onChange={(e) => setF({ ...f, stock: e.target.value })} /></Field></div>
    <Field label="Their code for it (optional)"><input className="input" value={f.ssku} onChange={(e) => setF({ ...f, ssku: e.target.value })} /></Field>
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || !f.supplier} onClick={() => void go()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>);
}
