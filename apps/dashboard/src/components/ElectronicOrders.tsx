import { useMemo, useState } from 'react';
import { Button, EmptyState, Panel, Skeleton, Status } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { refreshAll, useView } from '../data/store';
import { useCtx } from '../data/context';
import { supabase } from '../lib/api';
import { money, shortDate } from '../lib/domain';
import type { PoTransmissionRow } from '../data/types';

const LABEL: Record<PoTransmissionRow['status'], string> = { pending_review: 'Waiting for approval', queued: 'Approved, will be sent', sending: 'Sending', sent: 'Sent', failed: 'Failed', cancelled: 'Cancelled' };
const TONE: Record<PoTransmissionRow['status'], 'good' | 'medium' | 'high' | 'critical' | 'info'> = { pending_review: 'high', queued: 'info', sending: 'info', sent: 'good', failed: 'critical', cancelled: 'medium' };
const METHOD = { api: 'API', edi: 'EDI file' } as const;

// Purchase orders to suppliers we order from electronically (their card says API or EDI). Nothing is sent until a manager or admin approves it here;
// the sending itself is done by n8n, which needs the supplier's login set up first.
export function ElectronicOrders() {
  const tx = useView<PoTransmissionRow>('ui_po_transmissions'); const { senior } = useCtx(); const toast = useToast();
  const [busy, setBusy] = useState<string | null>(null); const [cancelling, setCancelling] = useState<string | null>(null); const [reason, setReason] = useState('');
  const rows = useMemo(() => [...tx.rows].sort((a, b) => (a.status === 'pending_review' || a.status === 'failed' ? 0 : 1) - (b.status === 'pending_review' || b.status === 'failed' ? 0 : 1) || b.queued_at.localeCompare(a.queued_at)), [tx.rows]);
  async function call(id: string, fn: 'po_tx_approve' | 'po_tx_cancel', args: Record<string, unknown>, done: string) {
    setBusy(id); const { data, error } = await supabase.rpc(fn, args); setBusy(null);
    const r = (data ?? {}) as { ok?: boolean; error?: string };
    if (error || r.ok === false) { toast.push({ tone: 'bad', title: 'Could not do that', body: error?.message ?? r.error }); return; }
    toast.push({ tone: 'good', title: done }); setCancelling(null); setReason(''); void tx.refresh(); void refreshAll();
  }
  return (
    <Panel title={`Orders to suppliers by API or EDI · ${rows.filter((r) => r.status === 'pending_review' || r.status === 'failed').length} need a decision`} flush>
      <p className="dim" style={{ padding: '12px 16px 0' }}>These are purchase orders to suppliers we order from electronically. Approving one tells n8n to send it to the supplier (Ralawise by API, ORN as a file on their SFTP server). Check the lines and value first: a real order is placed. A failed order is kept with its reason; approve it again to try again.</p>
      {tx.loading ? <Skeleton h={120} /> : rows.length === 0 ? <EmptyState icon="stock" title="No electronic orders yet">Raise a PO to a supplier whose card says API or EDI, then send it: it appears here to approve.</EmptyState> :
        <div className="stack" style={{ gap: 0 }}>{rows.map((r) => (
          <div key={r.id} className="stack" style={{ gap: 6, padding: '10px 16px', borderTop: '1px solid var(--border)' }} data-testid={`etx-${r.po_ref}`}>
            <div className="row wrap" style={{ justifyContent: 'space-between', gap: 12 }}>
              <span><b className="mono">{r.po_ref}</b> · {r.supplier} · {METHOD[r.method]} · {r.line_count} lines · {money(r.goods_value, 2)}</span>
              <span className="row" style={{ gap: 8 }}><Status tone={TONE[r.status]}>{LABEL[r.status]}</Status>
                {senior && (r.status === 'pending_review' || r.status === 'failed') && <Button variant="primary" size="sm" disabled={busy === r.id} onClick={() => void call(r.id, 'po_tx_approve', { p_id: r.id }, `${r.po_ref} approved: it will be sent to ${r.supplier}`)}>{r.status === 'failed' ? 'Approve to try again' : 'Approve and send'}</Button>}
                {senior && (r.status === 'pending_review' || r.status === 'queued' || r.status === 'failed') && <Button size="sm" onClick={() => { setCancelling(cancelling === r.id ? null : r.id); setReason(''); }}>Cancel</Button>}
              </span></div>
            <div className="dim">Prepared {shortDate(r.queued_at)} by {r.queued_by}{r.approved_by ? ` · approved by ${r.approved_by}` : ''}{r.sent_at ? ` · sent ${shortDate(r.sent_at)}` : ''}{r.supplier_order_ref ? ` · their order number ${r.supplier_order_ref}` : ''}{r.attempts > 1 ? ` · ${r.attempts} tries` : ''}{r.cancel_reason ? ` · ${r.cancel_reason}` : ''}</div>
            {r.last_error && r.status === 'failed' && <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{r.last_error}</div>}
            {r.last_error && r.status === 'sent' && <div className="callout" role="status">The supplier sent a warning with this order: {r.last_error}. Check the order on their side.</div>}
            {cancelling === r.id && <div className="row wrap"><input className="input" aria-label={`Reason for cancelling ${r.po_ref}`} placeholder="Why is this being cancelled? (at least 5 characters)" value={reason} onChange={(e) => setReason(e.target.value)} style={{ minWidth: 280 }} /><Button size="sm" variant="primary" disabled={reason.trim().length < 5 || busy === r.id} onClick={() => void call(r.id, 'po_tx_cancel', { p_id: r.id, p_reason: reason.trim() }, `${r.po_ref} cancelled`)}>Cancel this order</Button></div>}
          </div>))}</div>}
    </Panel>
  );
}
