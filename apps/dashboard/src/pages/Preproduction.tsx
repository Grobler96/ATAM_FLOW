import { useState } from 'react';
import { Button, Panel, EmptyState, Status, Tabs } from '../ui/primitives';
import { useCtx } from '../data/context';
import { BuildDtfDialog, ReceiveDtfDialog } from '../components/DtfDialogs';
import { batchTone, batchWords, canBuildRole, canReceiveRole, type DtfBatchRow } from '../lib/dtfOrders';
import { DataTable, type BulkAction, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { shortDate } from '../lib/domain';
import { LightPill } from '../components/PreproLights';
import { artworkTotals, dtfStatusWords, fileWords, isReady, lightScore, lightsText, ordersWithDtf, preprodCounts, STATUS_LIGHT, LIGHT_TONE, type DtfItemRow, type DtfOrderRow, type PreprodRow } from '../lib/preproduction';
import { scopeLabel } from '../lib/orderRules';

// Pre-production: the three things that happen at the same time before an order can go into production (the DTF prints, the embroidery check and the
// stock) and the traffic light for each. Read-only for now: it shows where every order stands; ordering or producing DTFs from here comes next.
const orderPath = (ref: string) => 'orders/' + ref.replace('#', '');

export function PreproductionPage({ route }: { route: Route }) {
  const tab = route.path[1] === 'dtf' ? 'dtf' : 'orders';
  const prep = useView<PreprodRow>('ui_preproduction'), dtf = useView<DtfItemRow>('ui_dtf_items'), batches = useView<DtfBatchRow>('ui_dtf_batches'); const c = preprodCounts(prep.rows); const withDtf = ordersWithDtf(dtf.rows);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Pre-production</h1>
        <p>{c.total === 0 ? 'No active orders yet.' : `${c.total} active orders · ${c.ready} ready for production · ${c.prints} need prints · ${c.embroidery} need embroidery checked · ${c.stock} need stock`}</p></div></div>
      <Tabs label="Pre-production sections" value={tab} tabs={[{ id: 'orders', label: 'Orders', count: prep.rows.length }, { id: 'dtf', label: 'DTF prints', count: withDtf.length }]} onChange={(t) => navigate(t === 'dtf' ? 'preprod/dtf' : 'preprod')} />
      {tab === 'orders' ? <OrdersTab prep={prep} route={route} /> : <DtfTab dtf={dtf} orders={withDtf} batches={batches} route={route} />}
    </div>
  );
}

function OrdersTab({ prep, route }: { prep: ReturnType<typeof useView<PreprodRow>>; route: Route }) {
  const views: ViewDef<PreprodRow>[] = [
    { id: 'notready', label: 'Not ready', test: (r) => !isReady(r) }, { id: 'ready', label: 'Ready for production', test: isReady }, { id: 'prints', label: 'Prints needed', test: (r) => r.prints === 'red' || r.prints === 'amber' },
    { id: 'emb', label: 'Embroidery to check', test: (r) => r.embroidery === 'red' || r.embroidery === 'amber' }, { id: 'stock', label: 'Stock to buy', test: (r) => r.stock === 'red' || r.stock === 'amber' }, { id: 'all', label: 'All', test: () => true }
  ];
  const filters: FilterDef<PreprodRow>[] = [{ id: 'scope', label: 'Where', options: [{ value: 'third_party', label: 'Third party' }, { value: 'in_house', label: 'In house' }, { value: 'unclassified', label: 'Not decided' }], test: (r, v) => r.scope === v }];
  const cols: Column<PreprodRow>[] = [
    { id: 'order', header: 'Order', width: '110px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '190px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '110px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'where', header: 'Where', width: '120px', render: (r) => scopeLabel(r.scope), sort: (r) => r.scope, csv: (r) => scopeLabel(r.scope), hide: 'mobile' },
    { id: 'prints', header: 'Prints', width: '190px', render: (r) => <LightPill kind="prints" light={r.prints} />, sort: (r) => r.prints, csv: (r) => r.prints },
    { id: 'emb', header: 'Embroidery', width: '210px', render: (r) => <LightPill kind="embroidery" light={r.embroidery} />, sort: (r) => r.embroidery, csv: (r) => r.embroidery },
    { id: 'stock', header: 'Stock', width: '190px', render: (r) => <LightPill kind="stock" light={r.stock} />, sort: (r) => r.stock, csv: (r) => r.stock },
    { id: 'ready', header: 'Ready?', width: '110px', render: (r) => (isReady(r) ? <Status tone="good">✓ Ready</Status> : <span className="dim">Not yet</span>), sort: (r) => lightScore(r), csv: (r) => lightsText(r) }
  ];
  return (
    <>
      <div className="callout soft">Before an order can go into production three things happen at the same time, and none waits for another: the <b>DTF prints</b> are made or ordered, the <b>embroidery</b> is checked, and the <b>stock</b> is bought. Each has a light: <b>✕ red</b> not started, <b>! amber</b> under way, <b>✓ green</b> done, <b>–</b> not needed for this order. This page only shows where every order stands. It changes nothing.</div>
      <Panel flush>
        <DataTable<PreprodRow> rows={prep.rows} columns={cols} rowKey={(r) => r.order_id} loading={prep.loading} error={prep.error} onRetry={() => void prep.refresh()} views={views} filters={filters} storageKey="preprod" exportName="pre-production" defaultTab="notready"
          searchText={(r) => [r.order_ref, r.customer_name, lightsText(r)].join(' ')} searchPlaceholder="Search order or customer…" onRowClick={(r) => navigate(orderPath(r.order_ref))} defaultSort={{ col: 'ready', dir: -1 }} initial={tableStateFromQuery(route)}
          empty={<EmptyState icon="check" title="Nothing here">No order matches this view.</EmptyState>} />
      </Panel>
    </>
  );
}

function DtfTab({ dtf, orders, batches, route }: { dtf: ReturnType<typeof useView<DtfItemRow>>; orders: DtfOrderRow[]; batches: ReturnType<typeof useView<DtfBatchRow>>; route: Route }) {
  const totals = artworkTotals(dtf.rows); const { role } = useCtx(); const [build, setBuild] = useState<string[] | null>(null); const [recv, setRecv] = useState<DtfBatchRow | null>(null);
  const canBuild = canBuildRole(role); const canRecv = canReceiveRole(role);
  const bulk: BulkAction<DtfOrderRow>[] = [{ id: 'build', label: 'Build DTF order', icon: 'purchasing', run: canBuild ? (rows) => setBuild(rows.map((r) => r.order_id)) : undefined, disabledReason: canBuild ? undefined : 'Managers, admins and production planners only' }];
  const views: ViewDef<DtfOrderRow>[] = [
    { id: 'req', label: 'Prints required', test: (r) => r.status === 'required' }, { id: 'prog', label: 'In progress', test: (r) => r.status === 'in_progress' }, { id: 'done', label: 'Done', test: (r) => r.status === 'done' },
    { id: 'nofile', label: 'File missing', test: (r) => r.missingFiles > 0 }, { id: 'all', label: 'All', test: () => true }
  ];
  const cols: Column<DtfOrderRow>[] = [
    { id: 'order', header: 'Order', width: '110px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '190px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '110px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'where', header: 'Where', width: '120px', render: (r) => scopeLabel(r.scope), sort: (r) => r.scope, csv: (r) => scopeLabel(r.scope), hide: 'mobile' },
    { id: 'status', header: 'Prints', width: '180px', render: (r) => <Status tone={LIGHT_TONE[STATUS_LIGHT[r.status]]}>{dtfStatusWords(r.status)}</Status>, sort: (r) => r.status, csv: (r) => dtfStatusWords(r.status) },
    { id: 'pl', header: 'Placements', width: '110px', align: 'r', render: (r) => `${r.done} of ${r.placements}`, sort: (r) => r.placements, csv: (r) => r.placements },
    { id: 'units', header: 'Garments', width: '100px', align: 'r', render: (r) => r.units.toLocaleString('en-GB'), sort: (r) => r.units, csv: (r) => r.units },
    { id: 'files', header: 'Files', width: '190px', render: (r) => (r.missingFiles === 0 ? <Status tone="good" plain>All there</Status> : <span className="row" style={{ gap: 6, flexWrap: 'nowrap' }}><Status tone="high" plain>{r.missingFiles} missing</Status><a href={href('artwork/' + r.order_ref.replace('#', ''))} onClick={(e) => e.stopPropagation()} title="Opens this order in Artwork & Job Packs, where a file can be uploaded">Add files</a></span>), sort: (r) => r.missingFiles, csv: (r) => r.missingFiles }
  ];
  return (
    <>
      <div className="callout soft">Every placement on an order that is decorated with DTF needs a print. This tab lists the orders that need them and, further down, what has to be made by design, with the number of garments, so the same artwork on several orders is one line. A print can only be made or ordered once Flow holds its real file; where it does not yet, the order says <b>file missing</b>. In-house orders: tick them and press <b>Build DTF order</b> to order the prints from Super Print (nothing is sent until the email is approved). Third-party orders are left out: the decorator orders their own.</div>
      <Panel title="Orders that need DTF prints" icon="orders" flush>
        <DataTable<DtfOrderRow> rows={orders} columns={cols} rowKey={(r) => r.order_id} loading={dtf.loading} error={dtf.error} onRetry={() => void dtf.refresh()} views={views} storageKey="preprod-dtf" exportName="dtf-orders" defaultTab="req"
          searchText={(r) => [r.order_ref, r.customer_name].join(' ')} searchPlaceholder="Search order or customer…" onRowClick={(r) => navigate(orderPath(r.order_ref))} defaultSort={{ col: 'due', dir: 1 }} initial={tableStateFromQuery(route)} bulk={bulk}
          empty={<EmptyState icon="check" title="No DTF orders here">No order matches this view.</EmptyState>} />
      </Panel>
      <Panel title="DTF orders to Super Print" icon="purchasing" flush>
        {batches.loading ? <p className="dim" style={{ padding: 16, margin: 0 }}>Loading…</p> : batches.rows.length === 0 ? <p className="dim" style={{ padding: 16, margin: 0 }}>No DTF order has been built yet.</p>
          : <div>{[...batches.rows].sort((a, b) => b.created_at.localeCompare(a.created_at)).map((b) => <div key={b.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}>
            <b className="mono" style={{ minWidth: 130 }}>{b.batch_ref}</b><Status tone={batchTone(b)}>{batchWords(b)}</Status>
            <span className="grow dim">{b.received} of {b.placements} placements received · {b.prints.toLocaleString('en-GB')} prints{b.comm_ref ? ` · email ${b.comm_ref}` : ''}</span>
            {b.status === 'ordered' && <Button disabled={!canRecv} title={canRecv ? '' : 'Your role cannot book prints in'} onClick={() => setRecv(b)}>DTF received…</Button>}</div>)}</div>}
      </Panel>
      {build && <BuildDtfDialog orderIds={build} items={dtf.rows} onClose={() => setBuild(null)} />}
      {recv && <ReceiveDtfDialog batch={recv} items={dtf.rows} onClose={() => setRecv(null)} />}
      <Panel title="What has to be made, by design" icon="artwork" flush>
        {dtf.loading ? <p className="dim" style={{ padding: 16, margin: 0 }}>Loading…</p> : totals.length === 0 ? <p className="dim" style={{ padding: 16, margin: 0 }}>No DTF prints are needed.</p>
          : <div>{totals.slice(0, 40).map((t) => <div key={t.key} className="row wrap" style={{ padding: '8px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}>
            <span style={{ width: 44, height: 44, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', background: 'var(--surface-2, transparent)', borderRadius: 6, overflow: 'hidden' }}>{t.thumbnail_url ? <img src={t.thumbnail_url} alt="" loading="lazy" style={{ maxWidth: 44, maxHeight: 44 }} /> : <span className="dim" aria-hidden>–</span>}</span>
            <b className="grow" style={{ minWidth: 180 }}>{t.label}</b><span className="num" style={{ minWidth: 150 }}>{t.outstanding.toLocaleString('en-GB')} to make · {t.qty.toLocaleString('en-GB')} in all</span>
            <span className="dim" style={{ minWidth: 120 }}>{t.orders} order{t.orders === 1 ? '' : 's'}</span>{t.hasFile ? <Status tone="good" plain>File ready{t.file_format ? ` (${t.file_format.toUpperCase()})` : ''}</Status> : <Status tone="high" plain>{fileWords({ artwork_id: null, storage_status: null, file_format: null })}</Status>}</div>)}
            {totals.length > 40 && <p className="dim" style={{ padding: '8px 16px', margin: 0 }}>Showing the first 40 designs of {totals.length}. Export the table above for every order.</p>}</div>}
      </Panel>
    </>
  );
}
