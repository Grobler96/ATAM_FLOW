import { useMemo } from 'react';
import { Panel, Status, EmptyState, Facts, Tag, Skeleton } from '../ui/primitives';
import { Drawer } from '../ui/overlay';
import { DataTable, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { dateTime } from '../lib/format';
import { PO_STATUS_LABEL, shortDate } from '../lib/domain';
import { Num, OrderLink } from '../components/common';
import type { HeldRow, OrderLineRow, OrderRow, PoLineRow, PoRow, StockRow, SupplierDiscRow } from '../data/types';

interface StockVM extends StockRow { atProducer: number; inTransit: number; short: boolean }
interface MoveRow { id: number; at: string; sku: string; movement_type: string; qty: number; ref_type: string | null; ref_id: string | null; note: string | null }

export function StockPage({ route }: { route: Route }) {
  const stock = useView<StockRow>('ui_stock'), held = useView<HeldRow>('ui_producer_held_stock'), disc = useView<SupplierDiscRow>('ui_supplier_discrepancies'), shortages = useView<{ sku: string; units_short: number }>('ui_shortages');
  const rows = useMemo<StockVM[]>(() => {
    const at = new Map<string, number>(), tr = new Map<string, number>();
    for (const h of held.rows) { if (!h.sku) continue; const m = ['in_transit_to_producer', 'in_transit_back'].includes(h.location_state) ? tr : at; m.set(h.sku, (m.get(h.sku) ?? 0) + h.qty); }
    const sh = new Set(shortages.rows.map((s) => s.sku));
    return stock.rows.filter((s) => !s.is_placeholder || s.qty_on_hand || s.qty_incoming || sh.has(s.sku)).map((s) => ({ ...s, atProducer: at.get(s.sku) ?? 0, inTransit: tr.get(s.sku) ?? 0, short: sh.has(s.sku) }));
  }, [stock.rows, held.rows, shortages.rows]);
  const discSkus = useMemo(() => new Set(disc.rows.map((d) => d.sku)), [disc.rows]);
  const views: ViewDef<StockVM>[] = [{ id: 'all', label: 'All stock', test: () => true }, { id: 'low', label: 'Low stock', test: (s) => s.is_low_stock && !s.is_out_of_stock }, { id: 'out', label: 'Out of stock', test: (s) => s.is_out_of_stock },
    { id: 'short', label: 'Short for orders', test: (s) => s.short }, { id: 'incoming', label: 'Incoming', test: (s) => s.qty_incoming > 0 }, { id: 'producers', label: 'At producers', test: (s) => s.atProducer + s.inTransit > 0 },
    { id: 'reserved', label: 'Reserved', test: (s) => s.qty_reserved > 0 }, { id: 'disc', label: 'Discrepancies', test: (s) => discSkus.has(s.sku) }];
  const filters: FilterDef<StockVM>[] = [
    { id: 'type', label: 'Garment', options: [...new Set(rows.map((r) => r.garment_type).filter(Boolean) as string[])].sort().map((v) => ({ value: v, label: v })), test: (s, v) => s.garment_type === v },
    { id: 'colour', label: 'Colour', options: [...new Set(rows.map((r) => r.colour).filter(Boolean) as string[])].sort().map((v) => ({ value: v, label: v })), test: (s, v) => s.colour === v },
    { id: 'size', label: 'Size', options: [...new Set(rows.map((r) => r.size).filter(Boolean) as string[])].sort().map((v) => ({ value: v, label: v })), test: (s, v) => s.size === v }
  ];
  const cols: Column<StockVM>[] = [
    { id: 'sku', header: 'SKU', width: '190px', render: (s) => <b className="mono">{s.sku}</b>, sort: (s) => s.sku, csv: (s) => s.sku },
    { id: 'product', header: 'Product', width: '260px', render: (s) => <span title={s.product_name ?? ''}>{s.product_name ?? '—'}</span>, sort: (s) => s.product_name?.toLowerCase() ?? null, csv: (s) => s.product_name },
    { id: 'colour', header: 'Colour', width: '110px', render: (s) => s.colour ?? '—', sort: (s) => s.colour, csv: (s) => s.colour }, { id: 'size', header: 'Size', width: '64px', render: (s) => s.size ?? '—', sort: (s) => s.size, csv: (s) => s.size },
    { id: 'avail', header: 'Available', width: '90px', align: 'r', render: (s) => <span className={`num ${s.qty_available === 0 ? 'bad' : ''}`}>{s.qty_available}</span>, sort: (s) => s.qty_available, csv: (s) => s.qty_available },
    { id: 'res', header: 'Reserved', width: '88px', align: 'r', render: (s) => <Num v={s.qty_reserved} dim0 />, sort: (s) => s.qty_reserved, csv: (s) => s.qty_reserved },
    { id: 'hand', header: 'On hand', width: '84px', align: 'r', render: (s) => <Num v={s.qty_on_hand} />, sort: (s) => s.qty_on_hand, csv: (s) => s.qty_on_hand },
    { id: 'transit', header: 'In transit', width: '84px', align: 'r', render: (s) => <Num v={s.inTransit} dim0 />, sort: (s) => s.inTransit, csv: (s) => s.inTransit },
    { id: 'prod', header: 'At producer', width: '96px', align: 'r', render: (s) => <Num v={s.atProducer} dim0 />, sort: (s) => s.atProducer, csv: (s) => s.atProducer },
    { id: 'inc', header: 'Incoming', width: '84px', align: 'r', render: (s) => <Num v={s.qty_incoming} dim0 />, sort: (s) => s.qty_incoming, csv: (s) => s.qty_incoming },
    { id: 'next', header: 'Next due', width: '90px', render: (s) => <span className="dim">{shortDate(s.next_expected)}</span>, sort: (s) => s.next_expected, csv: (s) => s.next_expected },
    { id: 'min', header: 'Min', width: '64px', align: 'r', render: (s) => <Num v={s.min_threshold} dim0 />, sort: (s) => s.min_threshold, csv: (s) => s.min_threshold },
    { id: 'flag', header: 'Status', width: '120px', render: (s) => s.is_out_of_stock ? <Status tone="critical">Out</Status> : s.is_low_stock ? <Status tone="high">Low</Status> : s.short ? <Status tone="medium">Short</Status> : <Status tone="good" plain>OK</Status>, csv: (s) => (s.is_out_of_stock ? 'out' : s.is_low_stock ? 'low' : '') },
    { id: 'loc', header: 'Location', width: '110px', render: (s) => <span className="mono dim">{s.storage_location ?? '—'}</span>, csv: (s) => s.storage_location },
    { id: 'sync', header: 'Last synced', width: '120px', render: (s) => <span className="dim">{s.last_synced_at ? dateTime(s.last_synced_at) : '—'}</span>, sort: (s) => s.last_synced_at, csv: (s) => s.last_synced_at }
  ];
  const open = route.path[1] ? decodeURIComponent(route.path[1]) : null;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Stock</h1><p>Every SKU, where it is and who holds it. “Available” already counts goods booked in here that DecoNetwork has not recorded yet.</p></div></div>
      <Panel flush><DataTable<StockVM> rows={rows} columns={cols} rowKey={(s) => s.stock_item_id} loading={stock.loading} error={stock.error} onRetry={() => void stock.refresh()} views={views} filters={filters} storageKey="stock" exportName="stock"
        searchText={(s) => [s.sku, s.product_name, s.colour, s.size, s.garment_type, s.storage_location].join(' ')} searchPlaceholder="Search SKU, product, colour, size…" onRowClick={(s) => navigate('stock/' + encodeURIComponent(s.sku))}
        activeKey={open ? rows.find((s) => s.sku === open)?.stock_item_id : null} rowTone={(s) => (s.is_out_of_stock ? 'high' : '')} defaultSort={{ col: 'sku', dir: 1 }} initial={tableStateFromQuery(route)} /></Panel>
      {open && <StockDrawer sku={open} rows={rows} onClose={() => navigate('stock')} />}
    </div>
  );
}

function StockDrawer({ sku, rows, onClose }: { sku: string; rows: StockVM[]; onClose: () => void }) {
  const s = rows.find((x) => x.sku === sku) ?? null;
  const moves = useView<MoveRow>('ui_stock_movements', { limit: 2000 }), poLines = useView<PoLineRow>('ui_po_lines'), pos = useView<PoRow>('ui_purchase_orders'), lines = useView<OrderLineRow>('ui_order_lines'), orders = useView<OrderRow>('ui_orders');
  const held = useView<HeldRow>('ui_producer_held_stock'), disc = useView<SupplierDiscRow>('ui_supplier_discrepancies');
  if (!s) return <Drawer open onClose={onClose} title={sku}>{rows.length === 0 ? <Skeleton h={120} /> : <EmptyState title="SKU not found" icon="search" />}</Drawer>;
  const mv = moves.rows.filter((m) => m.sku === sku).sort((a, b) => b.at.localeCompare(a.at)).slice(0, 25);
  const incoming = poLines.rows.filter((l) => l.sku === sku && l.qty_outstanding > 0).map((l) => ({ l, po: pos.rows.find((p) => p.po_id === l.po_id) })).filter((x) => x.po && x.po.po_status !== 'cancelled');
  const need = lines.rows.filter((l) => l.sku === sku && l.qty_required - l.qty_produced > 0).map((l) => ({ l, o: orders.rows.find((o) => o.id === l.order_id) })).filter((x) => x.o && x.o.order_status !== 'dispatched');
  const hs = held.rows.filter((h) => h.sku === sku), ds = disc.rows.filter((d) => d.sku === sku);
  const demand = need.reduce((t, x) => t + (x.l.qty_required - x.l.qty_produced), 0); const uncovered = Math.max(0, demand - s.qty_on_hand - s.qty_incoming);
  const reorder = uncovered > 0 ? Math.max(uncovered, s.reorder_qty ?? 0) : s.is_low_stock ? (s.reorder_qty ?? 0) : 0;
  return (
    <Drawer open onClose={onClose} wide title={<span className="mono">{s.sku}</span>} subtitle={[s.product_name, s.colour, s.size].filter(Boolean).join(' · ')}>
      <div className="stack" style={{ gap: 16 }}>
        <Facts items={[['Available', <b key="a" className="num">{s.qty_available}</b>], ['On hand (incl. booked in here)', s.qty_on_hand], ['Reserved', s.qty_reserved], ['Incoming', s.qty_incoming], ['Next expected', shortDate(s.next_expected)], ['At producers', s.atProducer], ['In transit', s.inTransit],
          ['Minimum', s.min_threshold], ['Location', s.storage_location], ['DecoNetwork on hand', s.qty_on_hand - s.qty_pending_receipt], ['Booked in here, not yet in DecoNetwork', s.qty_pending_receipt], ['Last synced', s.last_synced_at ? dateTime(s.last_synced_at) : '—']]} />
        <div className="callout"><b>Reorder recommendation</b>{reorder > 0 ? <span>Buy about <b className="num">{reorder}</b> unit(s){uncovered > 0 ? `: orders need ${demand}, with ${s.qty_on_hand} on hand and ${s.qty_incoming} incoming` : ': stock is below its minimum'}. Create a PO from Orders → select the waiting orders → Create PO.</span> : <span className="muted">No purchase needed: demand is covered.</span>}</div>
        <section className="stack"><h3>Orders that need it ({need.length})</h3>{need.length === 0 ? <p className="dim">No open order needs this SKU.</p> : need.map(({ l, o }) => <div key={l.id} className="row" style={{ justifyContent: 'space-between' }}><OrderLink r={o!.order_ref} /><span className="muted">{o!.customer_name}</span><span className="num">{l.qty_required - l.qty_produced} needed · {l.qty_allocated_on_hand + l.qty_allocated_incoming} reserved</span></div>)}</section>
        <section className="stack"><h3>Incoming purchase orders ({incoming.length})</h3>{incoming.length === 0 ? <p className="dim">Nothing on order.</p> : incoming.map(({ l, po }) => <div key={l.id} className="row" style={{ justifyContent: 'space-between' }}><a className="mono" href={href('purchasing/' + po!.po_id)}>{po!.po_ref}</a><span className="muted">{po!.supplier}</span><Status tone={po!.is_late ? 'critical' : 'info'}>{po!.po_status ? PO_STATUS_LABEL[po!.po_status] : po!.delivery_status}</Status><span className="num">{l.qty_outstanding} due {shortDate(l.expected_date ?? po!.expected_date)}</span></div>)}</section>
        {hs.length > 0 && <section className="stack"><h3>Held by producers</h3>{hs.map((h, i) => <div key={i} className="row" style={{ justifyContent: 'space-between' }}><span>{h.producer_name}</span><Tag>{h.location_state.replace(/_/g, ' ')}</Tag><span className="num">{h.qty}</span></div>)}</section>}
        {ds.length > 0 && <section className="stack"><h3>Open supplier discrepancies</h3>{ds.map((d) => <div key={d.id} className="row" style={{ justifyContent: 'space-between' }}><span className="mono">{d.disc_ref}</span><span>{d.disc_type} · {d.qty} on {d.po_ref}</span><Status tone={d.is_overdue ? 'critical' : 'medium'}>{d.is_overdue ? 'Overdue' : 'Open'}</Status></div>)}</section>}
        <section className="stack"><h3>Stock movements</h3>{mv.length === 0 ? <p className="dim">No movements recorded for this SKU yet.</p> : <ul className="timeline">{mv.map((m) => <li key={m.id}><b style={{ textTransform: 'capitalize' }}>{m.movement_type.replace(/_/g, ' ')}</b> <span className={m.qty < 0 ? 'bad' : 'good'}>{m.qty > 0 ? '+' : ''}{m.qty}</span><span className="dim"> · {dateTime(m.at)}</span>{m.note && <div className="muted">{m.note}</div>}</li>)}</ul>}</section>
        <p className="dim">Alternative SKUs and supplier price history arrive with approved alternatives and supplier price lists.</p>
      </div>
    </Drawer>
  );
}
