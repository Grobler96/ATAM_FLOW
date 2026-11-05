import { useMemo, useState } from 'react';
import { Modal } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { useView } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import { useToast } from '../ui/overlay';
import type { OrderRow } from '../data/types';

interface SupplierRow { id: string; name: string; email: string | null; lead_time_days: number; delivery_cost: number }

// Creates a draft ATAM_FLOW purchase order from the stock that waiting orders still need (identical SKUs are consolidated by the database).
export function CreatePoDialog({ open, onClose, presetOrders }: { open: boolean; onClose: () => void; presetOrders?: string[] }) {
  const suppliers = useView<SupplierRow>('ui_suppliers'); const orders = useView<OrderRow>('ui_orders');
  const [supplier, setSupplier] = useState(''); const [picked, setPicked] = useState<string[]>(presetOrders ?? []); const [reqBy, setReqBy] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const toast = useToast();
  const waiting = useMemo(() => orders.rows.filter((o) => o.order_status === 'awaiting_stock').sort((a, b) => (a.due_date ?? '9').localeCompare(b.due_date ?? '9')), [orders.rows]);
  const sup = suppliers.rows.find((s) => s.id === supplier);
  async function submit() {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('purchasing', 'create_po_for_orders', { supplier_id: supplier, order_ids: picked, options: reqBy ? { required_by: reqBy } : {} });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'Could not create the purchase order.')); return; }
    toast.push({ tone: 'good', title: `Draft purchase order ${String(r.af_po_ref ?? '')} created`, body: `${r.lines ?? ''} line(s), total £${r.total_cost ?? ''}. Review, approve and send it from Purchasing.`, href: '#/purchasing', linkLabel: 'Open Purchasing' });
    onClose();
  }
  return (
    <Modal open={open} onClose={onClose} title="Create purchase order">
      <div className="stack">
        <Field label="Supplier"><select className="select" value={supplier} onChange={(e) => setSupplier(e.target.value)}><option value="">Choose a supplier…</option>{suppliers.rows.map((s) => <option key={s.id} value={s.id}>{s.name}{s.email ? '' : ' (no email yet)'}</option>)}</select></Field>
        {sup && <p className="dim">Lead time {sup.lead_time_days} days · delivery £{sup.delivery_cost}</p>}
        <Field label={`Customer orders waiting for stock: choose which to buy for (${picked.length} chosen, about ${picked.reduce((t, id) => t + (waiting.find((o) => o.id === id)?.units_short ?? 0), 0)} units short)`}>
          <div className="panel" style={{ maxHeight: 220, overflow: 'auto', padding: 6 }}>
            {waiting.length === 0 && <p className="dim" style={{ padding: 8 }}>No orders are waiting for stock.</p>}
            {waiting.map((o) => <label key={o.id} className="check" style={{ padding: '5px 8px' }}><input type="checkbox" checked={picked.includes(o.id)} onChange={() => setPicked((p) => (p.includes(o.id) ? p.filter((x) => x !== o.id) : [...p, o.id]))} /><b>{o.order_ref}</b><span className="muted">{o.customer_name}</span><span className="dim">due {o.due_date?.slice(0, 10) ?? '—'}</span><span className="num" style={{ marginLeft: 'auto' }}>{o.units_short > 0 ? `${o.units_short} units short` : 'covered'}</span></label>)}
          </div>
        </Field>
        <Field label="Required by (optional)"><input type="date" className="input" value={reqBy} onChange={(e) => setReqBy(e.target.value)} /></Field>
        <p className="dim">The supplier is chosen above; the list is the customer orders whose missing stock will be bought from them. Only the stock each order still needs is ordered, after what is already reserved or on another PO. The PO is created as a draft; nothing is sent to the supplier until you approve it.</p>
        {err && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{err}</div>}
        <div className="row"><Button variant="primary" disabled={!supplier || picked.length === 0 || busy} onClick={() => void submit()}>{busy ? 'Creating…' : 'Create draft PO'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
