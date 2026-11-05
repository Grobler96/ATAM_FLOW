import { useEffect, useMemo, useState } from 'react';
import { Button, EmptyState, Facts, Panel, Progress, Segmented, Status, Field } from '../ui/primitives';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { supabase } from '../lib/api';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { whAction } from '../lib/warehouse';
import { dateTime } from '../lib/format';
import { Num, OrderLink, OrderTags } from '../components/common';
import { CreateBinsDialog, PutAwayDialog, ReasonDialog } from '../components/WarehouseDialogs';
import { GenerateLabelsDialog } from '../components/GenerateLabelsDialog';
import type { BinAssignRow, BinRow, CustodyRow, OrderToBinRow, StockLocRow } from '../data/types';

interface Hit { kind: string; id: string; label: string; sub: string; route: string }
const binTone = (s: string) => (s === 'available' ? 'good' : s === 'needs_emptying' ? 'critical' : s === 'full' ? 'high' : s === 'reserved' ? 'medium' : 'info') as 'good' | 'critical' | 'high' | 'medium' | 'info';

export function WarehousePage({ route }: { route: Route }) {
  const bins = useView<BinRow>('ui_bins'); const cust = useView<CustodyRow>('ui_custody'); const toBin = useView<OrderToBinRow>('ui_orders_to_bin'); const { canAct } = useCtx();
  const [mode, setMode] = useState<'bins' | 'stock'>('bins'); const [dlg, setDlg] = useState<null | 'create' | 'putaway' | 'labels'>(null); const [putOrder, setPutOrder] = useState<string | undefined>();
  const open = route.path[1] ? decodeURIComponent(route.path[1]) : route.query.get('bin');
  const views: ViewDef<BinRow>[] = [{ id: 'all', label: 'All bins', test: (b) => b.is_active }, { id: 'used', label: 'In use', test: (b) => b.is_active && b.units_in_bin > 0 }, { id: 'empty', label: 'Empty', test: (b) => b.is_active && b.units_in_bin === 0 && b.status !== 'needs_emptying' },
    { id: 'attention', label: 'Needs attention', test: (b) => b.is_active && (b.status === 'needs_emptying' || b.status === 'full') }, { id: 'nolabel', label: 'Label not printed', test: (b) => b.is_active && !b.label_printed }, { id: 'retired', label: 'Retired', test: (b) => !b.is_active }];
  const cols: Column<BinRow>[] = [
    { id: 'code', header: 'Bin', width: '120px', render: (b) => <b className="mono">{b.bin_code}</b>, sort: (b) => b.bin_code, csv: (b) => b.bin_code }, { id: 'zone', header: 'Zone', width: '150px', render: (b) => b.zone_name ?? b.zone_code ?? '—', sort: (b) => b.zone_code, csv: (b) => b.zone_code },
    { id: 'type', header: 'Type', width: '110px', render: (b) => b.location_type.replace(/_/g, ' '), csv: (b) => b.location_type }, { id: 'status', header: 'Status', width: '140px', render: (b) => <Status tone={binTone(b.status)}>{b.is_active ? b.status.replace(/_/g, ' ') : 'retired'}</Status>, csv: (b) => b.status },
    { id: 'units', header: 'Units', width: '80px', align: 'r', render: (b) => <Num v={b.units_in_bin} dim0 />, sort: (b) => b.units_in_bin, csv: (b) => b.units_in_bin }, { id: 'cap', header: 'Capacity', width: '150px', render: (b) => b.capacity_units ? <div style={{ width: 110 }}><Progress value={(b.units_in_bin / b.capacity_units) * 100} /></div> : <span className="dim">No limit</span>, csv: (b) => b.capacity_units },
    { id: 'orders', header: 'Orders', width: '260px', render: (b) => <OrderTags refs={b.order_refs} max={3} />, csv: (b) => b.order_refs }, { id: 'label', header: 'Label', width: '110px', render: (b) => (b.label_printed ? <Status tone="good" plain>Printed</Status> : <Status tone="medium" plain>Not printed</Status>), csv: (b) => b.label_printed }
  ];
  const noBin = cust.rows.filter((c) => ['returned_to_warehouse', 'ready_for_dispatch', 'in_warehouse'].includes(c.location_state)).reduce((t, c) => t + c.qty, 0);
  const b = open ? bins.rows.find((x) => x.bin_code === open) : null;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Warehouse / Bins</h1><p>Where every order’s garments sit in the building. {toBin.rows.length > 0 ? `${toBin.rows.length} order(s) have no bin yet. ` : ''}{noBin > 0 ? `${noBin} unit(s) are recorded in the warehouse with no bin.` : ''}</p></div>
        <div className="row wrap"><Segmented label="Warehouse section" value={mode} options={[{ id: 'bins', label: 'Bins' }, { id: 'stock', label: 'Stock locations' }]} onChange={setMode} />
          <Button icon="plus" disabled={!canAct} onClick={() => { setPutOrder(undefined); setDlg('putaway'); }} title={canAct ? '' : 'Your role cannot change bins'}>Put order away</Button><Button icon="warehouse" disabled={!canAct} onClick={() => setDlg('create')}>Create bins</Button><Button icon="labels" disabled={!canAct} onClick={() => setDlg('labels')}>Labels</Button></div></div>
      <FindBox />
      {mode === 'bins' && toBin.rows.length > 0 && <Panel title="Orders waiting for a bin" count={toBin.rows.length} icon="orders"><div className="stack" style={{ gap: 4 }}>{toBin.rows.slice(0, 8).map((o) => <div key={o.order_id} className="row" style={{ gap: 12 }}><OrderLink r={o.order_ref} /><span className="muted grow">{o.customer_name} · {o.total_units} units · {o.order_status.replace(/_/g, ' ')}</span><Button size="sm" disabled={!canAct} onClick={() => { setPutOrder(o.order_id); setDlg('putaway'); }}>Put away</Button></div>)}{toBin.rows.length > 8 && <span className="dim">+{toBin.rows.length - 8} more. Use “Put order away” to pick any of them.</span>}</div></Panel>}
      {mode === 'bins' && <Panel flush><DataTable<BinRow> rows={bins.rows} columns={cols} rowKey={(x) => x.bin_id} loading={bins.loading} error={bins.error} onRetry={() => void bins.refresh()} views={views} storageKey="bins" exportName="bins" searchText={(x) => [x.bin_code, x.zone_name, (x.order_refs ?? []).join(' ')].join(' ')} searchPlaceholder="Search bin ID or order…"
        onRowClick={(x) => navigate('warehouse/' + encodeURIComponent(x.bin_code))} activeKey={b?.bin_id} defaultSort={{ col: 'code', dir: 1 }} initial={tableStateFromQuery(route)}
        empty={<EmptyState icon="warehouse" title="No bins set up yet" action={canAct ? <Button variant="primary" onClick={() => setDlg('create')}>Create bins</Button> : undefined}>Create bins by zone (receiving, staging, work in progress, dispatch). Then put orders away in them and print a label for each bin.</EmptyState>} /></Panel>}
      {mode === 'stock' && <StockLocations canAct={canAct} />}
      {open && <BinDrawer code={open} bin={b ?? null} canAct={canAct} onClose={() => navigate('warehouse')} onPutAway={() => { setPutOrder(undefined); setDlg('putaway'); }} />}
      {dlg === 'create' && <CreateBinsDialog onClose={() => setDlg(null)} />}{dlg === 'putaway' && <PutAwayDialog orderId={putOrder} binCode={!putOrder && open ? open : undefined} onClose={() => setDlg(null)} />}{dlg === 'labels' && <GenerateLabelsDialog open presetType="bin" onClose={() => setDlg(null)} />}
    </div>
  );
}

// Search anything physical: bin, order, customer, SKU, producer movement, label code.
function FindBox() {
  const [q, setQ] = useState(''); const [hits, setHits] = useState<Hit[]>([]); const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (q.trim().length < 2) { setHits([]); return; } setBusy(true); let live = true;
    const t = setTimeout(() => { void supabase.rpc('ui_wh_find', { p_q: q }).then(({ data }) => { if (live) { setHits((data ?? []) as Hit[]); setBusy(false); } }); }, 250);
    return () => { live = false; clearTimeout(t); };
  }, [q]);
  return (<div className="stack" style={{ gap: 6 }}>
    <input className="input" aria-label="Find in the warehouse" placeholder="Find a bin, order, customer, SKU, producer movement or label code…" value={q} onChange={(e) => setQ(e.target.value)} />
    {q.trim().length >= 2 && <Panel flush>{hits.length === 0 ? <p className="dim" style={{ padding: 12 }}>{busy ? 'Searching…' : 'Nothing found.'}</p> : <ul className="plain" style={{ margin: 0 }}>{hits.map((h, i) => <li key={h.kind + h.id + i}><a className="row" style={{ padding: '8px 12px', gap: 12 }} href={h.route}><Status tone="info" plain>{h.kind}</Status><b className="mono">{h.label}</b><span className="dim">{h.sub}</span></a></li>)}</ul>}</Panel>}
  </div>);
}

function BinDrawer({ code, bin, canAct, onClose, onPutAway }: { code: string; bin: BinRow | null; canAct: boolean; onClose: () => void; onPutAway: () => void }) {
  const asg = useView<BinAssignRow>('ui_bin_assignments'); const [act, setAct] = useState<null | { kind: 'release'; order?: BinAssignRow } | { kind: 'empty' } | { kind: 'status'; status: string } | { kind: 'move'; order: BinAssignRow }>(null); const [gen, setGen] = useState(false);
  const mine = asg.rows.filter((a) => a.bin_code === code); const live = mine.filter((a) => a.is_active); const past = mine.filter((a) => !a.is_active).sort((a, b) => (b.released_at ?? '').localeCompare(a.released_at ?? '')).slice(0, 10);
  const [dest, setDest] = useState('');
  return (
    <Drawer open onClose={onClose} title={<span className="mono">{code}</span>} subtitle={bin ? `${bin.zone_name ?? bin.zone_code ?? ''} · ${bin.location_type.replace(/_/g, ' ')}` : undefined}>
      {!bin ? <EmptyState icon="search" title="Bin not found" /> : <div className="stack">
        <Facts items={[['Status', <Status tone={binTone(bin.status)}>{bin.is_active ? bin.status.replace(/_/g, ' ') : 'retired'}</Status>], ['Units', bin.units_in_bin], ['Capacity', bin.capacity_units ?? 'No limit'], ['Free', bin.units_free ?? '—'], ['Label', bin.label_printed ? 'Printed' : 'Not printed'], ['Last activity', bin.last_activity ? dateTime(bin.last_activity) : '—']]} />
        <div className="row wrap"><Button size="sm" variant="primary" disabled={!canAct || !bin.is_active} onClick={onPutAway}>Put an order here</Button><Button size="sm" disabled={!canAct || live.length === 0} onClick={() => setAct({ kind: 'empty' })}>Empty bin</Button>
          <Button size="sm" disabled={!canAct} onClick={() => setAct({ kind: 'status', status: bin.status === 'needs_emptying' ? 'available' : 'needs_emptying' })}>{bin.status === 'needs_emptying' ? 'Mark emptied / available' : 'Flag: needs emptying'}</Button>
          <Button size="sm" disabled={!canAct} onClick={() => setGen(true)}>{bin.label_printed ? 'Reprint label…' : 'Make label'}</Button></div>
        <h3>In this bin now</h3>
        {live.length === 0 ? <p className="dim">Empty.</p> : live.map((a) => <div key={a.id} className="panel" style={{ padding: 10 }}><div className="row"><OrderLink r={a.order_ref} /><span className="muted grow">{a.customer_name} · {a.units} units · since {dateTime(a.assigned_at)}</span></div>
          {a.contents.length > 0 && <ul className="plain dim" style={{ margin: '6px 0 0' }}>{a.contents.map((c, i) => <li key={i}>{c.qty} × {c.sku} {[c.colour, c.size].filter(Boolean).join(' ')}</li>)}</ul>}
          <div className="row" style={{ marginTop: 8, gap: 8 }}><Button size="sm" disabled={!canAct} onClick={() => setAct({ kind: 'release', order: a })}>Release</Button><Button size="sm" disabled={!canAct} onClick={() => { setDest(''); setAct({ kind: 'move', order: a }); }}>Move…</Button></div></div>)}
        <h3>Recent history</h3>
        {past.length === 0 ? <p className="dim">Nothing released from this bin yet.</p> : <ul className="plain dim">{past.map((a) => <li key={a.id}>{a.order_ref} · {a.units} units · {dateTime(a.assigned_at)} → {a.released_at ? dateTime(a.released_at) : ''}</li>)}</ul>}
      </div>}
      {act?.kind === 'release' && act.order && <ReasonDialog title={`Release ${act.order.order_ref} from ${code}`} intro="The order stays in history; the bin becomes free for other work." confirm="Release" action="release_bin" params={{ bin_code: code, order_id: act.order.order_id }} presets={['Dispatched', 'Sent to producer', 'Moved elsewhere', 'Put in wrong bin']} onClose={() => { setAct(null); void refreshAll(); }} />}
      {act?.kind === 'empty' && <ReasonDialog title={`Empty ${code}`} intro="Releases every order in this bin. Use this when the bin has been physically cleared." confirm="Empty bin" action="release_bin" params={{ bin_code: code }} presets={['Bin cleared', 'Stock moved to dispatch', 'Cleaning']} onClose={() => { setAct(null); void refreshAll(); }} />}
      {act?.kind === 'status' && <ReasonDialog title={`${code}: ${act.status.replace(/_/g, ' ')}`} intro="Changes what the system will put in this bin." confirm="Update bin" action="set_bin_status" params={{ bin_code: code, status: act.status }} presets={act.status === 'available' ? ['Bin emptied'] : ['Spill / damaged', 'Needs sorting', 'Reorganising']} onClose={() => { setAct(null); void refreshAll(); }} />}
      {act?.kind === 'move' && <ReasonDialog title={`Move ${act.order.order_ref} out of ${code}`} intro="Choose the bin to move this order into. If that bin breaks a rule the move is refused; use Put order away to override." confirm="Move order" action="move_order" params={{ bin_code: code, order_id: act.order.order_id, from_bin: code, to_bin: dest }} presets={['Consolidating', 'Bin was full', 'Production needs it']} extra={<Field label="Move to bin"><input className="input mono" value={dest} onChange={(e) => setDest(e.target.value.toUpperCase())} placeholder="e.g. STG-02" /></Field>} onClose={() => { setAct(null); void refreshAll(); }} />}
      {gen && <GenerateLabelsDialog open presetType="bin" presetRefs={[code]} onClose={() => setGen(false)} />}
    </Drawer>
  );
}

function StockLocations({ canAct }: { canAct: boolean }) {
  const rows = useView<StockLocRow>('ui_stock_locations'); const [edit, setEdit] = useState<StockLocRow | null>(null); const [loc, setLoc] = useState(''); const toast = useToast();
  const cols: Column<StockLocRow>[] = [
    { id: 'sku', header: 'SKU', width: '190px', render: (s) => <b className="mono">{s.sku}</b>, sort: (s) => s.sku, csv: (s) => s.sku }, { id: 'p', header: 'Product', width: '240px', render: (s) => [s.product_name, s.colour, s.size].filter(Boolean).join(' · '), csv: (s) => s.product_name },
    { id: 'q', header: 'On hand', width: '90px', align: 'r', render: (s) => <Num v={s.qty_on_hand} dim0 />, sort: (s) => s.qty_on_hand, csv: (s) => s.qty_on_hand }, { id: 'l', header: 'Location', width: '180px', render: (s) => s.storage_location ?? <Status tone="medium" plain>Not set</Status>, sort: (s) => s.storage_location, csv: (s) => s.storage_location },
    { id: 'a', header: '', width: '90px', render: (s) => <Button size="sm" disabled={!canAct} onClick={(e) => { e.stopPropagation(); setEdit(s); setLoc(s.storage_location ?? ''); }}>Set</Button> }
  ];
  const views = useMemo<ViewDef<StockLocRow>[]>(() => [{ id: 'all', label: 'All stock', test: () => true }, { id: 'noloc', label: 'No location', test: (s) => !s.storage_location && s.qty_on_hand > 0 }], []);
  async function save() { if (!edit) return; const r = await whAction('set_stock_location', { sku: edit.sku, location: loc }); if (r.ok === false) { toast.push({ tone: 'bad', title: 'Could not save', body: String(r.error) }); return; } void refreshAll(); toast.push({ tone: 'good', title: `${edit.sku} location saved` }); setEdit(null); }
  return (<Panel flush><DataTable<StockLocRow> rows={rows.rows} columns={cols} rowKey={(s) => s.sku} loading={rows.loading} error={rows.error} onRetry={() => void rows.refresh()} views={views} defaultTab="noloc" storageKey="stock-locations" exportName="stock-locations" searchText={(s) => [s.sku, s.product_name, s.storage_location].join(' ')} searchPlaceholder="Search SKU or location…" defaultSort={{ col: 'sku', dir: 1 }}
    empty={<EmptyState icon="stock" title="No stock items">Stock appears here after the stock sync.</EmptyState>} />
    {edit && <Modal open onClose={() => setEdit(null)} title={`Location for ${edit.sku}`}><div className="stack"><Field label="Shelf / rack / area"><input className="input" value={loc} onChange={(e) => setLoc(e.target.value)} placeholder="e.g. Rack B3 shelf 2" /></Field><div className="row"><Button variant="primary" onClick={() => void save()}>Save</Button><Button variant="ghost" onClick={() => setEdit(null)}>Cancel</Button></div></div></Modal>}</Panel>);
}
