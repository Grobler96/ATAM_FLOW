import { useMemo, useState } from 'react';
import { Button, EmptyState, Facts, Panel, Segmented, Skeleton, Status } from '../ui/primitives';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { DataTable, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { exceptionActionTo } from '../lib/api';
import { PO_STATUS_LABEL, money, shortDate, within } from '../lib/domain';
import { dateTime } from '../lib/format';
import { Num, OrderTags } from '../components/common';
import type { PoLineRow, PoRow, SupplierDiscRow } from '../data/types';

interface SupplierRow { id: string; name: string; email: string | null; contact_name: string | null; lead_time_days: number; delivery_cost: number; free_delivery_over: number | null; min_order_value: number | null; payment_terms: string | null; on_time_rate: number | null; quality_rating: number | null; can_deliver_to_producer: boolean }
interface CommRow { id: string; comm_ref: string; kind: string; status: string; to_addresses: string[]; subject: string; created_at: string; entity_id: string | null; supplier_name: string | null; error: string | null }
type Mode = 'pos' | 'discrepancies' | 'emails' | 'suppliers';
const poTone = (s: string | null) => (s === 'received' || s === 'closed' ? 'good' : s === 'short_shipped' ? 'critical' : s === 'cancelled' ? 'low' : s === 'draft' ? 'medium' : 'info') as 'good' | 'critical' | 'low' | 'medium' | 'info';

export function PurchasingPage({ route, onCreatePo }: { route: Route; onCreatePo: () => void }) {
  const pos = useView<PoRow>('ui_purchase_orders'), disc = useView<SupplierDiscRow>('ui_supplier_discrepancies'), sup = useView<SupplierRow>('ui_suppliers'), comms = useView<CommRow>('ui_communications');
  const { canAct } = useCtx(); const [mode, setMode] = useState<Mode>('pos'); const open = route.path[1];
  const views: ViewDef<PoRow>[] = [{ id: 'open', label: 'Open', test: (p) => p.units_outstanding > 0 && !['cancelled', 'closed'].includes(p.po_status ?? '') }, { id: 'late', label: 'Late', test: (p) => p.is_late }, { id: 'arriving', label: 'Arriving in 3 days', test: (p) => p.units_outstanding > 0 && !p.is_late && within(p.expected_date, 3) },
    { id: 'draft', label: 'Draft', test: (p) => p.po_status === 'draft' }, { id: 'disc', label: 'Discrepancies', test: (p) => p.open_discrepancies > 0 || p.units_short > 0 || p.po_status === 'short_shipped' }, { id: 'received', label: 'Received', test: (p) => ['received', 'closed'].includes(p.po_status ?? '') || p.delivery_status === 'received' }, { id: 'all', label: 'All', test: () => true }];
  const filters: FilterDef<PoRow>[] = [{ id: 'supplier', label: 'Supplier', options: [...new Set(pos.rows.map((p) => p.supplier).filter(Boolean) as string[])].sort().map((v) => ({ value: v, label: v })), test: (p, v) => p.supplier === v },
    { id: 'origin', label: 'Source', options: [{ value: 'atam_flow', label: 'ATAM_FLOW' }, { value: 'deconetwork', label: 'DecoNetwork' }], test: (p, v) => p.origin === v }, { id: 'pay', label: 'Payment', options: ['unpaid', 'part_paid', 'paid', 'credit'].map((v) => ({ value: v, label: v.replace('_', ' ') })), test: (p, v) => p.payment_status === v }];
  const cols: Column<PoRow>[] = [
    { id: 'ref', header: 'PO', width: '130px', render: (p) => <b className="mono">{p.po_ref}</b>, sort: (p) => p.po_ref, csv: (p) => p.po_ref }, { id: 'sup', header: 'Supplier', width: '190px', render: (p) => p.supplier, sort: (p) => p.supplier, csv: (p) => p.supplier },
    { id: 'status', header: 'Status', width: '140px', render: (p) => <Status tone={p.is_late ? 'critical' : poTone(p.po_status)}>{p.is_late ? `${p.days_late}d late` : p.po_status ? PO_STATUS_LABEL[p.po_status] : (p.delivery_status ?? '—')}</Status>, sort: (p) => p.po_status, csv: (p) => p.po_status ?? p.delivery_status },
    { id: 'date', header: 'Ordered', width: '90px', render: (p) => <span className="dim">{shortDate(p.po_date)}</span>, sort: (p) => p.po_date, csv: (p) => p.po_date }, { id: 'req', header: 'Required', width: '90px', render: (p) => <span className="dim">{shortDate(p.required_by)}</span>, sort: (p) => p.required_by, csv: (p) => p.required_by },
    { id: 'exp', header: 'Expected', width: '90px', render: (p) => shortDate(p.expected_date), sort: (p) => p.expected_date, csv: (p) => p.expected_date }, { id: 'act', header: 'Delivered', width: '90px', render: (p) => <span className="dim">{shortDate(p.actual_delivery)}</span>, sort: (p) => p.actual_delivery, csv: (p) => p.actual_delivery },
    { id: 'ord', header: 'Units', width: '70px', align: 'r', render: (p) => <Num v={p.units_ordered} />, sort: (p) => p.units_ordered, csv: (p) => p.units_ordered }, { id: 'rec', header: 'Received', width: '82px', align: 'r', render: (p) => <Num v={p.units_received} dim0 />, sort: (p) => p.units_received, csv: (p) => p.units_received },
    { id: 'out', header: 'Outstanding', width: '96px', align: 'r', render: (p) => <Num v={p.units_outstanding} dim0 />, sort: (p) => p.units_outstanding, csv: (p) => p.units_outstanding }, { id: 'cost', header: 'Cost', width: '96px', align: 'r', render: (p) => <span className="num">{money(p.total_cost)}</span>, sort: (p) => p.total_cost, csv: (p) => p.total_cost },
    { id: 'pay', header: 'Payment', width: '90px', render: (p) => <span className="dim">{p.payment_status.replace('_', ' ')}</span>, csv: (p) => p.payment_status }, { id: 'orders', header: 'Orders', width: '200px', render: (p) => <OrderTags refs={p.source_orders} max={2} />, csv: (p) => p.source_orders },
    { id: 'disc', header: 'Discrepancy', width: '110px', render: (p) => p.open_discrepancies ? <Status tone="critical">{p.open_discrepancies} open</Status> : p.units_short ? <Status tone="high">{p.units_short} short</Status> : <span className="dim">—</span>, csv: (p) => p.open_discrepancies }
  ];
  const draftCount = pos.rows.filter((p) => p.po_status === 'draft').length;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Purchasing</h1><p>{pos.rows.filter((p) => p.units_outstanding > 0).length} POs with stock outstanding · {pos.rows.filter((p) => p.is_late).length} late{draftCount ? ` · ${draftCount} draft` : ''}</p></div>
        <div className="row"><Segmented label="Purchasing section" value={mode} options={[{ id: 'pos', label: 'Purchase orders' }, { id: 'discrepancies', label: `Discrepancies (${disc.rows.length})` }, { id: 'emails', label: `Emails (${comms.rows.filter((c) => ['pending_review', 'draft', 'failed'].includes(c.status)).length})` }, { id: 'suppliers', label: 'Suppliers' }]} onChange={setMode} />
          {canAct && <Button variant="primary" icon="plus" onClick={onCreatePo}>Create PO</Button>}</div></div>
      {mode === 'pos' && <Panel flush><DataTable<PoRow> rows={pos.rows} columns={cols} rowKey={(p) => p.po_id} loading={pos.loading} error={pos.error} onRetry={() => void pos.refresh()} views={views} filters={filters} storageKey="purchasing" exportName="purchase-orders" defaultTab="open"
        searchText={(p) => [p.po_ref, p.supplier, (p.source_orders ?? []).join(' '), p.po_status, p.delivery_status].join(' ')} searchPlaceholder="Search PO, supplier, order…" onRowClick={(p) => navigate('purchasing/' + p.po_id)} activeKey={open} rowTone={(p) => (p.is_late ? 'critical' : p.open_discrepancies ? 'high' : '')}
        defaultSort={{ col: 'exp', dir: 1 }} initial={tableStateFromQuery(route)} /></Panel>}
      {mode === 'discrepancies' && <Panel title="Open supplier discrepancies" flush>{disc.rows.length === 0 ? <EmptyState icon="check" title="No open discrepancies" /> : <div className="stack" style={{ gap: 0 }}>{disc.rows.map((d) => <div key={d.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', justifyContent: 'space-between' }}><span className="mono">{d.disc_ref}</span><span className="grow">{d.disc_type} · {d.qty} × <span className="mono">{d.sku}</span> · PO {d.po_ref} · {d.supplier}</span><Status tone={d.is_overdue ? 'critical' : 'medium'}>{d.is_overdue ? 'Overdue' : `due ${shortDate(d.required_by)}`}</Status></div>)}</div>}</Panel>}
      {mode === 'emails' && <EmailQueue rows={comms.rows} loading={comms.loading} reload={() => void comms.refresh()} />}
      {mode === 'suppliers' && <Panel title="Supplier comparison" flush>{sup.loading ? <Skeleton h={160} /> : <div style={{ overflow: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}><thead><tr className="dim" style={{ textAlign: 'left' }}>{['Supplier', 'Lead time', 'Delivery', 'Free delivery over', 'Minimum order', 'Reliability', 'Direct to producer', 'Email'].map((h) => <th key={h} style={{ padding: '10px 12px' }}>{h}</th>)}</tr></thead>
        <tbody>{sup.rows.map((s) => <tr key={s.id} style={{ borderTop: '1px solid var(--border)' }}><td style={{ padding: '8px 12px' }}><b>{s.name}</b></td><td className="num" style={{ padding: '8px 12px' }}>{s.lead_time_days} d</td><td className="num" style={{ padding: '8px 12px' }}>{money(s.delivery_cost, 2)}</td><td className="num" style={{ padding: '8px 12px' }}>{s.free_delivery_over ? money(s.free_delivery_over) : '—'}</td><td className="num" style={{ padding: '8px 12px' }}>{s.min_order_value ? money(s.min_order_value) : '—'}</td><td className="num" style={{ padding: '8px 12px' }}>{s.on_time_rate != null ? Math.round(s.on_time_rate) + '% on time' : <span className="dim">no record yet</span>}</td><td style={{ padding: '8px 12px' }}>{s.can_deliver_to_producer ? 'Yes' : 'No'}</td><td style={{ padding: '8px 12px' }}>{s.email ?? <span className="warn">missing</span>}</td></tr>)}</tbody></table>
        <p className="dim" style={{ padding: 12 }}>Per-SKU prices, margin impact and risk are compared per order: open an order → Purchasing → Compare options.</p></div>}</Panel>}
      {open && <PoDrawer id={open} onClose={() => navigate('purchasing')} />}
    </div>
  );
}

function EmailQueue({ rows, loading, reload }: { rows: CommRow[]; loading: boolean; reload: () => void }) {
  const { canAct } = useCtx(); const toast = useToast();
  const act = async (id: string, action: string) => { const r = await exceptionActionTo('purchasing', action, { communication_id: id }); toast.push(r.ok === false ? { tone: 'bad', title: 'Could not do that', body: String(r.error) } : { tone: 'good', title: action === 'comm_approve' ? 'Approved: it will be sent shortly' : 'Cancelled' }); reload(); };
  const pending = rows.filter((c) => ['pending_review', 'draft', 'failed', 'approved', 'sending'].includes(c.status));
  return <Panel title="Outgoing emails waiting for you" flush>{loading ? <Skeleton h={120} /> : pending.length === 0 ? <EmptyState icon="check" title="No emails waiting">Supplier emails appear here for review before they are sent.</EmptyState> :
    pending.map((c) => <div key={c.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}><span className="mono dim">{c.comm_ref}</span><span className="grow"><b>{c.subject}</b><br /><span className="dim">To {c.to_addresses.join(', ') || 'nobody (add an email to the supplier)'} · {c.supplier_name}</span>{c.error && <><br /><span className="bad">{c.error}</span></>}</span><Status tone={c.status === 'failed' ? 'critical' : 'medium'}>{c.status.replace('_', ' ')}</Status>
      {canAct && <><Button size="sm" variant="good" disabled={c.to_addresses.length === 0} onClick={() => void act(c.id, 'comm_approve')}>Approve & send</Button><Button size="sm" onClick={() => void act(c.id, 'comm_cancel')}>Cancel</Button></>}</div>)}</Panel>;
}

function PoDrawer({ id, onClose }: { id: string; onClose: () => void }) {
  const pos = useView<PoRow>('ui_purchase_orders'), lines = useView<PoLineRow>('ui_po_lines'), disc = useView<SupplierDiscRow>('ui_supplier_discrepancies'), comms = useView<CommRow>('ui_communications');
  const { canAct, senior } = useCtx(); const toast = useToast(); const [busy, setBusy] = useState(false); const [ack, setAck] = useState(false); const [date, setDate] = useState(''); const [cancelWhy, setCancelWhy] = useState(''); const [cancel, setCancel] = useState(false);
  const p = pos.rows.find((x) => x.po_id === id) ?? null; const my = useMemo(() => lines.rows.filter((l) => l.po_id === id).sort((a, b) => a.line_no - b.line_no), [lines.rows, id]);
  if (!p) return <Drawer open onClose={onClose} title="Purchase order">{pos.loading ? <Skeleton h={120} /> : <EmptyState icon="search" title="Purchase order not found" />}</Drawer>;
  const mine = p.origin === 'atam_flow';
  const run = async (action: string, params: Record<string, unknown>, ok: string) => { setBusy(true); const r = await exceptionActionTo('purchasing', action, { po_id: id, ...params }); setBusy(false); toast.push(r.ok === false ? { tone: 'bad', title: 'Did not work', body: String(r.error) } : { tone: 'good', title: ok, body: String(r.note ?? '') }); if (r.ok !== false) { void pos.refresh(); setAck(false); setCancel(false); } };
  return (
    <Drawer open onClose={onClose} wide title={<span className="row wrap" style={{ gap: 10 }}><span className="mono">{p.po_ref}</span><Status tone={poTone(p.po_status)}>{p.po_status ? PO_STATUS_LABEL[p.po_status] : p.delivery_status}</Status>{p.is_late && <Status tone="critical">{p.days_late}d late</Status>}</span>} subtitle={`${p.supplier ?? ''} · ${mine ? 'ATAM_FLOW PO' : 'DecoNetwork PO'}`}>
      <div className="stack" style={{ gap: 16 }}>
        <Facts items={[['Ordered', shortDate(p.po_date)], ['Required by', shortDate(p.required_by)], ['Expected', shortDate(p.expected_date)], ['Delivered', shortDate(p.actual_delivery)], ['Deliver to', p.deliver_to], ['Payment', p.payment_status.replace('_', ' ')], ['Subtotal', money(p.subtotal, 2)], ['Total', money(p.total_cost, 2)], ['Units', `${p.units_received}/${p.units_ordered} received`]]} />
        {mine && canAct && <div className="row wrap">
          {p.po_status === 'draft' && senior && <Button variant="primary" disabled={busy} onClick={() => void run('approve_po', {}, 'PO approved')}>Approve</Button>}
          {p.po_status === 'approved' && <Button variant="primary" disabled={busy} onClick={() => void run('send_po', {}, 'Email queued: approve it under Emails')}>Prepare email to supplier</Button>}
          {['sent', 'acknowledged'].includes(p.po_status ?? '') && <Button disabled={busy} onClick={() => setAck(true)}>Record acknowledgement</Button>}
          {['draft', 'approved', 'sent', 'acknowledged'].includes(p.po_status ?? '') && senior && <Button variant="danger" onClick={() => setCancel(true)}>Cancel PO</Button>}
          <span className="dim">Book deliveries in on the <a href="#/goods-in">Goods in</a> page.</span></div>}
        <section><h3>Lines</h3>{my.length === 0 ? <p className="dim">No line detail.</p> : <div style={{ overflow: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}><thead><tr className="dim" style={{ textAlign: 'left' }}>{['SKU', 'Product', 'Ordered', 'Received', 'Outstanding', 'Short', 'Damaged', 'Unit cost', 'Line total'].map((h) => <th key={h} style={{ padding: '6px 8px' }}>{h}</th>)}</tr></thead>
          <tbody>{my.map((l) => <tr key={l.id} style={{ borderTop: '1px solid var(--border)' }}><td className="mono" style={{ padding: '6px 8px' }}><a href={href('stock/' + encodeURIComponent(l.sku ?? ''))}>{l.sku}</a></td><td style={{ padding: '6px 8px' }}>{l.product_name}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_expected}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_received}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_outstanding}</td><td className={`num ${l.qty_short ? 'bad' : 'dim'}`} style={{ padding: '6px 8px' }}>{l.qty_short}</td><td className={`num ${l.qty_damaged ? 'bad' : 'dim'}`} style={{ padding: '6px 8px' }}>{l.qty_damaged}</td><td className="num" style={{ padding: '6px 8px' }}>{money(l.unit_cost, 2)}</td><td className="num" style={{ padding: '6px 8px' }}>{money(l.line_total, 2)}</td></tr>)}</tbody></table></div>}</section>
        <section className="stack"><h3>Linked orders</h3><OrderTags refs={p.source_orders} max={20} />{!(p.source_orders ?? []).length && <p className="dim">DecoNetwork POs do not record which orders they are for.</p>}</section>
        {disc.rows.filter((d) => d.po_ref === p.po_ref).length > 0 && <section className="stack"><h3>Discrepancies</h3>{disc.rows.filter((d) => d.po_ref === p.po_ref).map((d) => <div key={d.id} className="callout soft"><b>{d.disc_ref} · {d.disc_type}</b>{d.qty} × {d.sku} · reply by {shortDate(d.required_by)}</div>)}</section>}
        {comms.rows.filter((c) => c.entity_id === id).length > 0 && <section className="stack"><h3>Emails</h3>{comms.rows.filter((c) => c.entity_id === id).map((c) => <div key={c.id} className="row" style={{ justifyContent: 'space-between' }}><span>{c.subject}</span><Status>{c.status.replace('_', ' ')}</Status><span className="dim">{dateTime(c.created_at)}</span></div>)}</section>}
      </div>
      <Modal open={ack} onClose={() => setAck(false)} title="Record acknowledgement"><div className="stack"><label className="field">Supplier's confirmed delivery date<input type="date" className="input" value={date} onChange={(e) => setDate(e.target.value)} /></label><Button variant="primary" disabled={busy} onClick={() => void run('acknowledge_po', { expected_delivery: date || undefined }, 'Acknowledged')}>Save</Button></div></Modal>
      <Modal open={cancel} onClose={() => setCancel(false)} title="Cancel purchase order"><div className="stack"><label className="field">Reason (required)<textarea className="textarea" rows={3} value={cancelWhy} onChange={(e) => setCancelWhy(e.target.value)} /></label><Button variant="danger" disabled={!cancelWhy.trim() || busy} onClick={() => void run('cancel_po', { reason: cancelWhy }, 'PO cancelled')}>Cancel this PO</Button></div></Modal>
    </Drawer>
  );
}
