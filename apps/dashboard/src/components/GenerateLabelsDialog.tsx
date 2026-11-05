import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { useView } from '../data/store';
import { LABEL_TYPES, whAction } from '../lib/warehouse';
import { refreshAll } from '../data/store';
import type { BinRow, OrderRow, StockLocRow } from '../data/types';

interface MovementRow { movement_code: string; producer_name: string; status: string; order_refs: string[] | null }
interface Target { ref: string; title: string; sub: string }

// Creates label records (and their QR payloads) for the chosen things. Printing happens afterwards from the Labels page.
export function GenerateLabelsDialog({ open, onClose, presetType, presetRefs }: { open: boolean; onClose: () => void; presetType?: string; presetRefs?: string[] }) {
  const orders = useView<OrderRow>('ui_orders'), bins = useView<BinRow>('ui_bins'), stock = useView<StockLocRow>('ui_stock_locations'), moves = useView<MovementRow>('ui_tp_movements');
  const [type, setType] = useState(presetType ?? 'order'); const [picked, setPicked] = useState<string[]>(presetRefs ?? []); const [q, setQ] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const toast = useToast();
  const targets: Target[] = useMemo(() => {
    if (['order', 'pick', 'dispatch'].includes(type)) return orders.rows.filter((o) => o.shipped_at == null).map((o) => ({ ref: o.order_ref, title: o.order_ref, sub: `${o.customer_name ?? ''} · ${o.total_units} units` }));
    if (type === 'bin') return bins.rows.filter((b) => b.is_active).map((b) => ({ ref: b.bin_code, title: b.bin_code, sub: `${b.zone_name ?? ''}${b.label_printed ? ' · label printed' : ''}` }));
    if (type === 'stock') return stock.rows.map((s) => ({ ref: s.sku, title: s.sku, sub: [s.product_name, s.colour, s.size].filter(Boolean).join(' · ') }));
    return moves.rows.map((m) => ({ ref: m.movement_code, title: m.movement_code, sub: `${m.producer_name} · ${m.status.replace(/_/g, ' ')}` }));
  }, [type, orders.rows, bins.rows, stock.rows, moves.rows]);
  const shown = targets.filter((t) => !q || (t.title + ' ' + t.sub).toLowerCase().includes(q.toLowerCase())).slice(0, 200);
  const info = LABEL_TYPES.find((t) => t.id === type)!;
  async function go() {
    setBusy(true); setErr(null);
    const r = await whAction('generate_labels', { type, refs: picked });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'Could not generate the labels.')); return; }
    void refreshAll();
    const failed = Number(r.failed ?? 0), made = Number(r.created ?? 0);
    toast.push({ tone: failed ? 'info' : 'good', title: `${picked.length - failed} label(s) ready${made ? `, ${made} new` : ' (already up to date)'}`, body: failed ? `${failed} could not be generated.` : 'They are waiting in the Labels page to be printed.', href: '#/labels?view=await', linkLabel: 'Open Labels' });
    onClose();
  }
  return (
    <Modal open={open} onClose={onClose} title="Generate labels">
      <div className="stack">
        <Field label="Label type"><select className="select" value={type} onChange={(e) => { setType(e.target.value); setPicked([]); }}>{LABEL_TYPES.map((t) => <option key={t.id} value={t.id}>{t.label}</option>)}</select></Field>
        <Field label={`Choose ${info.target} (${picked.length} chosen)`}>
          <input className="input" placeholder="Filter…" value={q} onChange={(e) => setQ(e.target.value)} />
          <div className="panel" style={{ maxHeight: 240, overflow: 'auto', padding: 6, marginTop: 6 }}>
            {shown.length === 0 && <p className="dim" style={{ padding: 8 }}>Nothing to label here yet.</p>}
            {shown.map((t) => <label key={t.ref} className="check" style={{ padding: '5px 8px' }}><input type="checkbox" checked={picked.includes(t.ref)} onChange={() => setPicked((p) => (p.includes(t.ref) ? p.filter((x) => x !== t.ref) : [...p, t.ref]))} /><b className="mono">{t.title}</b><span className="muted">{t.sub}</span></label>)}
          </div>
        </Field>
        <p className="dim">Generating again later is safe: unchanged labels are left alone, and a label that was already printed but whose details changed is flagged for reprint.</p>
        {err && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{err}</div>}
        <div className="row"><Button variant="primary" disabled={picked.length === 0 || busy} onClick={() => void go()}>{busy ? 'Generating…' : `Generate ${picked.length || ''} label(s)`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
