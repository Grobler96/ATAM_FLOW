import { useState, type FormEvent } from 'react';
import { exceptionAction, findOrderId } from '../lib/api';

const CATEGORIES = ['stock', 'purchasing', 'producer', 'artwork', 'production', 'quality', 'logistics', 'order', 'other'];

export function RaiseDialog({ me, onClose, onDone }: { me: string | null; onClose: () => void; onDone: (msg: string) => Promise<void> }) {
  const [category, setCategory] = useState('other');
  const [severity, setSeverity] = useState('medium');
  const [description, setDescription] = useState('');
  const [orderRef, setOrderRef] = useState('');
  const [owner, setOwner] = useState(me ?? '');
  const [deadline, setDeadline] = useState('');
  const [blocks, setBlocks] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(ev: FormEvent) {
    ev.preventDefault(); setBusy(true); setError(null);
    const links: unknown[] = [];
    if (orderRef.trim()) {
      const id = await findOrderId(orderRef.startsWith('#') ? orderRef : '#' + orderRef);
      if (!id) { setBusy(false); setError(`No order called ${orderRef.trim()} was found. Check the number, or leave it blank.`); return; }
      links.push({ type: 'order', id });
    }
    const r = await exceptionAction('raise', { category, severity, description, links, owner: owner.trim() || undefined, deadline: deadline ? new Date(deadline).toISOString() : undefined, blocks });
    setBusy(false);
    if (r.ok === false) { setError(r.error ?? 'That did not work.'); return; }
    await onDone('Issue raised.');
  }
  const toggle = (b: string) => setBlocks((x) => (x.includes(b) ? x.filter((y) => y !== b) : [...x, b]));

  return (
    <div className="scrim" onClick={onClose}>
      <form className="dialog" role="dialog" aria-modal="true" aria-label="Raise an issue" onClick={(e) => e.stopPropagation()} onSubmit={submit}>
        <h2>Raise an issue</h2>
        <label>What is wrong?<textarea rows={3} required value={description} onChange={(e) => setDescription(e.target.value)} placeholder="e.g. Customer reports faded print on order #636220" /></label>
        <div className="two">
          <label>Type<select value={category} onChange={(e) => setCategory(e.target.value)}>{CATEGORIES.map((c) => <option key={c}>{c}</option>)}</select></label>
          <label>How serious?<select value={severity} onChange={(e) => setSeverity(e.target.value)}><option>low</option><option>medium</option><option>high</option><option>critical</option></select></label>
        </div>
        <div className="two">
          <label>Order number (optional)<input value={orderRef} onChange={(e) => setOrderRef(e.target.value)} placeholder="636220" inputMode="numeric" /></label>
          <label>Owner<input value={owner} onChange={(e) => setOwner(e.target.value)} /></label>
        </div>
        <label>Respond by (optional)<input type="datetime-local" value={deadline} onChange={(e) => setDeadline(e.target.value)} /></label>
        <fieldset><legend>Stops the order from…</legend>
          {['completion', 'dispatch', 'production'].map((b) => <label className="check" key={b}><input type="checkbox" checked={blocks.includes(b)} onChange={() => toggle(b)} /> {b === 'completion' ? 'being completed' : b === 'dispatch' ? 'being dispatched' : 'going into production'}</label>)}
        </fieldset>
        {error && <div className="alert error" role="alert">{error}</div>}
        <div className="btn-row"><button className="btn primary" disabled={busy || !description.trim()}>{busy ? 'Saving…' : 'Raise issue'}</button><button type="button" className="btn" onClick={onClose}>Cancel</button></div>
      </form>
    </div>
  );
}
