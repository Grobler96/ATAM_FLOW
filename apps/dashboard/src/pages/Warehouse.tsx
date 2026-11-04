import { EmptyState, Facts, Panel, Progress, Status } from '../ui/primitives';
import { Drawer } from '../ui/overlay';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { navigate, type Route } from '../router';
import { Num, OrderTags } from '../components/common';
import type { BinRow, CustodyRow } from '../data/types';

export function WarehousePage({ route }: { route: Route }) {
  const bins = useView<BinRow>('ui_bins'); const cust = useView<CustodyRow>('ui_custody'); const open = route.path[1] ? decodeURIComponent(route.path[1]) : null;
  const views: ViewDef<BinRow>[] = [{ id: 'all', label: 'All bins', test: () => true }, { id: 'used', label: 'In use', test: (b) => b.units_in_bin > 0 }, { id: 'empty', label: 'Empty', test: (b) => b.units_in_bin === 0 }, { id: 'nolabel', label: 'Label not printed', test: (b) => !b.label_printed }];
  const cols: Column<BinRow>[] = [
    { id: 'code', header: 'Bin', width: '120px', render: (b) => <b className="mono">{b.bin_code}</b>, sort: (b) => b.bin_code, csv: (b) => b.bin_code }, { id: 'zone', header: 'Zone', width: '150px', render: (b) => b.zone_name ?? b.zone_code ?? '—', sort: (b) => b.zone_code, csv: (b) => b.zone_code },
    { id: 'type', header: 'Type', width: '110px', render: (b) => b.location_type.replace(/_/g, ' '), csv: (b) => b.location_type }, { id: 'status', header: 'Status', width: '120px', render: (b) => <Status tone={b.status === 'available' ? 'good' : 'info'}>{b.status}</Status>, csv: (b) => b.status },
    { id: 'units', header: 'Units', width: '80px', align: 'r', render: (b) => <Num v={b.units_in_bin} dim0 />, sort: (b) => b.units_in_bin, csv: (b) => b.units_in_bin }, { id: 'cap', header: 'Capacity', width: '150px', render: (b) => b.capacity_units ? <div style={{ width: 110 }}><Progress value={(b.units_in_bin / b.capacity_units) * 100} /></div> : <span className="dim">—</span>, csv: (b) => b.capacity_units },
    { id: 'orders', header: 'Orders', width: '260px', render: (b) => <OrderTags refs={b.order_refs} max={3} />, csv: (b) => b.order_refs }, { id: 'label', header: 'Label', width: '110px', render: (b) => (b.label_printed ? <Status tone="good" plain>Printed</Status> : <Status tone="medium" plain>Not printed</Status>), csv: (b) => b.label_printed }
  ];
  const awaiting = cust.rows.filter((c) => ['returned_to_warehouse', 'ready_for_dispatch', 'in_warehouse'].includes(c.location_state)).reduce((t, c) => t + c.qty, 0);
  const b = open ? bins.rows.find((x) => x.bin_code === open) : null;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Warehouse / Bins</h1><p>Where garments sit in the building. {awaiting > 0 ? `${awaiting} unit(s) are recorded in the warehouse with no bin.` : ''}</p></div></div>
      <Panel flush><DataTable<BinRow> rows={bins.rows} columns={cols} rowKey={(x) => x.bin_id} loading={bins.loading} error={bins.error} onRetry={() => void bins.refresh()} views={views} storageKey="bins" exportName="bins" searchText={(x) => [x.bin_code, x.zone_name, (x.order_refs ?? []).join(' ')].join(' ')} searchPlaceholder="Search bin ID or order…"
        onRowClick={(x) => navigate('warehouse/' + encodeURIComponent(x.bin_code))} activeKey={b?.bin_id} defaultSort={{ col: 'code', dir: 1 }}
        empty={<EmptyState icon="warehouse" title="No bins set up yet">Create bins by zone (receiving, staging, work-in-progress, dispatch) and orders can be assigned to them, with a label for each. Bin creation and assignment screens come with the warehouse workflows.</EmptyState>} /></Panel>
      {open && <Drawer open onClose={() => navigate('warehouse')} title={<span className="mono">{open}</span>}>{b ? <div className="stack"><Facts items={[['Zone', b.zone_name ?? b.zone_code], ['Type', b.location_type.replace(/_/g, ' ')], ['Status', b.status], ['Units', b.units_in_bin], ['Free', b.units_free], ['Label', b.label_printed ? 'Printed' : 'Not printed']]} /><h3>Orders in this bin</h3><OrderTags refs={b.order_refs} max={30} /><p className="dim">Label reprint and release/empty actions arrive with the label and bin workflows.</p></div> : <EmptyState icon="search" title="Bin not found" />}</Drawer>}
    </div>
  );
}
