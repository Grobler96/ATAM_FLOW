import { useMemo, useState } from 'react';
import { Panel, EmptyState, Status, Tabs } from '../ui/primitives';
import { useCtx } from '../data/context';
import { BuildDtfDialog, ReceiveDtfDialog } from '../components/DtfDialogs';
import { BatchList, DesignList } from '../components/DtfParts';
import { canBuildRole, canReceiveRole, type DtfBatchRow } from '../lib/dtfOrders';
import { DataTable, type BulkAction, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { shortDate } from '../lib/domain';
import { dtfStatusWords, ordersWithDtf, STATUS_LIGHT, LIGHT_TONE, type DtfItemRow, type DtfOrderRow } from '../lib/preproduction';
import { scopeLabel } from '../lib/orderRules';

// In house: ordering and managing the DTF prints. This is not applying them to garments: it is working out what to order from Super Print, ordering it
// (the email waits for a person's approval), and booking the prints in when they arrive. Third-party orders are not here: the decorator orders their own.
const orderPath = (ref: string) => 'orders/' + ref.replace('#', '');
const TABS = ['order', 'draft', 'ordered', 'received', 'designs'] as const; type TabId = (typeof TABS)[number];

export function DtfPrintsPage({ route }: { route: Route }) {
  const tab: TabId = (TABS as readonly string[]).includes(route.path[1] ?? '') ? (route.path[1] as TabId) : 'order';
  const { role } = useCtx(); const canBuild = canBuildRole(role), canRecv = canReceiveRole(role);
  const dtf = useView<DtfItemRow>('ui_dtf_items'), batches = useView<DtfBatchRow>('ui_dtf_batches');
  const [build, setBuild] = useState<string[] | null>(null); const [recv, setRecv] = useState<DtfBatchRow | null>(null);
  const items = useMemo(() => dtf.rows.filter((i) => i.scope !== 'third_party'), [dtf.rows]); // in house, and orders not yet decided
  const orders = useMemo(() => ordersWithDtf(items), [items]);
  const toOrder = useMemo(() => orders.filter((o) => o.status === 'required'), [orders]);
  const drafts = useMemo(() => batches.rows.filter((b) => b.status === 'draft'), [batches.rows]);
  const waiting = useMemo(() => batches.rows.filter((b) => b.status === 'ordered'), [batches.rows]);
  // A draft DTF order that holds a third-party order would order prints the decorator orders themselves: say so before anyone approves it.
  const warnDraft = (b: DtfBatchRow): string | null => { const tp = [...new Set(dtf.rows.filter((i) => i.batch_id === b.id && i.scope === 'third_party').map((i) => i.order_ref))]; return tp.length ? `${tp.join(', ')} ${tp.length === 1 ? 'is' : 'are'} a third-party order, so the decorator orders ${tp.length === 1 ? 'its' : 'their'} own DTFs. Do not approve this email: cancel it under Purchasing, Emails.` : !b.supplier_has_email ? 'Super Print has no email address in Flow yet, so this email cannot be approved. Add the address to the supplier first.' : null; };
  const booked = useMemo(() => batches.rows.filter((b) => b.status === 'received'), [batches.rows]);
  const sortNew = (a: DtfBatchRow, b: DtfBatchRow) => b.created_at.localeCompare(a.created_at);
  const prints = (list: DtfItemRow[]) => list.reduce((n, i) => n + i.qty, 0);
  const needPrints = prints(items.filter((i) => i.status === 'required' && !i.batch_id));
  const missing = items.filter((i) => i.status === 'required' && !i.batch_id && !(i.artwork_id && i.storage_status === 'stored')).length;

  const bulk: BulkAction<DtfOrderRow>[] = [{ id: 'build', label: 'Build DTF order', icon: 'purchasing', run: canBuild ? (rows) => setBuild(rows.map((r) => r.order_id)) : undefined, disabledReason: canBuild ? undefined : 'Managers, admins and production planners only' }];
  const views: ViewDef<DtfOrderRow>[] = [{ id: 'req', label: 'Prints required', test: (r) => r.status === 'required' }, { id: 'nofile', label: 'File missing', test: (r) => r.missingFiles > 0 }, { id: 'all', label: 'All', test: () => true }];
  const filters: FilterDef<DtfOrderRow>[] = [{ id: 'scope', label: 'Where', options: [{ value: 'in_house', label: 'In house' }, { value: 'unclassified', label: 'Not decided' }], test: (r, v) => r.scope === v }];
  const cols: Column<DtfOrderRow>[] = [
    { id: 'order', header: 'Order', width: '110px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '190px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '110px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'where', header: 'Where', width: '120px', render: (r) => scopeLabel(r.scope), sort: (r) => r.scope, csv: (r) => scopeLabel(r.scope), hide: 'mobile' },
    { id: 'status', header: 'Prints', width: '180px', render: (r) => <Status tone={LIGHT_TONE[STATUS_LIGHT[r.status]]}>{dtfStatusWords(r.status)}</Status>, sort: (r) => r.status, csv: (r) => dtfStatusWords(r.status) },
    { id: 'pl', header: 'Placements', width: '110px', align: 'r', render: (r) => `${r.done} of ${r.placements}`, sort: (r) => r.placements, csv: (r) => r.placements },
    { id: 'units', header: 'Prints', width: '90px', align: 'r', render: (r) => r.units.toLocaleString('en-GB'), sort: (r) => r.units, csv: (r) => r.units },
    { id: 'files', header: 'Files', width: '190px', render: (r) => (r.missingFiles === 0 ? <Status tone="good" plain>All there</Status> : <span className="row" style={{ gap: 6, flexWrap: 'nowrap' }}><Status tone="high" plain>{r.missingFiles} missing</Status><a href={href('artwork/' + r.order_ref.replace('#', ''))} onClick={(e) => e.stopPropagation()}>Add the file</a></span>), sort: (r) => r.missingFiles, csv: (r) => r.missingFiles },
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>DTF prints</h1>
        <p>{dtf.loading ? 'Loading…' : `${needPrints.toLocaleString('en-GB')} prints to order · ${drafts.length} waiting to send · ${waiting.length} order${waiting.length === 1 ? '' : 's'} waiting for delivery · ${missing} placement${missing === 1 ? '' : 's'} missing a file`}</p></div></div>
      <div className="callout soft">In house, this is where DTF prints are <b>ordered from Super Print and booked in</b>. Pick the orders that need prints and build one DTF order. It then shows under <b>Waiting to send</b> until a person approves its email: open <a href={href('purchasing/emails')}>Purchasing, Emails</a> and approve it there, which is what sends it to Super Print. When the prints arrive, book them in here. Applying them to garments happens on the floor, not here. Third-party orders are not on this page: the decorator orders their own.</div>
      <Tabs label="DTF print sections" value={tab} tabs={[{ id: 'order', label: 'To order', count: toOrder.length }, { id: 'draft', label: 'Waiting to send', count: drafts.length }, { id: 'ordered', label: 'Ordered, waiting', count: waiting.length }, { id: 'received', label: 'Booked in', count: booked.length }, { id: 'designs', label: 'By design' }]} onChange={(t) => navigate(t === 'order' ? 'dtf-prints' : 'dtf-prints/' + t)} />
      {tab === 'order' && (
        <Panel title="Orders that need DTF prints" icon="orders" flush>
          <DataTable<DtfOrderRow> rows={orders} columns={cols} rowKey={(r) => r.order_id} loading={dtf.loading} error={dtf.error} onRetry={() => void dtf.refresh()} views={views} filters={filters} storageKey="dtf-prints" exportName="dtf-orders" defaultTab="req"
            searchText={(r) => [r.order_ref, r.customer_name].join(' ')} searchPlaceholder="Search order or customer…" onRowClick={(r) => navigate(orderPath(r.order_ref))} defaultSort={{ col: 'due', dir: 1 }} initial={tableStateFromQuery(route)} bulk={bulk}
            empty={<EmptyState icon="check" title="No prints to order">No in-house order matches this view.</EmptyState>} />
        </Panel>)}
      {tab === 'draft' && <Panel title="DTF orders built but not sent to Super Print yet" icon="purchasing" flush><BatchList batches={[...drafts].sort(sortNew)} loading={batches.loading} empty="Nothing is waiting to be sent. Build a DTF order on the To order tab and it shows here until its email is approved." canReceive={false} warn={warnDraft} /></Panel>}
      {tab === 'ordered' && <Panel title="DTF orders waiting for delivery" icon="purchasing" flush><BatchList batches={[...waiting].sort(sortNew)} loading={batches.loading} empty="Nothing is waiting for delivery. An order shows here once its email to Super Print has been sent." canReceive={canRecv} onReceive={setRecv} /></Panel>}
      {tab === 'received' && <Panel title="Booked in" icon="check" flush><BatchList batches={[...booked].sort(sortNew)} loading={batches.loading} empty="No DTF order has been booked in yet." canReceive={canRecv} /></Panel>}
      {tab === 'designs' && <Panel title="What has to be made, by design" icon="artwork" flush><DesignList items={items} loading={dtf.loading} /></Panel>}
      {build && <BuildDtfDialog orderIds={build} items={dtf.rows} onClose={() => setBuild(null)} />}
      {recv && <ReceiveDtfDialog batch={recv} items={dtf.rows} onClose={() => setRecv(null)} />}
    </div>
  );
}
