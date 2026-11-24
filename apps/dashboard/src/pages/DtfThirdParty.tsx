import { useMemo, useState } from 'react';
import { Panel, EmptyState, Status } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { useCtx } from '../data/context';
import { refreshAll, useView } from '../data/store';
import { supabase } from '../lib/api';
import { canBuildRole } from '../lib/dtfOrders';
import { DataTable, type BulkAction, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { shortDate } from '../lib/domain';
import { LIGHT_TONE, STATUS_LIGHT } from '../lib/preproduction';
import type { DtfThirdPartyRow } from '../data/types';

// 3PD DTF prints: the transfers a decorator is making for our third-party orders. The decorator orders and makes their own and confirms on their
// portal ("in production", then "made"); this page lets the office see where each one stands and confirm on their behalf (a phone call, an email).
const WORDS = { required: 'Not started', in_progress: 'In production', done: 'Made' } as const;
const who = (r: DtfThirdPartyRow) => (r.status_by ? (r.status_by.startsWith('staff:') ? 'Confirmed by the office' : 'Confirmed by ' + r.status_by.replace(/^producer:/, '')) : '');
const orderPath = (ref: string) => 'orders/' + ref.replace('#', '');

export function DtfThirdPartyPage({ route }: { route: Route }) {
  const { role } = useCtx(); const toast = useToast(); const can = canBuildRole(role);
  const v = useView<DtfThirdPartyRow>('ui_dtf_third_party'); const [busy, setBusy] = useState(false);
  const rows = v.rows; const todo = rows.filter((r) => r.status !== 'done');
  const decorators = useMemo(() => [...new Set(rows.map((r) => r.producer_name ?? 'No decorator chosen'))].sort(), [rows]);
  async function move(list: DtfThirdPartyRow[], to: 'in_progress' | 'done') {
    setBusy(true); const { data, error } = await supabase.rpc('dtf_third_party_set', { p_item_ids: list.map((r) => r.id), p_to: to }); setBusy(false);
    const r = (data ?? {}) as { ok?: boolean; error?: string; changed?: number };
    if (error || r.ok === false) { toast.push({ tone: 'bad', title: 'Could not do that', body: error?.message ?? r.error }); return; }
    toast.push({ tone: 'good', title: `${r.changed} transfer${r.changed === 1 ? '' : 's'} marked ${to === 'done' ? 'made' : 'in production'}` }); void v.refresh(); void refreshAll();
  }
  const reason = can ? undefined : 'Managers, admins and production planners only';
  const bulk: BulkAction<DtfThirdPartyRow>[] = [
    { id: 'start', label: 'Mark in production', icon: 'production', run: can && !busy ? (rs) => void move(rs, 'in_progress') : undefined, disabledReason: reason ?? (busy ? 'Working…' : undefined) },
    { id: 'done', label: 'Confirm made', icon: 'check', run: can && !busy ? (rs) => void move(rs, 'done') : undefined, disabledReason: reason ?? (busy ? 'Working…' : undefined) }];
  const views: ViewDef<DtfThirdPartyRow>[] = [{ id: 'todo', label: 'To make', test: (r) => r.status === 'required' }, { id: 'prod', label: 'In production', test: (r) => r.status === 'in_progress' }, { id: 'made', label: 'Made', test: (r) => r.status === 'done' }, { id: 'all', label: 'All', test: () => true }];
  const filters: FilterDef<DtfThirdPartyRow>[] = [{ id: 'dec', label: 'Decorator', options: decorators.map((d) => ({ value: d, label: d })), test: (r, val) => (r.producer_name ?? 'No decorator chosen') === val }];
  const cols: Column<DtfThirdPartyRow>[] = [
    { id: 'dec', header: 'Decorator', width: '170px', render: (r) => r.producer_name ?? <span className="dim">None chosen</span>, sort: (r) => r.producer_name, csv: (r) => r.producer_name },
    { id: 'order', header: 'Order', width: '110px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '170px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name, hide: 'mobile' },
    { id: 'due', header: 'Due', width: '100px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'area', header: 'Placement', width: '150px', render: (r) => <span>{r.area}{r.product_name ? <span className="dim"> · {r.product_name}</span> : null}</span>, sort: (r) => r.area, csv: (r) => r.area },
    { id: 'qty', header: 'Qty', width: '70px', align: 'r', render: (r) => r.qty.toLocaleString('en-GB'), sort: (r) => r.qty, csv: (r) => r.qty },
    { id: 'status', header: 'Transfer', width: '200px', render: (r) => <span className="row" style={{ gap: 6, flexWrap: 'nowrap' }}><Status tone={LIGHT_TONE[STATUS_LIGHT[r.status]]}>{WORDS[r.status]}</Status>{who(r) && <span className="dim" title={r.status_at ? shortDate(r.status_at) : ''}>{who(r)}</span>}</span>, sort: (r) => r.status, csv: (r) => WORDS[r.status] },
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>3PD DTF prints</h1>
        <p>{v.loading ? 'Loading…' : `${todo.length} transfer${todo.length === 1 ? '' : 's'} still to be made by ${new Set(todo.map((r) => r.producer_name ?? '')).size} decorator${new Set(todo.map((r) => r.producer_name ?? '')).size === 1 ? '' : 's'}`}</p></div></div>
      <div className="callout soft">On a third-party order the <b>decorator orders and makes their own DTF transfers</b>. They mark each one <b>in production</b> and then <b>made</b> on their portal. This page shows where every transfer stands. If a decorator confirms by phone or email, tick the transfers and press <b>Mark in production</b> or <b>Confirm made</b> here for them. It is recorded as the office confirming. Moves only go forward.</div>
      <Panel title="Transfers being made by decorators" icon="producers" flush>
        <DataTable<DtfThirdPartyRow> rows={rows} columns={cols} rowKey={(r) => r.id} loading={v.loading} error={v.error} onRetry={() => void v.refresh()} views={views} filters={filters} storageKey="dtf-3pd" exportName="dtf-third-party" defaultTab="todo"
          searchText={(r) => [r.order_ref, r.customer_name, r.producer_name, r.area].join(' ')} searchPlaceholder="Search order, customer or decorator…" onRowClick={(r) => navigate(orderPath(r.order_ref))} defaultSort={{ col: 'due', dir: 1 }} initial={tableStateFromQuery(route)} bulk={bulk}
          empty={<EmptyState icon="check" title="No transfers here">No third-party transfer matches this view.</EmptyState>} />
      </Panel>
    </div>
  );
}
