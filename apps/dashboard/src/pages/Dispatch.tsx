import { useMemo, useState } from 'react';
import { Button, Facts, Field, Kpi, Panel, Status } from '../ui/primitives';
import { DataTable, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { useFocus } from '../data/focus';
import { FocusBar } from '../components/FocusBar';
import { DueCell, PriorityCell } from '../components/common';
import { ScanPanel } from '../scan/ScanPanel';
import { parseScan } from '../scan/parse';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { dateTime } from '../lib/format';
import type { PrintFormat } from '../lib/warehouse';
import { addressLines, dispatchCancel, dispatchHandover, dispatchPack, dispatchPrinted, dispatchTracking, printParcelLabels, STAGE_LABEL, STAGE_TONE, type ParcelRow, type QueueRow } from '../lib/dispatch';

const firstLine = (t: string | null) => addressLines(t)[0] ?? '';
const postcode = (t: string | null) => { const m = String(t ?? '').match(/[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}/i); return m ? m[0].toUpperCase() : ''; };

export function DispatchPage({ route }: { route: Route }) {
  const q = useView<QueueRow>('ui_dispatch_queue'); const parcels = useView<ParcelRow>('ui_dispatch_parcels');
  const { canAct } = useCtx(); const focus = useFocus(); const [handover, setHandover] = useState(false);
  const rows = useMemo(() => q.rows.filter((r) => !focus.hideOrder(r.order_id)), [q.rows, focus]); const hidden = q.rows.length - rows.length;
  const refresh = async () => { await Promise.all([q.refresh(), parcels.refresh()]); };
  const open = route.path[1];
  const sel = open ? q.rows.find((r) => r.order_ref.replace('#', '') === open) : null;
  const count = (s: QueueRow['stage']) => rows.filter((r) => r.stage === s).length;

  const views: ViewDef<QueueRow>[] = [
    { id: 'ready', label: 'Ready to pack', test: (r) => r.stage === 'ready' }, { id: 'blocked', label: 'Blocked', test: (r) => r.stage === 'blocked' }, { id: 'packed', label: 'Packed', test: (r) => r.stage === 'packed' },
    { id: 'courier', label: 'With courier', test: (r) => r.stage === 'with_courier' }, { id: 'shipped', label: 'Shipped', test: (r) => r.stage === 'shipped' }, { id: 'all', label: 'All', test: () => true }
  ];
  const filters: FilterDef<QueueRow>[] = [
    { id: 'method', label: 'Shipping method', options: [...new Set(rows.map((r) => r.shipping_method).filter(Boolean) as string[])].sort().map((v) => ({ value: v, label: v })), test: (r, v) => r.shipping_method === v },
    { id: 'due', label: 'Due', options: [{ value: 'late', label: 'Overdue' }, { value: 'today', label: 'Today' }, { value: '3', label: 'Next 3 days' }], test: (r, v) => r.days_to_due != null && (v === 'late' ? r.days_to_due < 0 : v === 'today' ? r.days_to_due === 0 : r.days_to_due >= 0 && r.days_to_due <= 3) }
  ];
  const cols: Column<QueueRow>[] = [
    { id: 'ref', header: 'Order', width: '104px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'customer', header: 'Customer', width: '200px', render: (r) => <span title={r.customer_name ?? ''}>{r.customer_name ?? '—'}</span>, sort: (r) => r.customer_name?.toLowerCase() ?? null, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '170px', render: (r) => <DueCell days={r.days_to_due} date={r.due_date} />, sort: (r) => r.due_date, csv: (r) => r.due_date?.slice(0, 10) },
    { id: 'priority', header: 'Priority', width: '110px', render: (r) => <PriorityCell p={r.priority} vip={r.is_vip} />, sort: (r) => r.priority, csv: (r) => r.priority },
    { id: 'stage', header: 'Stage', width: '140px', render: (r) => <Status tone={STAGE_TONE[r.stage]}>{STAGE_LABEL[r.stage]}{r.stage === 'ready' && r.partial ? ' (partly)' : ''}</Status>, sort: (r) => r.stage, csv: (r) => STAGE_LABEL[r.stage] },
    { id: 'why', header: 'What is stopping it', width: '320px', render: (r) => r.stage === 'blocked' ? <span className="warn" title={r.blockers.join('; ')}>{r.blockers[0] ?? 'Not ready'}{r.blockers.length > 1 ? ` (+${r.blockers.length - 1})` : ''}</span> : r.stage === 'ready' && r.partial ? <span className="dim">Only the checked units; the rest is still with a decorator</span> : <span className="dim">—</span>, csv: (r) => r.blockers.join('; ') },
    { id: 'to', header: 'Deliver to', width: '230px', render: (r) => r.is_collection ? <Status tone="info" plain>Customer collects</Status> : <span title={r.ship_to ?? ''}>{firstLine(r.ship_to)} <span className="dim mono">{postcode(r.ship_to)}</span></span>, csv: (r) => r.ship_to },
    { id: 'method', header: 'Method', width: '200px', render: (r) => <span className="dim" title={r.shipping_method ?? ''}>{r.shipping_method ?? '—'}</span>, sort: (r) => r.shipping_method, csv: (r) => r.shipping_method },
    { id: 'units', header: 'Units', width: '90px', align: 'r', render: (r) => <span className="num">{r.ready_units || r.units}</span>, sort: (r) => r.ready_units || r.units, csv: (r) => r.ready_units || r.units },
    { id: 'bins', header: 'Bin', width: '110px', render: (r) => <span className="mono dim">{r.bins ?? '—'}</span>, csv: (r) => r.bins },
    { id: 'parcels', header: 'Parcels', width: '120px', render: (r) => r.parcels ? <span className="num">{r.parcels_handed}/{r.parcels} handed</span> : <span className="dim">—</span>, sort: (r) => r.parcels, csv: (r) => r.parcels },
    { id: 'tracking', header: 'Tracking', width: '190px', render: (r) => r.tracking ? <span className="mono">{r.tracking}</span> : r.parcels ? <span className="warn">Not entered</span> : <span className="dim">—</span>, csv: (r) => r.tracking }
  ];

  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Dispatch</h1><p>Orders ready to go out: pack, print the courier label, add tracking and hand over. Marking an order shipped is still done in DecoNetwork.</p></div>
        <div className="row"><Button variant="primary" icon="labels" disabled={!canAct} title={canAct ? undefined : 'Your role cannot hand parcels over'} onClick={() => setHandover(true)}>Hand over (scan)</Button></div></div>
      <FocusBar focus={focus} hidden={[{ n: hidden, noun: 'order' }]} />
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 12 }}>
        <Kpi label="Ready to pack" value={count('ready')} tone={count('ready') ? 'good' : ''} /><Kpi label="Blocked" value={count('blocked')} tone={count('blocked') ? 'high' : ''} />
        <Kpi label="Packed, waiting for the courier" value={count('packed')} /><Kpi label="With the courier" value={count('with_courier')} />
      </div>
      <Panel flush>
        <DataTable<QueueRow> rows={rows} columns={cols} rowKey={(r) => r.order_id} loading={q.loading} error={q.error} onRetry={() => void q.refresh()} views={views} filters={filters} storageKey="dispatch" exportName="dispatch"
          searchText={(r) => [r.order_ref, r.customer_name, r.customer_po, r.ship_to, r.shipping_method, r.tracking, r.bins].join(' ')} searchPlaceholder="Search order, customer, address, tracking, bin…"
          onRowClick={(r) => navigate('dispatch/' + r.order_ref.replace('#', ''))} activeKey={sel?.order_id} defaultSort={{ col: 'due', dir: 1 }} initial={{ tab: 'ready', ...tableStateFromQuery(route) }}
          rowTone={(r) => (r.stage === 'blocked' ? 'medium' : r.days_to_due != null && r.days_to_due < 0 && r.stage !== 'shipped' ? 'critical' : '')} />
      </Panel>
      {open && (sel ? <DispatchDrawer row={sel} parcels={parcels.rows.filter((p) => p.order_id === sel.order_id)} onClose={() => navigate('dispatch')} refresh={refresh} />
        : <Drawer open onClose={() => navigate('dispatch')} title={'#' + open}><p className="muted">{q.loading ? 'Loading…' : 'This order is not in the dispatch queue. It may not be ready yet, or it may already have shipped.'}</p></Drawer>)}
      {handover && <HandoverDialog onClose={() => setHandover(false)} refresh={refresh} />}
    </div>
  );
}

function DispatchDrawer({ row, parcels, onClose, refresh }: { row: QueueRow; parcels: ParcelRow[]; onClose: () => void; refresh: () => Promise<void> }) {
  const { canAct, senior } = useCtx(); const toast = useToast();
  const active = parcels.filter((p) => p.status !== 'cancelled'); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const [n, setN] = useState('1'); const [weights, setWeights] = useState(''); const [carrier, setCarrier] = useState(''); const [service, setService] = useState(''); const [note, setNote] = useState(''); const [override, setOverride] = useState('');
  const [fmt, setFmt] = useState<PrintFormat>('thermal'); const [asking, setAsking] = useState(false); const [reason, setReason] = useState('');
  const [track, setTrack] = useState(''); const [trackCarrier, setTrackCarrier] = useState(''); const [trackParcel, setTrackParcel] = useState('all'); const [cancelling, setCancelling] = useState(false); const [cancelReason, setCancelReason] = useState('');
  const reprint = active.some((p) => p.print_count > 0); const nParcels = Number(n);
  async function act(fn: () => Promise<{ ok: boolean; error?: string; [k: string]: unknown }>, done: string) {
    setBusy(true); setErr(null); const r = await fn(); setBusy(false);
    if (!r.ok) { setErr(String(r.error ?? 'That did not work.')); return false; }
    toast.push({ tone: 'good', title: done }); await refresh(); return true;
  }
  async function pack() {
    const w = weights.split(',').map((x) => Number(x.trim())).filter((x) => x > 0);
    await act(() => dispatchPack({ order_id: row.order_id, parcels: nParcels, weights: w.length ? w : undefined, carrier: carrier.trim() || undefined, service: service.trim() || undefined, note: note.trim() || undefined, override: override.trim() || undefined }), 'Packed. Print the labels next.');
  }
  async function print() {
    setErr(null); const ok = await printParcelLabels(active, fmt);
    if (!ok) { setErr('The browser blocked the print window. Allow pop-ups for this site and try again.'); return; }
    setAsking(true);
  }
  async function confirmPrinted() { if (await act(() => dispatchPrinted(row.order_id, reason.trim() || undefined), 'Recorded as printed.')) { setAsking(false); setReason(''); } }
  const canPackNow = row.can_pack || (senior && override.trim().length >= 5);

  return (
    <Drawer open onClose={onClose} wide title={<span className="row wrap" style={{ gap: 10 }}><b className="mono">{row.order_ref}</b><Status tone={STAGE_TONE[row.stage]}>{STAGE_LABEL[row.stage]}</Status></span>} subtitle={row.customer_name ?? undefined}>
      <div className="stack" style={{ gap: 16 }}>
        {row.stage === 'blocked' && <div className="callout" role="alert"><b>Not ready to go out</b><ul style={{ margin: '6px 0 0 18px' }}>{row.blockers.map((b, i) => <li key={i}>{b}</li>)}</ul></div>}
        {row.partial && row.stage === 'ready' && <div className="callout soft" role="note"><b>Partly ready.</b> Only the {row.ready_units} checked unit(s) can go now; the rest is still with a decorator or not yet checked.</div>}
        {row.stage === 'shipped' && <div className="callout soft" role="status">DecoNetwork shows this order as shipped.</div>}
        {row.stage === 'with_courier' && !row.shipped_at && <div className="callout" role="status"><b>Everything has been handed over.</b> Mark the order as shipped in DecoNetwork with the tracking number{row.tracking ? '' : ' (add it below first)'}; ATAM_FLOW picks that up on the next sync.</div>}
        <Facts items={[['Deliver to', row.is_collection ? 'Customer collects' : <span style={{ whiteSpace: 'pre-line' }}>{addressLines(row.ship_to).join('\n') || <span className="warn">No address on the order</span>}</span>], ['Shipping method', row.shipping_method ?? '—'], ['Customer PO', row.customer_po ?? '—'],
          ['Due', row.due_date ? dateTime(row.due_date) : '—'], ['Units ready', `${row.ready_units || row.units} of ${row.units}`], ['Where it is', row.bins ?? 'No bin recorded']]} />

        {(row.stage === 'ready' || row.stage === 'blocked') && (canAct ? (
          <section className="panel stack" style={{ padding: 14, gap: 10 }} aria-label="Pack">
            <h3>Pack and make labels</h3>
            <div className="row wrap" style={{ gap: 12 }}>
              <Field label="How many parcels?"><input className="input" style={{ width: 90 }} inputMode="numeric" value={n} onChange={(e) => setN(e.target.value)} aria-label="Number of parcels" /></Field>
              <Field label="Weights in kg (optional, comma separated)"><input className="input" value={weights} onChange={(e) => setWeights(e.target.value)} placeholder="3.5, 1.2" aria-label="Weights" /></Field>
            </div>
            {!row.is_collection && <div className="row wrap" style={{ gap: 12 }}>
              <Field label="Courier (defaults to the order's method)"><input className="input" value={carrier} onChange={(e) => setCarrier(e.target.value)} placeholder={row.shipping_method ?? ''} aria-label="Courier" /></Field>
              <Field label="Service (optional)"><input className="input" value={service} onChange={(e) => setService(e.target.value)} aria-label="Service" /></Field>
            </div>}
            <Field label="Note on the label (optional)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Fragile, leave with reception" aria-label="Label note" /></Field>
            {!row.can_pack && (senior
              ? <Field label="Send it anyway: why is this fine? (required, audited)"><textarea className="textarea" rows={2} value={override} onChange={(e) => setOverride(e.target.value)} aria-label="Reason to send anyway" /></Field>
              : <p className="warn">It is blocked. A manager or admin can send it anyway with a written reason.</p>)}
            {err && <div className="callout" role="alert">{err}</div>}
            <div className="row"><Button variant="primary" disabled={busy || !(nParcels >= 1 && nParcels <= 20) || !canPackNow} onClick={() => void pack()}>{busy ? 'Packing…' : row.can_pack ? 'Pack and make labels' : 'Pack anyway'}</Button></div>
          </section>) : <p className="muted">You have view-only access.</p>)}

        {active.length > 0 && (
          <section className="stack" style={{ gap: 10 }} aria-label="Parcels">
            <h3>Parcels</h3>
            <div style={{ overflowX: 'auto' }}><table className="table" style={{ minWidth: 560 }}>
              <thead><tr><th>Label</th><th>Courier</th><th>Tracking</th><th>Printed</th><th>Status</th></tr></thead>
              <tbody>{active.map((p) => <tr key={p.id}><td><b className="mono">{p.label_code}</b><div className="dim">Parcel {p.parcel_no} of {p.parcels_total}{p.weight_kg ? ` · ${p.weight_kg} kg` : ''}</div></td><td>{p.carrier ?? '—'}{p.service ? <div className="dim">{p.service}</div> : null}</td>
                <td>{p.tracking_ref ? <span className="mono">{p.tracking_ref}</span> : <span className="warn">Not entered</span>}</td><td>{p.print_count > 0 ? `${p.print_count}×` : <span className="dim">Not yet</span>}</td>
                <td>{p.status === 'handed_over' ? <Status tone="good" plain>Handed over {p.handed_at ? dateTime(p.handed_at) : ''}</Status> : <Status tone="info" plain>Packed</Status>}{p.override_reason && <div className="dim" title={p.override_reason}>Sent anyway: {p.override_reason}</div>}</td></tr>)}</tbody></table></div>
            {canAct && row.stage !== 'shipped' && <>
              <div className="row wrap" style={{ gap: 8 }}>
                <select className="select" style={{ width: 'auto' }} value={fmt} onChange={(e) => setFmt(e.target.value as PrintFormat)} aria-label="Paper"><option value="thermal">Thermal 100 × 150 mm</option><option value="A4">A4 sheet</option></select>
                <Button variant="primary" icon="labels" disabled={busy} onClick={() => void print()}>{reprint ? 'Print the labels again' : 'Print labels'}</Button>
              </div>
              {asking && <div className="callout" role="status"><b>Did the labels print?</b>
                {reprint && <Field label="They were printed before. Why again? (required)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Reprint reason" /></Field>}
                <div className="row" style={{ marginTop: 8 }}><Button variant="good" disabled={busy || (reprint && reason.trim().length < 5)} onClick={() => void confirmPrinted()}>Yes, they printed</Button><Button variant="ghost" onClick={() => setAsking(false)}>No, it failed</Button></div></div>}
              <div className="panel stack" style={{ padding: 12, gap: 8 }} aria-label="Tracking">
                <h3>Courier tracking</h3>
                <p className="dim">Book the courier in their own system, then type the tracking number here.</p>
                <div className="row wrap" style={{ gap: 10 }}>
                  <Field label="Tracking reference"><input className="input" value={track} onChange={(e) => setTrack(e.target.value)} aria-label="Tracking reference" /></Field>
                  <Field label="Courier (optional)"><input className="input" value={trackCarrier} onChange={(e) => setTrackCarrier(e.target.value)} aria-label="Tracking courier" /></Field>
                  {active.length > 1 && <Field label="For"><select className="select" value={trackParcel} onChange={(e) => setTrackParcel(e.target.value)} aria-label="Tracking for"><option value="all">Every parcel</option>{active.map((p) => <option key={p.id} value={p.parcel_no}>Parcel {p.parcel_no}</option>)}</select></Field>}
                </div>
                <div className="row"><Button disabled={busy || track.trim().length < 3} onClick={() => void act(() => dispatchTracking(row.order_id, track.trim(), trackCarrier.trim() || undefined, trackParcel === 'all' ? null : Number(trackParcel)), 'Tracking saved.').then((ok) => { if (ok) setTrack(''); })}>Save tracking</Button></div>
              </div>
              {active.some((p) => p.status === 'packed') && <>
                <div className="row wrap">{active.filter((p) => p.status === 'packed').map((p) => <Button key={p.id} disabled={busy} onClick={() => void act(() => dispatchHandover(p.label_code, senior && override.trim().length >= 5 ? override.trim() : undefined), `Parcel ${p.parcel_no} handed to the courier.`)}>Mark parcel {p.parcel_no} handed over</Button>)}</div>
                {!cancelling ? <Button variant="ghost" onClick={() => setCancelling(true)}>Cancel the packing</Button>
                  : <div className="panel stack" style={{ padding: 12, gap: 8 }}><Field label="Why? The printed labels become void. (required)"><input className="input" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} aria-label="Cancel reason" /></Field>
                    <div className="row"><Button variant="danger" disabled={busy || cancelReason.trim().length < 5} onClick={() => void act(() => dispatchCancel(row.order_id, cancelReason.trim()), 'Packing cancelled. Throw away the old labels.').then((ok) => { if (ok) { setCancelling(false); setCancelReason(''); } })}>Cancel packing</Button><Button variant="ghost" onClick={() => setCancelling(false)}>Keep it</Button></div></div>}
              </>}
              {err && <div className="callout" role="alert">{err}</div>}
            </>}
          </section>)}
      </div>
    </Drawer>
  );
}

interface Result { id: number; tone: 'good' | 'bad'; text: string; needsOverride?: string }
// Scan each parcel as it goes to the courier. Each scan records the hand-over (audited); the window stays open for the next one.
function HandoverDialog({ onClose, refresh }: { onClose: () => void; refresh: () => Promise<void> }) {
  const { senior } = useCtx(); const [log, setLog] = useState<Result[]>([]); const [busy, setBusy] = useState(false); const [pending, setPending] = useState<{ label: string; text: string } | null>(null); const [reason, setReason] = useState('');
  const push = (r: Omit<Result, 'id'>) => setLog((l) => [{ ...r, id: Date.now() + Math.random() }, ...l].slice(0, 8));
  async function handle(label: string, override?: string) {
    setBusy(true); const r = await dispatchHandover(label, override); setBusy(false);
    if (r.ok) {
      const t = `${r.order_ref} · ${r.customer_name ?? ''} · parcel ${r.parcel_no} of ${r.parcels_total}`;
      push({ tone: 'good', text: r.already ? `Already handed over: ${t}` : r.all_handed ? `Handed over: ${t}. That is the last parcel for this order.${r.tracking_missing ? ' Tracking has not been entered yet.' : ''}` : `Handed over: ${t} (${r.parcels_left} left)` });
      setPending(null); setReason(''); await refresh();
    } else if (r.needs_override) { setPending({ label, text: String(r.error) }); push({ tone: 'bad', text: String(r.error) }); }
    else push({ tone: 'bad', text: String(r.error ?? 'That did not work.') });
  }
  function scanned(text: string) {
    const p = parseScan(text);
    if (p.kind !== 'parcel') { push({ tone: 'bad', text: 'That is not a parcel label from the Dispatch page. Scan the barcode on the courier label.' }); return; }
    setPending(null); void handle(p.ref);
  }
  return (
    <Modal open onClose={onClose} title="Hand parcels to the courier">
      <div className="stack" style={{ gap: 12 }}>
        <ScanPanel hint="Scan each parcel's label as it goes to the courier. Each scan is recorded." onScan={scanned} onClose={onClose} />
        {busy && <p className="dim" role="status">Recording…</p>}
        {pending && <div className="callout" role="alert">{senior
          ? <><b>Send it anyway?</b><Field label="Why is it fine to go? (required, audited)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Hand-over override reason" /></Field><div className="row" style={{ marginTop: 8 }}><Button variant="primary" disabled={busy || reason.trim().length < 5} onClick={() => void handle(pending.label, reason.trim())}>Hand over anyway</Button><Button variant="ghost" onClick={() => setPending(null)}>Hold it</Button></div></>
          : <>Ask a manager or admin: they can hand it over with a written reason.</>}</div>}
        <ul className="plain" aria-label="Scan results" style={{ display: 'grid', gap: 6 }}>{log.map((l) => <li key={l.id} className={l.tone === 'bad' ? 'bad' : 'good'}>{l.tone === 'good' ? '✓ ' : '✕ '}{l.text}</li>)}</ul>
      </div>
    </Modal>
  );
}
