import { Button, Status } from '../ui/primitives';
import { batchTone, batchWords, type DtfBatchRow } from '../lib/dtfOrders';
import { artworkTotals, fileWords, type DtfItemRow } from '../lib/preproduction';
import { shortDate } from '../lib/domain';
import { href } from '../router';

// The pieces of the In house "DTF prints" page: the DTF orders to Super Print, and what has to be made by design.
export function BatchList({ batches, loading, empty, canReceive, onReceive, warn }: { batches: DtfBatchRow[]; loading: boolean; empty: string; canReceive: boolean; onReceive?: (b: DtfBatchRow) => void; warn?: (b: DtfBatchRow) => string | null }) {
  if (loading) return <p className="dim" style={{ padding: 16, margin: 0 }}>Loading…</p>;
  if (batches.length === 0) return <p className="dim" style={{ padding: 16, margin: 0 }}>{empty}</p>;
  return (
    <div>{batches.map((b) => (
      <div key={b.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', gap: 12 }} data-testid={`dtf-batch-${b.batch_ref}`}>
        <b className="mono" style={{ minWidth: 130 }}>{b.batch_ref}</b><Status tone={batchTone(b)}>{batchWords(b)}</Status>
        <span className="grow dim">{b.received} of {b.placements} placements booked in · {b.prints.toLocaleString('en-GB')} prints{b.ordered_at ? ` · ordered ${shortDate(b.ordered_at)}` : ''}{b.received_at ? ` · booked in ${shortDate(b.received_at)}` : ''}{b.comm_ref ? ` · email ${b.comm_ref}` : ''}</span>
        {b.status === 'draft' && <a href={href('purchasing/emails')} title="Opens Purchasing on the Emails section, where a person approves the email to Super Print">Open the email{b.comm_ref ? ` ${b.comm_ref}` : ''} to approve it</a>}
        {warn?.(b) && <div className="callout" role="alert" style={{ flexBasis: '100%' }}>{warn(b)}</div>}
        {b.status === 'ordered' && onReceive && <Button disabled={!canReceive} title={canReceive ? '' : 'Your role cannot book prints in'} onClick={() => onReceive(b)}>DTF received…</Button>}
      </div>))}
    </div>
  );
}

export function DesignList({ items, loading }: { items: DtfItemRow[]; loading: boolean }) {
  const totals = artworkTotals(items);
  if (loading) return <p className="dim" style={{ padding: 16, margin: 0 }}>Loading…</p>;
  if (totals.length === 0) return <p className="dim" style={{ padding: 16, margin: 0 }}>No DTF prints are needed.</p>;
  return (
    <div>{totals.slice(0, 60).map((t) => (
      <div key={t.key} className="row wrap" style={{ padding: '8px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}>
        <span style={{ width: 44, height: 44, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', borderRadius: 6, overflow: 'hidden' }}>{t.thumbnail_url ? <img src={t.thumbnail_url} alt="" loading="lazy" style={{ maxWidth: 44, maxHeight: 44 }} /> : <span className="dim" aria-hidden>–</span>}</span>
        <b className="grow" style={{ minWidth: 180 }}>{t.label}</b><span className="num" style={{ minWidth: 150 }}>{t.outstanding.toLocaleString('en-GB')} to make · {t.qty.toLocaleString('en-GB')} in all</span>
        <span className="dim" style={{ minWidth: 120 }}>{t.orders} order{t.orders === 1 ? '' : 's'}</span>
        {t.hasFile ? <Status tone="good" plain>File ready{t.file_format ? ` (${t.file_format.toUpperCase()})` : ''}</Status> : <Status tone="high" plain>{fileWords({ artwork_id: null, storage_status: null, file_format: null })}</Status>}
      </div>))}
      {totals.length > 60 && <p className="dim" style={{ padding: '8px 16px', margin: 0 }}>Showing the first 60 designs of {totals.length}.</p>}
    </div>
  );
}
