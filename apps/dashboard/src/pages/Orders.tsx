import { useMemo } from 'react';
import { Panel, Status } from '../ui/primitives';
import { DataTable, type BulkAction, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { exceptionActionTo } from '../lib/api';
import { useToast } from '../ui/overlay';
import { METHOD_LABEL, money, pct, PRIORITY, statusLabel, stockStatus, TP_STATUS_LABEL } from '../lib/domain';
import { DueCell, Num, PriorityCell, StatusCell } from '../components/common';
import { OrderDrawer } from './OrderDrawer';
import { useRunner } from '../shell/useRunner';
import { WORKFLOWS } from '../lib/workflows';
import { relativeTime } from '../lib/format';
import type { ExceptionRow } from '../types';
import type { AllocationRow, ArtworkStatusRow, BinRow, OrderRow, SelectionRow, TpOrderRow } from '../data/types';

export interface OrderVM extends OrderRow { route: 'Producer' | 'Internal'; producer: string | null; tp_status: string | null; stock: ReturnType<typeof stockStatus>; art: string; artOk: boolean | null; bin: string; margin: number | null; exCount: number; sev: '' | 'critical' | 'high' | 'medium' | 'low'; atRisk: boolean; score: number | null; stage: string }
const RANK = { critical: 1, high: 2, medium: 3, low: 4, '': 9 } as const;
const AWAIT_RETURN = ['awaiting_return', 'in_transit_back', 'partially_returned', 'production_complete', 'in_production', 'received_by_producer', 'dispatched'];

export function OrdersPage({ route }: { route: Route }) {
  const orders = useView<OrderRow>('ui_orders'), tpo = useView<TpOrderRow>('ui_tp_orders'), art = useView<ArtworkStatusRow>('ui_artwork_status'), sel = useView<SelectionRow>('ui_selection');
  const chg = useView<{ order_id: string; status: string }>('ui_order_changes'); const changedIds = useMemo(() => new Set(chg.rows.filter((c) => c.status === 'new').map((c) => c.order_id)), [chg.rows]);
  const bins = useView<BinRow>('ui_bins'), ex = useView<ExceptionRow>('ui_exceptions'), alloc = useView<AllocationRow>('ui_allocation');
  const { canAct } = useCtx(); const toast = useToast(); const runner = useRunner();

  const rows = useMemo<OrderVM[]>(() => orders.rows.filter((o) => o.order_status !== 'dispatched').map((o) => {
    const tp = tpo.rows.find((t) => t.order_id === o.id && t.tp_status), a = art.rows.find((x) => x.order_id === o.id), s = sel.rows.find((x) => x.order_id === o.id), al = alloc.rows.find((x) => x.order_id === o.id);
    const myEx = ex.rows.filter((e) => e.order_refs.includes(o.order_ref)); const sev = myEx.reduce<OrderVM['sev']>((m, e) => (RANK[e.severity] < RANK[m] ? e.severity : m), '');
    const myBins = bins.rows.filter((b) => (b.order_refs ?? []).includes(o.order_ref)).map((b) => b.bin_code);
    return { ...o, route: tp ? 'Producer' : 'Internal', producer: tp?.producer_name ?? null, tp_status: tp?.tp_status ?? null, stock: stockStatus(o), art: !a ? 'No decoration' : a.blocking_issues === 0 ? 'Ready' : `${a.blocking_issues} issue${a.blocking_issues > 1 ? 's' : ''}`, artOk: a ? a.blocking_issues === 0 : null,
      bin: myBins.join(', '), margin: s?.margin_pct ?? null, exCount: myEx.length, sev, atRisk: myEx.some((e) => e.type_code === 'order_at_risk'), score: al?.score ?? null, stage: o.production_stage ?? statusLabel(o.order_status) };
  }), [orders.rows, tpo.rows, art.rows, sel.rows, bins.rows, ex.rows, alloc.rows]);

  const views: ViewDef<OrderVM>[] = [
    { id: 'all', label: 'All open', test: () => true }, { id: 'today', label: 'Due today', test: (o) => o.is_due_today }, { id: 'overdue', label: 'Overdue', test: (o) => o.is_overdue }, { id: 'risk', label: 'At risk', test: (o) => o.atRisk },
    { id: 'ready', label: 'Ready for production', test: (o) => o.order_status === 'ready_for_production' }, { id: 'stock', label: 'Blocked by stock', test: (o) => o.order_status === 'awaiting_stock' },
    { id: 'producers', label: 'With producers', test: (o) => o.route === 'Producer' }, { id: 'return', label: 'Awaiting return', test: (o) => !!o.tp_status && AWAIT_RETURN.includes(o.tp_status) },
    { id: 'dispatch', label: 'Ready for dispatch', test: (o) => o.order_status === 'ready_for_dispatch' }, { id: 'exceptions', label: 'Exceptions', test: (o) => o.exCount > 0 },
    { id: 'hold', label: 'On hold', test: (o) => o.order_status === 'on_hold' }, { id: 'changed', label: 'Changed', test: (o) => changedIds.has(o.id) }
  ];
  const uniq = (f: (o: OrderVM) => string | null | undefined) => [...new Set(rows.map(f).filter(Boolean) as string[])].sort().map((v) => ({ value: v, label: v }));
  const filters: FilterDef<OrderVM>[] = [
    { id: 'status', label: 'Status', options: Object.keys(Object.fromEntries(rows.map((o) => [o.order_status, 1]))).map((v) => ({ value: v, label: statusLabel(v) })), test: (o, v) => o.order_status === v },
    { id: 'due', label: 'Due', options: [{ value: 'overdue', label: 'Overdue' }, { value: 'today', label: 'Today' }, { value: '3', label: 'Next 3 days' }, { value: '7', label: 'Next 7 days' }, { value: 'none', label: 'No date' }], test: (o, v) => v === 'overdue' ? o.is_overdue : v === 'today' ? o.is_due_today : v === 'none' ? o.days_to_due === null : o.days_to_due !== null && o.days_to_due >= 0 && o.days_to_due <= Number(v) },
    { id: 'customer', label: 'Customer', options: uniq((o) => o.customer_name), test: (o, v) => o.customer_name === v },
    { id: 'priority', label: 'Priority', options: Object.entries(PRIORITY).map(([k, v]) => ({ value: k, label: v.label })), test: (o, v) => String(o.priority) === v },
    { id: 'method', label: 'Method', options: [...new Set(rows.flatMap((o) => o.decoration_methods))].map((m) => ({ value: m, label: METHOD_LABEL[m] ?? m })), test: (o, v) => o.decoration_methods.includes(v) },
    { id: 'stock', label: 'Stock', options: [{ value: 'Secured', label: 'Secured' }, { value: 'Allocated', label: 'Allocated' }, { value: 'Partial', label: 'Partial' }, { value: 'Short', label: 'Short / none' }], test: (o, v) => o.stock.label.startsWith(v) },
    { id: 'artwork', label: 'Artwork', options: [{ value: 'ok', label: 'Ready' }, { value: 'issue', label: 'Has issues' }, { value: 'none', label: 'No decoration' }], test: (o, v) => v === 'ok' ? o.artOk === true : v === 'issue' ? o.artOk === false : o.artOk === null },
    { id: 'route', label: 'Route', options: [{ value: 'Internal', label: 'Internal' }, { value: 'Producer', label: 'Producer' }], test: (o, v) => o.route === v },
    { id: 'producer', label: 'Producer', options: uniq((o) => o.producer), test: (o, v) => o.producer === v },
    { id: 'bin', label: 'Bin', options: [{ value: 'in', label: 'In a bin' }, { value: 'out', label: 'No bin' }], test: (o, v) => (v === 'in') === !!o.bin },
    { id: 'exc', label: 'Exceptions', options: [{ value: 'any', label: 'Has open exceptions' }, { value: 'critical', label: 'Has critical' }, { value: 'none', label: 'None' }], test: (o, v) => v === 'any' ? o.exCount > 0 : v === 'critical' ? o.sev === 'critical' : o.exCount === 0 }
  ];

  const columns: Column<OrderVM>[] = [
    { id: 'ref', header: 'Order', width: '104px', render: (o) => <b className="mono">{o.order_ref}</b>, sort: (o) => o.order_ref, csv: (o) => o.order_ref },
    { id: 'customer', header: 'Customer', width: '210px', render: (o) => <span title={o.customer_name ?? ''}>{o.customer_name ?? '—'}</span>, sort: (o) => o.customer_name?.toLowerCase() ?? null, csv: (o) => o.customer_name },
    { id: 'due', header: 'Due', width: '170px', render: (o) => <DueCell days={o.days_to_due} date={o.due_date} />, sort: (o) => o.due_date, csv: (o) => o.due_date?.slice(0, 10) },
    { id: 'priority', header: 'Priority', width: '120px', render: (o) => <PriorityCell p={o.priority} vip={o.is_vip} />, sort: (o) => o.priority, csv: (o) => PRIORITY[o.priority]?.label },
    { id: 'score', header: 'Score', width: '70px', align: 'r', render: (o) => <Num v={o.score} />, sort: (o) => o.score, csv: (o) => o.score },
    { id: 'status', header: 'Status', width: '176px', render: (o) => <StatusCell s={o.order_status} />, sort: (o) => o.order_status, csv: (o) => statusLabel(o.order_status) },
    { id: 'route', header: 'Route', width: '150px', render: (o) => o.route === 'Producer' ? <span title={o.producer ?? ''}><Status tone="info" plain>Producer</Status> <span className="dim">{o.producer}</span></span> : <span className="dim">Internal</span>, sort: (o) => o.route, csv: (o) => o.producer ?? 'Internal' },
    { id: 'stock', header: 'Stock', width: '120px', render: (o) => <Status tone={o.stock.tone} plain>{o.stock.label}</Status>, csv: (o) => o.stock.label },
    { id: 'art', header: 'Artwork', width: '120px', render: (o) => <Status tone={o.artOk === false ? 'high' : o.artOk ? 'good' : ''} plain>{o.art}</Status>, csv: (o) => o.art },
    { id: 'units', header: 'Units', width: '72px', align: 'r', render: (o) => <Num v={o.total_units} />, sort: (o) => o.total_units, csv: (o) => o.total_units },
    { id: 'value', header: 'Value', width: '96px', align: 'r', render: (o) => <span className="num">{money(o.order_value)}</span>, sort: (o) => o.order_value, csv: (o) => o.order_value },
    { id: 'margin', header: 'Margin', width: '76px', align: 'r', render: (o) => <span className="num">{pct(o.margin)}</span>, sort: (o) => o.margin, csv: (o) => o.margin },
    { id: 'bin', header: 'Bin', width: '100px', render: (o) => <span className="mono dim">{o.bin || '—'}</span>, csv: (o) => o.bin },
    { id: 'stage', header: 'Stage', width: '150px', render: (o) => <span className="muted">{o.tp_status ? TP_STATUS_LABEL[o.tp_status] ?? o.tp_status : o.stage}</span>, csv: (o) => o.stage },
    { id: 'risk', header: 'Risk', width: '120px', render: (o) => o.sev ? <Status tone={o.sev}>{o.atRisk ? 'At risk' : o.sev}{o.exCount > 1 ? ` ·${o.exCount}` : ''}</Status> : <span className="dim">—</span>, sort: (o) => RANK[o.sev], csv: (o) => o.sev },
    { id: 'updated', header: 'Updated', width: '100px', render: (o) => <span className="dim">{relativeTime(o.updated_at)}</span>, sort: (o) => o.updated_at, csv: (o) => o.updated_at }
  ];

  const allocateWf = WORKFLOWS.find((w) => w.id === 'allocate')!;
  const bulk: BulkAction<OrderVM>[] = [
    { id: 'alloc', label: 'Allocate stock', icon: 'box', run: canAct && runner.can(allocateWf) ? () => void runner.run(allocateWf) : undefined, disabledReason: 'Your role cannot run allocation' },
    { id: 'po', label: 'Create PO', icon: 'purchasing', run: canAct ? (r) => window.dispatchEvent(new CustomEvent('atamflow:create-po', { detail: r.filter((o) => o.order_status === 'awaiting_stock').map((o) => o.id) })) : undefined, disabledReason: 'Your role cannot create POs' },
    { id: 'esc', label: 'Escalate (raise issue)', icon: 'exceptions', run: canAct ? (r) => void raise(r) : undefined, disabledReason: 'Your role cannot raise issues' },
    { id: 'send', label: 'Send to producer', icon: 'truck', run: canAct ? (r) => window.dispatchEvent(new CustomEvent('atamflow:send-to-producer', { detail: { orders: r.map((o) => o.order_ref) } })) : undefined, disabledReason: 'Your role cannot create producer movements' },
    { id: 'labels', label: 'Generate labels', icon: 'labels', run: canAct ? (r) => window.dispatchEvent(new CustomEvent('atamflow:generate-labels', { detail: { type: 'order', refs: r.map((o) => o.order_ref) } })) : undefined, disabledReason: 'Your role cannot generate labels' },
    { id: 'qc', label: 'Record quality check', icon: 'check', run: canAct ? (r) => window.dispatchEvent(new CustomEvent('atamflow:record-qc', { detail: { orderId: r[0]?.id } })) : undefined, disabledReason: 'Your role cannot record quality checks' },
    { id: 'status', label: 'Update status', icon: 'check', disabledReason: 'Order status follows DecoNetwork and the engines; manual status changes are not built yet' },
    { id: 'bin', label: 'Assign bin', icon: 'warehouse', run: canAct ? () => navigate('warehouse') : undefined, disabledReason: 'Your role cannot change bins' }
  ];
  async function raise(r: OrderVM[]) {
    const res = await exceptionActionTo('exceptions', 'raise', { category: 'order', severity: 'high', description: `Escalated from the Orders list: ${r.map((o) => o.order_ref).join(', ')}`, links: r.map((o) => ({ type: 'order', id: o.id })) });
    toast.push(res.ok === false ? { tone: 'bad', title: 'Could not raise the issue', body: String(res.error) } : { tone: 'good', title: `Issue raised for ${r.length} order(s)`, href: '#/exceptions', linkLabel: 'Open Exceptions' });
  }

  const open = route.path[1];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Orders</h1><p>Every open order, with why it is where it is.</p></div></div>
      <Panel flush>
        <DataTable<OrderVM> rows={rows} columns={columns} rowKey={(o) => o.id} loading={orders.loading} error={orders.error} onRetry={() => void orders.refresh()} views={views} filters={filters} storageKey="orders" exportName="orders"
          searchText={(o) => [o.order_ref, o.customer_name, o.customer_po, o.producer, o.bin, o.order_status, o.decoration_methods.join(' ')].join(' ')} searchPlaceholder="Search order, customer, PO, producer, bin…"
          onRowClick={(o) => navigate('orders/' + o.order_ref.replace('#', ''))} activeKey={open ? rows.find((o) => o.order_ref.replace('#', '') === open)?.id : null}
          rowTone={(o) => (o.sev === 'critical' || o.sev === 'high' || o.sev === 'medium' ? o.sev : o.is_overdue ? 'critical' : '')} bulk={bulk} defaultSort={{ col: 'due', dir: 1 }} initial={tableStateFromQuery(route)} />
      </Panel>
      {open && <OrderDrawer orderRef={open} onClose={() => navigate('orders')} />}
    </div>
  );
}
