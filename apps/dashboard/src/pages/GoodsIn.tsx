import { useMemo, useState } from 'react';
import { Button, EmptyState, Field, Panel, Status } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { postJson } from '../lib/api';
import { shortDate } from '../lib/domain';
import type { PoLineRow, PoRow } from '../data/types';

interface Entry { good: string; damaged: string; wrong: string; batch: string; notes: string; final: boolean }
const blank = (l: PoLineRow): Entry => ({ good: String(l.qty_outstanding), damaged: '0', wrong: '0', batch: '', notes: '', final: true });
const n = (v: string) => Math.max(0, Math.floor(Number(v) || 0));

// The warehouse books a delivery in against an ATAM_FLOW purchase order: what actually arrived, what was damaged or wrong, and whether more is still coming.
export function GoodsInPage() {
  const pos = useView<PoRow>('ui_purchase_orders'); const lines = useView<PoLineRow>('ui_po_lines'); const { role } = useCtx(); const toast = useToast();
  const allowed = role === 'admin' || role === 'manager' || role === 'warehouse';
  const open = useMemo(() => pos.rows.filter((p) => p.origin === 'atam_flow' && p.units_outstanding > 0 && !['draft', 'cancelled', 'closed'].includes(p.po_status ?? '')).sort((a, b) => (a.expected_date ?? '9').localeCompare(b.expected_date ?? '9')), [pos.rows]);
  const [poId, setPoId] = useState(''); const [entries, setEntries] = useState<Record<string, Entry>>({}); const [delivery, setDelivery] = useState(''); const [receivedBy, setReceivedBy] = useState(''); const [notes, setNotes] = useState(''); const [evidence, setEvidence] = useState('');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [result, setResult] = useState<Record<string, any> | null>(null);
  const po = open.find((p) => p.po_id === poId); const poLines = useMemo(() => lines.rows.filter((l) => l.po_id === poId && l.qty_outstanding > 0).sort((a, b) => a.line_no - b.line_no), [lines.rows, poId]);
  const get = (l: PoLineRow): Entry => entries[l.id] ?? blank(l); const set = (l: PoLineRow, patch: Partial<Entry>) => setEntries((e) => ({ ...e, [l.id]: { ...get(l), ...patch } }));
  const summary = poLines.reduce((t, l) => { const e = get(l); const arrived = n(e.good) + n(e.damaged) + n(e.wrong); return { good: t.good + n(e.good), bad: t.bad + n(e.damaged) + n(e.wrong), short: t.short + (e.final ? Math.max(l.qty_outstanding - arrived, 0) : 0), over: t.over + Math.max(arrived - l.qty_outstanding, 0) }; }, { good: 0, bad: 0, short: 0, over: 0 });
  async function submit() {
    setBusy(true); setErr(null);
    const urls = evidence.split(/\s+/).filter((u) => /^https?:\/\//.test(u)).map((url) => ({ url, name: 'Delivery evidence' }));
    const receipt = { delivery_ref: delivery || null, received_by: receivedBy || null, notes: notes || null, evidence: urls,
      lines: poLines.map((l) => { const e = get(l); return { po_line_id: l.id, qty_received: n(e.good), qty_damaged: n(e.damaged), qty_incorrect: n(e.wrong), batch_ref: e.batch || null, notes: e.notes || null, final: e.final }; }).filter((l) => l.qty_received + l.qty_damaged + l.qty_incorrect > 0 || l.final) };
    const r = await postJson('goods-in', { po_id: poId, receipt }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'The delivery could not be booked in.')); return; }
    setResult(r); void refreshAll();
    toast.push({ tone: 'good', title: `Delivery booked in${r.receipt_code ? ` (${r.receipt_code})` : ''}`, body: 'Stock levels are updated and allocation is re-running.' });
  }
  if (result) { const disc = (result.discrepancies as any[] | undefined) ?? []; const orders = (result.affected_orders as any[] | undefined) ?? []; return (
    <div className="stack" style={{ gap: 16 }}><div className="page-head"><div><h1>Goods in</h1><p>Delivery booked in.</p></div></div>
      <Panel title={`Receipt ${String(result.receipt_code ?? '')}`} icon="stock"><div className="stack"><p>Purchase order status is now <b>{String(result.po_status ?? '').replace(/_/g, ' ')}</b>.</p>
        {disc.length > 0 ? <div className="callout" role="status"><b>{disc.length} discrepanc{disc.length === 1 ? 'y' : 'ies'} raised.</b> The supplier email is in the Purchasing review queue for you to approve before anything is sent.</div> : <p className="dim">No discrepancies: everything expected arrived in good condition.</p>}
        {orders.length > 0 && <p className="muted">Orders affected: {orders.map((o: any) => (typeof o === 'string' ? o : o.order_ref)).join(', ')}</p>}
        <div className="row"><Button variant="primary" onClick={() => { setResult(null); setPoId(''); setEntries({}); setDelivery(''); setNotes(''); setEvidence(''); }}>Book in another delivery</Button><a className="btn" href="#/purchasing">Open Purchasing</a><a className="btn" href="#/warehouse">Put goods away</a></div></div></Panel></div>); }
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Goods in</h1><p>Book a delivery in against its purchase order. Stock is updated with what actually arrived; shortages and damage raise a supplier issue automatically.</p></div></div>
      {!allowed && <div className="callout" role="status">Your role can look but not book goods in. Goods-in is for warehouse staff, managers and admins.</div>}
      <Panel>
        <Field label="Purchase order"><select className="select" value={poId} disabled={!allowed} onChange={(e) => { setPoId(e.target.value); setEntries({}); setErr(null); }}><option value="">{open.length ? 'Choose the PO this delivery is for…' : 'No ATAM_FLOW purchase orders are waiting for goods'}</option>{open.map((p) => <option key={p.po_id} value={p.po_id}>{p.po_ref} · {p.supplier} · {p.units_outstanding} units outstanding{p.expected_date ? ` · due ${shortDate(p.expected_date)}` : ''}</option>)}</select></Field>
        {open.length === 0 && !pos.loading && <EmptyState icon="purchasing" title="Nothing to book in">Approve and send a purchase order from Purchasing and it will appear here until its goods arrive.</EmptyState>}
      </Panel>
      {po && <Panel title={`${po.po_ref} · ${po.supplier}`} icon="purchasing" actions={po.is_late ? <Status tone="critical">{po.days_late}d late</Status> : undefined}>
        <div className="stack">
          <div className="grid" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
            <Field label="Supplier delivery note / ref"><input className="input" value={delivery} onChange={(e) => setDelivery(e.target.value)} /></Field>
            <Field label="Received by"><input className="input" value={receivedBy} onChange={(e) => setReceivedBy(e.target.value)} placeholder="Your name" /></Field>
          </div>
          <div style={{ overflowX: 'auto' }}><table className="table" style={{ minWidth: 760 }}><thead><tr><th>Line</th><th className="r">Expected</th><th className="r">Good</th><th className="r">Damaged</th><th className="r">Wrong item</th><th>Batch / ref</th><th>More coming?</th></tr></thead>
            <tbody>{poLines.map((l) => { const e = get(l); const arrived = n(e.good) + n(e.damaged) + n(e.wrong); return (<tr key={l.id}><td><b className="mono">{l.sku}</b><div className="dim">{[l.colour, l.size].filter(Boolean).join(' · ')}</div></td><td className="r num">{l.qty_outstanding}</td>
              <td className="r"><input aria-label={`Good ${l.sku}`} className="input" style={{ width: 70 }} type="number" min={0} value={e.good} onChange={(ev) => set(l, { good: ev.target.value })} /></td>
              <td className="r"><input aria-label={`Damaged ${l.sku}`} className="input" style={{ width: 70 }} type="number" min={0} value={e.damaged} onChange={(ev) => set(l, { damaged: ev.target.value })} /></td>
              <td className="r"><input aria-label={`Wrong ${l.sku}`} className="input" style={{ width: 70 }} type="number" min={0} value={e.wrong} onChange={(ev) => set(l, { wrong: ev.target.value })} /></td>
              <td><input aria-label={`Batch ${l.sku}`} className="input" style={{ width: 120 }} value={e.batch} onChange={(ev) => set(l, { batch: ev.target.value })} /></td>
              <td><label className="check"><input type="checkbox" checked={!e.final} onChange={(ev) => set(l, { final: !ev.target.checked })} />Yes, more to come</label>{e.final && arrived < l.qty_outstanding && <div><Status tone="high" plain>{l.qty_outstanding - arrived} short</Status></div>}{arrived > l.qty_outstanding && <div><Status tone="medium" plain>{arrived - l.qty_outstanding} over</Status></div>}</td></tr>); })}</tbody></table></div>
          <Field label="Photos of the delivery or problem (paste links, one per line or separated by spaces)"><textarea className="input" rows={2} value={evidence} onChange={(e) => setEvidence(e.target.value)} placeholder="https://…" /></Field>
          <p className="dim">Photo upload from the device is not built yet; for now paste a link to where the photo is stored.</p>
          <Field label="Notes"><textarea className="input" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
          <div className="callout" role="status">Booking in: <b>{summary.good}</b> good{summary.bad ? <>, <b>{summary.bad}</b> damaged or wrong</> : null}{summary.short ? <>, <b>{summary.short}</b> short (a supplier issue will be raised)</> : null}{summary.over ? <>, <b>{summary.over}</b> more than ordered</> : null}.</div>
          {err && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{err}</div>}
          <div className="row"><Button variant="primary" disabled={!allowed || busy || poLines.length === 0} onClick={() => void submit()}>{busy ? 'Booking in…' : 'Book in delivery'}</Button></div>
        </div></Panel>}
    </div>
  );
}
