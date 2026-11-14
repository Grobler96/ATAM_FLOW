import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import { navigate } from '../router';
import { planPos, type PlanOrderInfo } from '../lib/poPlan';
import { money } from '../lib/domain';
import type { BuyLineRow, OrderDecoratorRow, OrderRow, ProducerRow } from '../data/types';

interface SupplierRow { id: string; name: string; email: string | null; lead_time_days: number; delivery_cost: number; can_deliver_to_producer?: boolean }

// Raises purchase orders from the stock that customer orders still need. The product catalogue decides the supplier for each item, so an
// order that needs items from two suppliers becomes two POs. Third-party orders are pre-set to be delivered straight to their decorator.
// A PO goes live as soon as it is raised (no draft, no approval); the email to the supplier still waits for a click on the Purchasing page.
export function CreatePoDialog({ open, onClose, presetOrders }: { open: boolean; onClose: () => void; presetOrders?: string[] }) {
  const suppliers = useView<SupplierRow>('ui_suppliers'), orders = useView<OrderRow>('ui_orders'), producers = useView<ProducerRow>('ui_producers');
  const buy = useView<BuyLineRow>('ui_order_buy_lines'), dec = useView<OrderDecoratorRow>('ui_order_decorator_named');
  const [picked, setPicked] = useState<string[] | null>(presetOrders && presetOrders.length ? presetOrders : null);
  const [fallback, setFallback] = useState(''); const [reqBy, setReqBy] = useState(''); const [busy, setBusy] = useState(false); const [errs, setErrs] = useState<string[]>([]);
  const [skip, setSkip] = useState<Set<string>>(new Set()); const [dest, setDest] = useState<Record<string, string>>({});
  const toast = useToast();

  const needing = useMemo(() => { const ids = new Set(buy.rows.map((l) => l.order_id)); return orders.rows.filter((o) => ids.has(o.id)).sort((a, b) => (a.due_date ?? '9').localeCompare(b.due_date ?? '9')); }, [orders.rows, buy.rows]);
  const chosen = picked ?? needing.map((o) => o.id);
  const info = useMemo(() => new Map<string, PlanOrderInfo>(dec.rows.map((d) => [d.order_id, { orderId: d.order_id, thirdParty: d.scope === 'third_party', producerId: d.producer_id, producerName: d.producer_name }])), [dec.rows]);
  const fb = suppliers.rows.find((s) => s.id === fallback);
  const plan = useMemo(() => planPos(buy.rows.filter((l) => chosen.includes(l.order_id)), info, fb ? { id: fb.id, name: fb.name } : null), [buy.rows, chosen, info, fb]);
  const live = plan.groups.filter((g) => !skip.has(g.key));
  const where = (g: (typeof plan.groups)[number]) => dest[g.key] ?? (g.deliverTo === 'producer' ? g.producerId ?? 'warehouse' : 'warehouse');

  async function submit() {
    setBusy(true); setErrs([]);
    const made: { id: string; ref: string }[] = []; const bad: string[] = []; const done = new Set<string>();
    for (const g of live) {
      const w = where(g);
      const r = await exceptionActionTo('purchasing', 'create_po_for_orders', { supplier_id: g.supplierId, order_ids: g.orderIds, options: { live: true, skus: g.skus, ...(reqBy ? { required_by: reqBy } : {}), ...(w !== 'warehouse' ? { deliver_to: 'producer', producer_id: w } : {}) } });
      if (r.ok === false) bad.push(`${g.supplier}: ${String(r.error ?? 'could not be raised')}`);
      else { made.push({ id: String(r.po_id ?? ''), ref: String(r.af_po_ref ?? '') }); done.add(g.key); }
    }
    setBusy(false); void refreshAll();
    if (made.length) toast.push({ tone: 'good', title: made.length === 1 ? `Purchase order ${made[0].ref} is live` : `${made.length} purchase orders are live`, body: `${made.map((m) => m.ref).join(', ')}. The email to the supplier is waiting under Purchasing → Emails.` });
    if (bad.length) { setErrs(bad); setSkip((s) => new Set([...s, ...done])); return; }
    onClose();
    if (made.length === 1 && made[0].id) navigate('purchasing/' + made[0].id); else navigate('purchasing');
  }
  const unassignedSkus = [...new Set(plan.unassigned.map((l) => l.sku))];
  return (
    <Modal open={open} onClose={onClose} title="Raise purchase orders">
      <div className="stack">
        <Field label={`Customer orders that still need stock (${chosen.length} chosen)`}>
          <div className="panel" style={{ maxHeight: 190, overflow: 'auto', padding: 6 }}>
            {buy.loading && <p className="dim" style={{ padding: 8 }}>Loading…</p>}
            {!buy.loading && needing.length === 0 && <p className="dim" style={{ padding: 8 }}>No orders need stock buying right now.</p>}
            {needing.map((o) => <label key={o.id} className="check" style={{ padding: '5px 8px' }}><input type="checkbox" checked={chosen.includes(o.id)} onChange={() => setPicked(chosen.includes(o.id) ? chosen.filter((x) => x !== o.id) : [...chosen, o.id])} /><b>{o.order_ref}</b><span className="muted">{o.customer_name}</span><span className="dim">due {o.due_date?.slice(0, 10) ?? '—'}</span><span className="num" style={{ marginLeft: 'auto' }}>{buy.rows.filter((l) => l.order_id === o.id).reduce((t, l) => t + l.qty_needed, 0)} units to buy</span></label>)}
          </div>
        </Field>
        {plan.unassigned.length > 0 && <div className="callout" role="status"><b>{unassignedSkus.length} item(s) are not in the product catalogue</b>, so Flow does not know who to buy them from ({unassignedSkus.slice(0, 6).join(', ')}{unassignedSkus.length > 6 ? '…' : ''}). Choose a supplier for them, or add them to the catalogue.
          <div style={{ marginTop: 8 }}><select className="select" aria-label="Supplier for items not in the catalogue" value={fallback} onChange={(e) => setFallback(e.target.value)}><option value="">Leave them out for now</option>{suppliers.rows.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></div></div>}
        {plan.groups.length === 0 && plan.unassigned.length === 0 && chosen.length > 0 && !buy.loading && <p className="dim">Nothing left to buy for these orders.</p>}
        {plan.groups.map((g) => { const sup = suppliers.rows.find((s) => s.id === g.supplierId); const w = where(g); const on = !skip.has(g.key);
          return (
            <section key={g.key} className="panel" style={{ padding: 12, opacity: on ? 1 : 0.55 }} aria-label={`Purchase order to ${g.supplier}`}>
              <div className="row" style={{ justifyContent: 'space-between', gap: 8 }}>
                <label className="check"><input type="checkbox" checked={on} onChange={() => setSkip((s) => { const n = new Set(s); if (n.has(g.key)) n.delete(g.key); else n.add(g.key); return n; })} /><b>{g.supplier}</b></label>
                <span className="num">{g.units} units · {g.missingCost ? 'cost missing' : money(g.cost, 2)}</span></div>
              <div style={{ overflow: 'auto', margin: '8px 0' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                <thead><tr className="dim" style={{ textAlign: 'left' }}>{['Item', 'Product', 'Colour', 'Size', 'Qty', 'Cost', 'For orders'].map((h) => <th key={h} style={{ padding: '4px 6px' }}>{h}</th>)}</tr></thead>
                <tbody>{g.lines.map((l) => <tr key={l.sku + l.colour + l.size} style={{ borderTop: '1px solid var(--border)' }}><td className="mono" style={{ padding: '4px 6px' }}>{l.sku}</td><td style={{ padding: '4px 6px' }}>{l.product}</td><td style={{ padding: '4px 6px' }}>{l.colour}</td><td style={{ padding: '4px 6px' }}>{l.size}</td><td className="num" style={{ padding: '4px 6px' }}>{l.qty}</td><td className={`num ${l.unitCost === null ? 'bad' : ''}`} style={{ padding: '4px 6px' }}>{l.unitCost === null ? 'no cost' : money(l.unitCost, 2)}</td><td className="dim" style={{ padding: '4px 6px' }}>{l.orders.join(', ')}</td></tr>)}</tbody></table></div>
              <Field label="Deliver to">
                <select className="select" value={w} onChange={(e) => setDest((d) => ({ ...d, [g.key]: e.target.value }))}>
                  <option value="warehouse">Our warehouse</option>
                  {producers.rows.filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>Straight to {p.name}{p.id === g.producerId ? ' (this order’s decorator)' : ''}</option>)}
                </select></Field>
              {w !== 'warehouse' && sup && sup.can_deliver_to_producer === false && <p className="warn" role="status">{sup.name} is not marked as able to deliver straight to a decorator. Check with them first.</p>}
              {g.missingCost > 0 && <p className="warn" role="status">{g.missingCost} item(s) have no cost in the catalogue. The PO cannot go live until every line has a cost.</p>}
            </section>); })}
        <Field label="Required by (optional)"><input type="date" className="input" value={reqBy} onChange={(e) => setReqBy(e.target.value)} /></Field>
        <p className="dim">Each PO goes live straight away. The email to the supplier waits for one click under Purchasing → Emails.</p>
        {errs.length > 0 && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{errs.map((e) => <div key={e}>{e}</div>)}</div>}
        <div className="row"><Button variant="primary" disabled={live.length === 0 || busy || live.some((g) => g.missingCost > 0)} onClick={() => void submit()}>{busy ? 'Raising…' : live.length > 1 ? `Raise ${live.length} purchase orders` : 'Raise purchase order'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
