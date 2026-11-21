import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { refreshAll } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import { href } from '../router';
import { batchItems, planBuild, refsOf, type DtfBatchRow } from '../lib/dtfOrders';
import { dtfStatusWords, LIGHT_TONE, STATUS_LIGHT, type DtfItemRow } from '../lib/preproduction';

// Building a DTF order to Super Print, and booking the prints in when they arrive. Building creates the order and queues its email for a person's
// approval; nothing is sent from here. Everything is recorded in the audit trail.
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const Thumb = ({ url }: { url: string | null }) => <span style={{ width: 40, height: 40, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden', flex: '0 0 40px' }}>{url ? <img src={url} alt="" loading="lazy" style={{ maxWidth: 40, maxHeight: 40 }} /> : <span className="dim" aria-hidden>–</span>}</span>;

export function BuildDtfDialog({ orderIds, items, onClose }: { orderIds: string[]; items: DtfItemRow[]; onClose: () => void }) {
  const plan = planBuild(items, orderIds); const toast = useToast();
  const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [done, setDone] = useState<{ ref: string; message: string; noRecipient: boolean; skipped: number } | null>(null);
  async function build() {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('dtf', 'build_order', { order_ids: [...new Set(plan.included.map((i) => i.order_id))], note: note.trim() });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    setDone({ ref: String(r.batch_ref ?? ''), message: String(r.note ?? 'DTF order created.'), noRecipient: r.no_recipient === true, skipped: Array.isArray(r.skipped) ? r.skipped.length : 0 });
    toast.push({ tone: 'good', title: `DTF order ${String(r.batch_ref ?? '')} created`, body: String(r.note ?? 'Its email is waiting for approval. Nothing has been sent.') }); void refreshAll();
  }
  return (
    <Modal open onClose={onClose} title="Build a DTF order">
      <div className="stack">
        {!done && <>
          <p>This makes one DTF order to <b>Super Print</b> for the {plan.orders} order{plan.orders === 1 ? '' : 's'} below. It lists each design once with its total number of prints, a picture and a download link for the file. <b>Nothing is sent</b>: the email waits for a person to approve it.</p>
          {plan.designs.length === 0 ? <Err m="Nothing can go on a DTF order from the orders you ticked. See why below." /> : <div className="stack" style={{ gap: 4 }}>
            <b>{plan.designs.length} design{plan.designs.length === 1 ? '' : 's'} · {plan.prints.toLocaleString('en-GB')} print{plan.prints === 1 ? '' : 's'}</b>
            {plan.designs.slice(0, 30).map((d) => <div key={d.key} className="row wrap" style={{ gap: 10 }}><Thumb url={d.thumbnail_url} /><span className="grow">{d.label}</span><span className="num">{d.qty} print{d.qty === 1 ? '' : 's'}</span><span className="dim">{d.orders} order{d.orders === 1 ? '' : 's'}</span></div>)}
            {plan.designs.length > 30 && <span className="dim">and {plan.designs.length - 30} more designs</span>}</div>}
          {plan.skipped.map((s) => <div key={s.reason} className="callout soft" role="status"><b>Left out: {s.reason}</b><div className="dim">{s.items.length} placement{s.items.length === 1 ? '' : 's'} · {refsOf(s.items)}</div></div>)}
          <Field label="A note for the DTF order (optional, kept on the order)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="For example Needed by Friday" /></Field>
          {err && <Err m={err} />}
          <div className="row"><Button variant="primary" disabled={busy || plan.included.length === 0} onClick={() => void build()}>{busy ? 'Building…' : `Build DTF order (${plan.prints.toLocaleString('en-GB')} prints)`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
        </>}
        {done && <>
          <p role="status"><b>DTF order {done.ref} created.</b> {done.message}</p>
          {done.noRecipient && <div className="callout" role="status">Super Print has no email address in Flow yet, so the email stays a draft that cannot be approved. Add the address to the supplier, then approve the email under <a href={href('purchasing')}>Purchasing, Emails</a>.</div>}
          {!done.noRecipient && <p>Approve it under <a href={href('purchasing')}>Purchasing, Emails</a>. When it is sent the prints go to amber (Prints ordered).</p>}
          <div className="row"><Button variant="primary" onClick={onClose}>Done</Button></div>
        </>}
      </div>
    </Modal>
  );
}

export function ReceiveDtfDialog({ batch, items, onClose }: { batch: DtfBatchRow; items: DtfItemRow[]; onClose: () => void }) {
  const mine = batchItems(items, batch.id); const toast = useToast();
  const [picked, setPicked] = useState<Set<string>>(() => new Set(mine.filter((i) => i.status !== 'done').map((i) => i.id)));
  const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const toggle = (id: string) => setPicked((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  async function save() {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('dtf', 'receive', { batch_id: batch.id, item_ids: [...picked], note: note.trim() });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: r.complete === true ? `${batch.batch_ref} fully received` : `${String(r.received ?? picked.size)} print${picked.size === 1 ? '' : 's'} booked in`, body: r.complete === true ? 'Every print on this DTF order has arrived.' : `${String(r.left ?? '')} still to come.` }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={`DTF received: ${batch.batch_ref}`}>
      <div className="stack">
        <p className="dim">Tick the prints that have arrived. Each shows its picture so you can match it up. The rest stay on order.</p>
        <div className="stack" style={{ gap: 4 }}>{mine.map((i) => <label key={i.id} className="row wrap" style={{ gap: 10, opacity: i.status === 'done' ? 0.6 : 1 }}>
          <input type="checkbox" checked={picked.has(i.id)} disabled={i.status === 'done'} onChange={() => toggle(i.id)} aria-label={`${i.order_ref} ${i.area}`} />
          <Thumb url={i.thumbnail_url} /><b className="mono">{i.order_ref}</b><span className="grow">{i.area}{i.product_name ? ` · ${i.product_name}` : ''}</span><span className="num">{i.qty} print{i.qty === 1 ? '' : 's'}</span>
          <Status tone={LIGHT_TONE[STATUS_LIGHT[i.status]]}>{dtfStatusWords(i.status)}</Status></label>)}</div>
        <Field label="A note (optional, for example a short delivery)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || picked.size === 0} onClick={() => void save()}>{busy ? 'Saving…' : `Mark ${picked.size} as received`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
