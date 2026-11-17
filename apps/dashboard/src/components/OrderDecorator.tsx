import { useState } from 'react';
import { Button, Status } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { refreshAll, useView } from '../data/store';
import { useCtx } from '../data/context';
import { supabase } from '../lib/api';
import type { OrderDecoratorRow, ProducerRow } from '../data/types';

// Which decorator a third-party order goes to. Every third-party order follows the default (DPS) unless it is changed here.
export function OrderDecorator({ orderId }: { orderId: string }) {
  const dec = useView<OrderDecoratorRow>('ui_order_decorator_named'), producers = useView<ProducerRow>('ui_producers');
  const { role } = useCtx(); const toast = useToast(); const [editing, setEditing] = useState(false); const [pick, setPick] = useState(''); const [busy, setBusy] = useState(false);
  const d = dec.rows.find((x) => x.order_id === orderId);
  if (!d || d.scope !== 'third_party') return null;
  const can = role === 'admin' || role === 'manager' || role === 'production';
  async function save(producer: string | null) {
    setBusy(true); const { data, error } = await supabase.rpc('set_order_decorator', { p_order: orderId, p_producer: producer }); setBusy(false);
    const r = (data ?? {}) as { ok?: boolean; error?: string };
    if (error || r.ok === false) { toast.push({ tone: 'bad', title: 'Could not change the decorator', body: error?.message ?? r.error }); return; }
    toast.push({ tone: 'good', title: producer ? 'Decorator changed for this order' : 'Back to the default decorator' }); setEditing(false); void refreshAll();
  }
  return (
    <div className="callout soft" aria-label="Decorator for this order">
      <div className="row wrap" style={{ gap: 10, justifyContent: 'space-between' }}>
        <span><span className="fact-l">Decorator</span><br /><b>{d.producer_name ?? 'None set'}</b> {d.is_default ? <Status tone="info" plain>default</Status> : <Status tone="medium" plain>chosen for this order</Status>}</span>
        {can && !editing && <Button size="sm" onClick={() => { setPick(d.producer_id ?? ''); setEditing(true); }}>Change…</Button>}
      </div>
      {editing && <div className="row wrap" style={{ marginTop: 8, gap: 8 }}>
        <select className="select" aria-label="Decorator" value={pick} onChange={(e) => setPick(e.target.value)}><option value="">Choose a decorator…</option>{producers.rows.filter((p) => p.is_active).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
        <Button variant="primary" size="sm" disabled={!pick || busy} onClick={() => void save(pick)}>Save</Button>
        {!d.is_default && <Button size="sm" disabled={busy} onClick={() => void save(null)}>Use the default</Button>}
        <Button size="sm" variant="ghost" onClick={() => setEditing(false)}>Cancel</Button></div>}
    </div>);
}
