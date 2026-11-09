import { useMemo, useState, type FormEvent, type ReactNode } from 'react';
import { Button, EmptyState, Facts, Field, Kpi, Panel, Status } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { ScanPanel } from '../scan/ScanPanel';
import { parseScan } from '../scan/parse';
import { navigate, type Route } from '../router';
import { dateTime, gbp } from '../lib/format';
import { LINE_LABEL, LINE_TONE, parseSkuList, stocktakeAccept, stocktakeAcceptSmall, stocktakeAdjusted, stocktakeCancel, stocktakeClose, stocktakeCount, stocktakeRecount, stocktakeReview, stocktakeStart, TAKE_LABEL, TAKE_TONE, type Scope, type StockTakeLine, type StockTakeRow } from '../lib/stocktake';
import type { ActionResult } from '../types';

const Err = ({ m }: { m: string | null }) => (m ? <div className="callout" role="alert">{m}</div> : null);
function Dialog({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) { return <Modal open onClose={onClose} title={title}><div className="stack" style={{ gap: 12 }}>{children}</div></Modal>; }
const variant = (l: { colour: string | null; size: string | null }) => [l.colour, l.size].filter(Boolean).join(' · ');
const signed = (n: number | null) => (n == null ? '—' : n > 0 ? `+${n}` : String(n));

export function StockTakesPage({ route }: { route: Route }) {
  const takes = useView<StockTakeRow>('ui_stock_takes'); const { canAct } = useCtx(); const [creating, setCreating] = useState(false);
  const open = route.path[1]; const sel = open ? takes.rows.find((t) => t.take_ref === open) : null;
  const n = (s: StockTakeRow['status']) => takes.rows.filter((t) => t.status === s).length;
  const views: ViewDef<StockTakeRow>[] = [
    { id: 'open', label: 'Open', test: (t) => t.status === 'counting' || t.status === 'review' }, { id: 'fix', label: 'Needs correcting in DecoNetwork', test: (t) => t.needs_correction },
    { id: 'closed', label: 'Closed', test: (t) => t.status === 'closed' }, { id: 'cancelled', label: 'Cancelled', test: (t) => t.status === 'cancelled' }, { id: 'all', label: 'All', test: () => true }
  ];
  const cols: Column<StockTakeRow>[] = [
    { id: 'ref', header: 'Stock-take', width: '120px', render: (t) => <b className="mono">{t.take_ref}</b>, sort: (t) => t.take_ref, csv: (t) => t.take_ref },
    { id: 'name', header: 'Name', width: '230px', render: (t) => t.name, sort: (t) => t.name.toLowerCase(), csv: (t) => t.name },
    { id: 'scope', header: 'What is counted', width: '260px', render: (t) => <span className="muted">{t.scope_detail}</span>, csv: (t) => t.scope_detail },
    { id: 'st', header: 'Status', width: '190px', render: (t) => <span className="row" style={{ gap: 6 }}><Status tone={TAKE_TONE[t.status]}>{TAKE_LABEL[t.status]}</Status>{t.needs_correction && <Status tone="high" plain>Not corrected yet</Status>}</span>, sort: (t) => t.status, csv: (t) => t.status },
    { id: 'prog', header: 'Counted', width: '110px', align: 'r', render: (t) => <span className="num">{t.counted_lines}/{t.lines}</span>, sort: (t) => t.counted_lines, csv: (t) => `${t.counted_lines}/${t.lines}` },
    { id: 'net', header: 'Net difference', width: '130px', align: 'r', render: (t) => (t.net_value == null ? <span className="dim">hidden while counting</span> : <span className={`num ${t.net_value < 0 ? 'bad' : ''}`}>{gbp(t.net_value)}</span>), sort: (t) => t.net_value, csv: (t) => t.net_value },
    { id: 'by', header: 'Started by', width: '170px', render: (t) => <span className="dim">{t.created_by.replace('dashboard:', '')} · {dateTime(t.created_at)}</span>, sort: (t) => t.created_at, csv: (t) => t.created_at }
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Stock-takes</h1><p>Count what is really on the shelves and compare it with the system. A stock-take never changes stock: it records the differences, suggests the losses, and reminds you to correct DecoNetwork.</p></div>
        <div className="row"><Button variant="primary" icon="plus" disabled={!canAct} title={canAct ? undefined : 'Your role cannot start a stock-take'} onClick={() => setCreating(true)}>New stock-take</Button></div></div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 12 }}>
        <Kpi label="Being counted" value={n('counting')} tone={n('counting') ? 'info' : ''} /><Kpi label="In review" value={n('review')} tone={n('review') ? 'medium' : ''} /><Kpi label="Waiting to be corrected" value={takes.rows.filter((t) => t.needs_correction).length} tone={takes.rows.some((t) => t.needs_correction) ? 'high' : ''} /><Kpi label="Closed" value={n('closed')} />
      </div>
      <Panel flush><DataTable<StockTakeRow> rows={takes.rows} columns={cols} rowKey={(t) => t.id} loading={takes.loading} error={takes.error} onRetry={() => void takes.refresh()} views={views} storageKey="stocktakes" exportName="stock-takes"
        searchText={(t) => [t.take_ref, t.name, t.scope_detail, t.created_by].join(' ')} onRowClick={(t) => navigate('stocktake/' + t.take_ref)} activeKey={sel?.id} defaultSort={{ col: 'by', dir: -1 }}
        empty={<EmptyState icon="stock" title="No stock-takes yet">Start one to count a shelf, your most valuable items, or everything.</EmptyState>} /></Panel>
      {open && (sel ? <TakeDrawer take={sel} onClose={() => navigate('stocktake')} refresh={() => takes.refresh()} /> : <Drawer open onClose={() => navigate('stocktake')} title={open}><p className="muted">{takes.loading ? 'Loading…' : 'Stock-take not found.'}</p></Drawer>)}
      {creating && <NewTakeDialog onClose={() => setCreating(false)} onCreated={async (ref) => { setCreating(false); await takes.refresh(); navigate('stocktake/' + ref); }} />}
    </div>
  );
}

function NewTakeDialog({ onClose, onCreated }: { onClose: () => void; onCreated: (ref: string) => Promise<void> }) {
  const [name, setName] = useState(''); const [kind, setKind] = useState<Scope['kind']>('location'); const [loc, setLoc] = useState(''); const [skus, setSkus] = useState(''); const [top, setTop] = useState('50');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  const scope: Scope = kind === 'all' ? { kind } : kind === 'location' ? { kind, location: loc.trim() } : kind === 'skus' ? { kind, skus: parseSkuList(skus) } : { kind, top: Number(top) || 50 };
  const ok = name.trim().length >= 3 && (kind === 'all' || (kind === 'location' && loc.trim().length > 0) || (kind === 'skus' && parseSkuList(skus).length > 0) || (kind === 'high_value' && Number(top) >= 1));
  async function submit(e: FormEvent) {
    e.preventDefault(); if (!ok) return; setBusy(true); setErr(null); const r = await stocktakeStart(name.trim(), scope); setBusy(false);
    if (!r.ok) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: `${r.take_ref}: ${r.lines} item(s) to count`, body: [r.skipped_in_other_take ? `${r.skipped_in_other_take} left out (already in another stock-take)` : '', Array.isArray(r.unknown_skus) && r.unknown_skus.length ? `Not found: ${(r.unknown_skus as string[]).join(', ')}` : ''].filter(Boolean).join('. ') || undefined });
    await onCreated(String(r.take_ref));
  }
  return (
    <Dialog title="New stock-take" onClose={onClose}>
      <form className="stack" style={{ gap: 10 }} onSubmit={submit}>
        <Field label="Name"><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. November shelf A count" aria-label="Stock-take name" /></Field>
        <Field label="What do you want to count?"><select className="select" value={kind} onChange={(e) => setKind(e.target.value as Scope['kind'])} aria-label="What to count">
          <option value="location">A shelf or area</option><option value="high_value">The most valuable items</option><option value="skus">Particular SKUs</option><option value="all">Everything with stock</option></select></Field>
        {kind === 'location' && <Field label="Shelf or area (starts with)"><input className="input" value={loc} onChange={(e) => setLoc(e.target.value)} placeholder="e.g. A3" aria-label="Shelf or area" /></Field>}
        {kind === 'high_value' && <Field label="How many items (the most valuable first)"><input className="input" style={{ width: 120 }} inputMode="numeric" value={top} onChange={(e) => setTop(e.target.value)} aria-label="How many items" /></Field>}
        {kind === 'skus' && <Field label="SKUs (separate with commas, spaces or new lines)"><textarea className="textarea" rows={3} value={skus} onChange={(e) => setSkus(e.target.value)} aria-label="SKUs" /></Field>}
        <p className="dim">The counter will not see how many the system expects. An item can only be in one open stock-take at a time.</p>
        <Err m={err} />
        <div className="row"><Button variant="primary" disabled={busy || !ok}>{busy ? 'Starting…' : 'Start counting'}</Button><Button type="button" variant="ghost" onClick={onClose}>Cancel</Button></div>
      </form>
    </Dialog>
  );
}

type Dlg = null | { kind: 'recount'; line: StockTakeLine } | { kind: 'accept'; line: StockTakeLine } | { kind: 'small' } | { kind: 'close' } | { kind: 'cancel' } | { kind: 'review' } | { kind: 'adjusted' };

function TakeDrawer({ take, onClose, refresh }: { take: StockTakeRow; onClose: () => void; refresh: () => Promise<void> }) {
  const { canAct, senior } = useCtx(); const toast = useToast(); const allLines = useView<StockTakeLine>('ui_stock_take_lines');
  const lines = useMemo(() => allLines.rows.filter((l) => l.take_id === take.id), [allLines.rows, take.id]); const [dlg, setDlg] = useState<Dlg>(null);
  const reload = async () => { await Promise.all([refresh(), allLines.refresh()]); };
  const done = async (msg: string) => { toast.push({ tone: 'good', title: msg }); setDlg(null); await reload(); };
  const counting = take.status === 'counting', review = take.status === 'review';
  const cnt = (s: string) => lines.filter((l) => l.status === s).length;
  const needsAction = lines.filter((l) => ['counted', 'recounted', 'recount_needed'].includes(l.status));

  const baseCols: Column<StockTakeLine>[] = [
    { id: 'sku', header: 'SKU', width: '190px', render: (l) => <span><b className="mono">{l.sku}</b>{l.added_in_count && <Status tone="info" plain> found, not on the list</Status>}</span>, sort: (l) => l.sku, csv: (l) => l.sku },
    { id: 'p', header: 'Item', width: '210px', render: (l) => <span>{l.product_name ?? '—'}<span className="dim"> {variant(l)}</span></span>, csv: (l) => `${l.product_name ?? ''} ${variant(l)}` },
    { id: 'loc', header: 'Shelf', width: '100px', render: (l) => <span className="mono dim">{l.location ?? '—'}</span>, sort: (l) => l.location, csv: (l) => l.location }
  ];
  const countingCols: Column<StockTakeLine>[] = [...baseCols,
    { id: 'st', header: 'Status', width: '110px', render: (l) => <Status tone={l.counted_qty == null ? '' : 'info'} plain>{l.counted_qty == null ? 'To count' : 'Counted'}</Status>, sort: (l) => (l.counted_qty == null ? 0 : 1), csv: (l) => l.status },
    { id: 'cq', header: 'You counted', width: '110px', align: 'r', render: (l) => (l.counted_qty == null ? '—' : <span className="num">{l.counted_qty}</span>), sort: (l) => l.counted_qty, csv: (l) => l.counted_qty },
    { id: 'by', header: 'By', width: '130px', render: (l) => <span className="dim">{l.counted_by?.replace('dashboard:', '') ?? ''}</span>, csv: (l) => l.counted_by }
  ];
  const reviewCols: Column<StockTakeLine>[] = [...baseCols,
    { id: 'exp', header: 'System said', width: '100px', align: 'r', render: (l) => <span className="num">{l.expected_qty ?? '—'}</span>, sort: (l) => l.expected_qty, csv: (l) => l.expected_qty },
    { id: 'cq', header: 'Counted', width: '90px', align: 'r', render: (l) => <span className="num">{l.counted_qty ?? '—'}</span>, sort: (l) => l.counted_qty, csv: (l) => l.counted_qty },
    { id: 'rq', header: 'Recount', width: '90px', align: 'r', render: (l) => <span className="num">{l.recount_qty ?? '—'}</span>, csv: (l) => l.recount_qty },
    { id: 'var', header: 'Difference', width: '100px', align: 'r', render: (l) => <span className={`num ${l.variance ? (l.variance < 0 ? 'bad' : 'warn') : ''}`}>{signed(l.variance)}</span>, sort: (l) => l.variance, csv: (l) => l.variance },
    { id: 'val', header: 'Value', width: '100px', align: 'r', render: (l) => <span className="num">{l.variance_value == null ? '—' : gbp(l.variance_value)}</span>, sort: (l) => (l.variance_value == null ? null : Math.abs(l.variance_value)), csv: (l) => l.variance_value },
    { id: 'st', header: 'Status', width: '150px', render: (l) => <Status tone={LINE_TONE[l.status]}>{LINE_LABEL[l.status]}</Status>, sort: (l) => l.status, csv: (l) => l.status },
    { id: 'why', header: 'Reason accepted', width: '240px', render: (l) => <span className="muted" title={l.accept_reason ?? ''}>{l.accept_reason ?? ''}</span>, csv: (l) => l.accept_reason },
    { id: 'act', header: '', width: '190px', render: (l) => (review && canAct && ['counted', 'recounted', 'recount_needed'].includes(l.status))
        ? <span className="row" style={{ gap: 6 }}><Button size="sm" onClick={() => setDlg({ kind: 'recount', line: l })}>Recount</Button><Button size="sm" variant="primary" disabled={l.status === 'recount_needed' && !senior} title={l.status === 'recount_needed' && !senior ? 'This needs a recount by someone else first' : undefined} onClick={() => setDlg({ kind: 'accept', line: l })}>Accept</Button></span> : null }
  ];
  const countingViews: ViewDef<StockTakeLine>[] = [{ id: 'todo', label: 'To count', test: (l) => l.counted_qty == null }, { id: 'done', label: 'Counted', test: (l) => l.counted_qty != null }, { id: 'all', label: 'All', test: () => true }];
  const reviewViews: ViewDef<StockTakeLine>[] = [{ id: 'act', label: 'Needs a decision', test: (l) => ['counted', 'recounted', 'recount_needed'].includes(l.status) }, { id: 'ok', label: 'Matches', test: (l) => l.status === 'matched' },
    { id: 'acc', label: 'Accepted differences', test: (l) => l.status === 'accepted' }, { id: 'nc', label: 'Not counted', test: (l) => l.status === 'to_count' }, { id: 'all', label: 'All', test: () => true }];

  return (
    <Drawer open onClose={onClose} wide title={<span className="row wrap" style={{ gap: 10 }}><b className="mono">{take.take_ref}</b><Status tone={TAKE_TONE[take.status]}>{TAKE_LABEL[take.status]}</Status></span>} subtitle={take.name}>
      <div className="stack" style={{ gap: 16 }}>
        <Facts items={[['What is counted', take.scope_detail ?? '—'], ['Started', `${take.created_by.replace('dashboard:', '')} · ${dateTime(take.created_at)}`], ['Progress', `${take.counted_lines} of ${take.lines} counted`],
          ...(take.review_at ? [['Counting finished', dateTime(take.review_at)] as [string, ReactNode]] : []), ...(take.closed_at ? [['Closed', `${take.closed_by?.replace('dashboard:', '')} · ${dateTime(take.closed_at)}${take.close_note ? ' · ' + take.close_note : ''}`] as [string, ReactNode]] : []),
          ...(take.cancelled_at ? [['Cancelled', `${take.cancel_reason}`] as [string, ReactNode]] : []), ...(take.dn_adjusted_at ? [['Corrected in DecoNetwork', `${take.dn_adjusted_by?.replace('dashboard:', '')} · ${dateTime(take.dn_adjusted_at)}`] as [string, ReactNode]] : [])]} />

        {counting && <>
          <CountEntry take={take} lines={lines} onSaved={reload} />
          <div className="row wrap" style={{ gap: 8 }}>{canAct && <Button variant="primary" onClick={() => setDlg({ kind: 'review' })}>Finish counting…</Button>}{senior && <Button variant="ghost" onClick={() => setDlg({ kind: 'cancel' })}>Cancel this stock-take…</Button>}</div>
          <Panel flush><DataTable<StockTakeLine> rows={lines} columns={countingCols} rowKey={(l) => l.id} loading={allLines.loading} error={allLines.error} views={countingViews} storageKey={'st-count-' + take.id} exportName={take.take_ref + '-count'} searchText={(l) => [l.sku, l.product_name, l.location].join(' ')} searchPlaceholder="Search SKU, item, shelf…" defaultSort={{ col: 'sku', dir: 1 }} /></Panel>
        </>}

        {(review || take.status === 'closed') && <>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(130px, 1fr))', gap: 10 }}>
            <Kpi label="Match" value={cnt('matched')} tone="good" /><Kpi label="Need a recount" value={cnt('recount_needed')} tone={cnt('recount_needed') ? 'high' : ''} /><Kpi label="Waiting for a decision" value={cnt('counted') + cnt('recounted')} tone={cnt('counted') + cnt('recounted') ? 'medium' : ''} />
            <Kpi label="Not counted" value={cnt('to_count')} /><Kpi label="Net difference" text={take.net_value == null ? '—' : gbp(take.net_value)} sub={take.net_units == null ? undefined : `${signed(take.net_units)} units`} tone={take.net_value != null && take.net_value < 0 ? 'high' : ''} />
          </div>
          {review && <div className="row wrap" style={{ gap: 8 }}>
            {canAct && <Button onClick={() => setDlg({ kind: 'small' })} disabled={cnt('counted') + cnt('recounted') === 0}>Accept the small differences…</Button>}
            {senior ? <Button variant="primary" disabled={needsAction.length > 0} title={needsAction.length ? `${needsAction.length} difference(s) still need a recount or a decision` : undefined} onClick={() => setDlg({ kind: 'close' })}>Close the stock-take…</Button> : <span className="dim">A manager or admin closes the stock-take.</span>}
            {senior && <Button variant="ghost" onClick={() => setDlg({ kind: 'cancel' })}>Cancel…</Button>}</div>}
          {take.status === 'closed' && <div className="callout" role="note">{take.dn_adjusted_at ? 'The corrections have been made in DecoNetwork.' : <>This stock-take changed nothing in the system. <b>Put the accepted differences right in DecoNetwork</b> (use the Accepted differences list, which can be downloaded), then mark it as corrected. Accepted shortfalls are on the Waste page as suggestions to confirm.</>}
            {take.needs_correction && canAct && <div style={{ marginTop: 8 }}><Button variant="primary" onClick={() => setDlg({ kind: 'adjusted' })}>Mark as corrected in DecoNetwork…</Button></div>}</div>}
          <Panel flush><DataTable<StockTakeLine> rows={lines} columns={reviewCols} rowKey={(l) => l.id} loading={allLines.loading} error={allLines.error} views={reviewViews} initial={{ tab: take.status === 'closed' ? 'acc' : 'act' }} storageKey={'st-review-' + take.id} exportName={take.take_ref + '-results'}
            searchText={(l) => [l.sku, l.product_name, l.location, l.accept_reason].join(' ')} searchPlaceholder="Search SKU, item, shelf…" defaultSort={{ col: 'val', dir: -1 }} /></Panel>
        </>}
      </div>

      {dlg?.kind === 'review' && <ConfirmDialog title="Finish counting" body={`${lines.filter((l) => l.counted_qty == null).length} item(s) have not been counted and will be left out. Once you finish, the expected quantities are shown and counting stops.`} button="Finish counting" run={() => stocktakeReview(take.id)} ok="Counting finished. Review the differences." onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'recount' && <RecountDialog take={take} line={dlg.line} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'accept' && <ReasonDialog title={`Accept the difference on ${dlg.line.sku}`} intro={`The system said ${dlg.line.expected_qty}, the count was ${dlg.line.final_qty} (${signed(dlg.line.variance)}, worth ${gbp(Math.abs(dlg.line.variance_value ?? 0))}).`} label="Why is this difference accepted? (required)" button="Accept"
        run={(r) => stocktakeAccept(dlg.line.id, r)} ok="Difference accepted." onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'small' && <ReasonDialog title="Accept the small differences" intro="Every counted difference that did not need a recount, and is under the manager limit, is accepted with this one reason." label="Reason (required)" button="Accept them" run={(r) => stocktakeAcceptSmall(take.id, r)} ok="Small differences accepted." onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'close' && <ReasonDialog title={`Close ${take.take_ref}`} intro="Closing records the result. Accepted shortfalls become suggested waste records. Nothing in stock is changed." label="Note (optional)" optional button="Close the stock-take" run={(r) => stocktakeClose(take.id, r || undefined)} ok="Stock-take closed." onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'cancel' && <ReasonDialog title={`Cancel ${take.take_ref}`} intro="The counts so far are kept for the record but the stock-take is abandoned." label="Why? (required)" button="Cancel the stock-take" danger run={(r) => stocktakeCancel(take.id, r)} ok="Stock-take cancelled." onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'adjusted' && <ReasonDialog title="Corrected in DecoNetwork" intro="Confirm the accepted differences have been put right in DecoNetwork." label="Note (optional)" optional button="Mark as corrected" run={(r) => stocktakeAdjusted(take.id, r || undefined)} ok="Marked as corrected." onClose={() => setDlg(null)} onDone={done} />}
    </Drawer>
  );
}

// Blind count entry: scan or type the SKU, then the quantity. The expected quantity is never shown here.
function CountEntry({ take, lines, onSaved }: { take: StockTakeRow; lines: StockTakeLine[]; onSaved: () => Promise<void> }) {
  const stock = useView<{ sku: string; product_name: string | null; colour: string | null; size: string | null; storage_location: string | null }>('ui_stock'); const toast = useToast(); const { canAct } = useCtx();
  const known = useMemo(() => ({ skus: new Set(stock.rows.map((s) => s.sku)) }), [stock.rows]);
  const [cur, setCur] = useState<{ sku: string; name: string; location: string | null; existing: number | null; outside: boolean } | null>(null); const [qty, setQty] = useState(''); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false); const [key, setKey] = useState(0); const [last, setLast] = useState<string | null>(null);
  if (!canAct) return <p className="muted">You can look at this stock-take. Counting is for warehouse, production, manager and admin roles.</p>;
  function scanned(text: string) {
    setErr(null); const p = parseScan(text, known); const want = (p.kind === 'sku' ? p.ref : text.trim()).toUpperCase();
    const line = lines.find((l) => l.sku.toUpperCase() === want); const item = line ?? stock.rows.find((s) => s.sku.toUpperCase() === want);
    if (!item) { setErr(`"${text.trim().slice(0, 60)}" is not in the stock list. Check the code on the shelf label.`); setKey((k) => k + 1); return; }
    setCur({ sku: item.sku, name: `${item.product_name ?? item.sku} ${variant(item)}`.trim(), location: line ? line.location : (item as { storage_location: string | null }).storage_location, existing: line?.counted_qty ?? null, outside: !line }); setQty('');
  }
  async function save(e: FormEvent) {
    e.preventDefault(); if (!cur) return; const n = Number(qty);
    if (qty.trim() === '' || !Number.isInteger(n) || n < 0) { setErr('Enter a whole number, 0 or more.'); return; }
    setBusy(true); setErr(null); const r: ActionResult = await stocktakeCount(take.id, cur.sku, n); setBusy(false);
    if (!r.ok) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: `${cur.sku}: ${n} counted` }); setLast(`${cur.sku}: ${n}`); setCur(null); setKey((k) => k + 1); await onSaved();
  }
  return (
    <section className="panel stack" style={{ padding: 14, gap: 10 }} aria-label="Count">
      <h3>Count</h3>
      {!cur ? <ScanPanel key={key} hint="Scan the shelf label or type the SKU, then enter how many you can see. You will not be shown how many the system expects." onScan={scanned} onClose={() => setErr(null)} />
        : <form className="stack" style={{ gap: 10 }} onSubmit={save}>
          <div><b className="mono">{cur.sku}</b> <span className="muted">{cur.name}</span>{cur.location && <span className="dim"> · shelf {cur.location}</span>}</div>
          {cur.outside && <p className="warn">This item is not on the list for this stock-take. Counting it adds it.</p>}
          {cur.existing != null && <p className="warn">Already counted as {cur.existing}. Saving replaces that count (both are kept in the log).</p>}
          <Field label="How many did you count?"><input className="input" style={{ width: 160 }} autoFocus inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value)} aria-label="Quantity counted" /></Field>
          <div className="row"><Button variant="primary" disabled={busy || qty.trim() === ''}>{busy ? 'Saving…' : 'Save count'}</Button><Button type="button" variant="ghost" onClick={() => { setCur(null); setErr(null); setKey((k) => k + 1); }}>Back</Button></div>
        </form>}
      <Err m={err} />
      {last && <p className="dim" role="status">Last saved: {last}</p>}
    </section>
  );
}

function useDo(onDone: (m: string) => Promise<void>) {
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function go(fn: () => Promise<ActionResult>, ok: string) { setBusy(true); setErr(null); const r = await fn(); setBusy(false); if (!r.ok) { setErr(String(r.error ?? 'That did not work.')); return; } await onDone(ok); }
  return { busy, err, go };
}
function ConfirmDialog({ title, body, button, run, ok, onClose, onDone }: { title: string; body: string; button: string; run: () => Promise<ActionResult>; ok: string; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const { busy, err, go } = useDo(onDone);
  return <Dialog title={title} onClose={onClose}><p className="muted">{body}</p><Err m={err} /><div className="row"><Button variant="primary" disabled={busy} onClick={() => void go(run, ok)}>{busy ? 'Saving…' : button}</Button><Button variant="ghost" onClick={onClose}>Back</Button></div></Dialog>;
}
function ReasonDialog({ title, intro, label, button, run, ok, onClose, onDone, optional, danger }: { title: string; intro: string; label: string; button: string; run: (reason: string) => Promise<ActionResult>; ok: string; onClose: () => void; onDone: (m: string) => Promise<void>; optional?: boolean; danger?: boolean }) {
  const [reason, setReason] = useState(''); const { busy, err, go } = useDo(onDone);
  return (
    <Dialog title={title} onClose={onClose}><p className="muted">{intro}</p><Field label={label}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Reason" /></Field><Err m={err} />
      <div className="row"><Button variant={danger ? 'danger' : 'primary'} disabled={busy || (!optional && reason.trim().length < 5)} onClick={() => void go(() => run(reason.trim()), ok)}>{busy ? 'Saving…' : button}</Button><Button variant="ghost" onClick={onClose}>Back</Button></div></Dialog>
  );
}
function RecountDialog({ take, line, onClose, onDone }: { take: StockTakeRow; line: StockTakeLine; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [qty, setQty] = useState(''); const { busy, err, go } = useDo(onDone);
  return (
    <Dialog title={`Recount ${line.sku}`} onClose={onClose}>
      <p className="muted">Count it again without looking at the first count. A recount has to be done by a different person from the one who counted it.</p>
      <Field label="How many did you count?"><input className="input" style={{ width: 160 }} autoFocus inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value)} aria-label="Recount quantity" /></Field><Err m={err} />
      <div className="row"><Button variant="primary" disabled={busy || qty.trim() === '' || !Number.isInteger(Number(qty)) || Number(qty) < 0} onClick={() => void go(() => stocktakeRecount(take.id, line.sku, Number(qty)), 'Recount saved.')}>{busy ? 'Saving…' : 'Save recount'}</Button><Button variant="ghost" onClick={onClose}>Back</Button></div>
    </Dialog>
  );
}
