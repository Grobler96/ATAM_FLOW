import { Panel, Status, Chip, EmptyState } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { dateTime } from '../lib/format';
import type { LabelRow } from '../data/types';

export function LabelsPage() {
  const labels = useView<LabelRow>('ui_labels');
  const views: ViewDef<LabelRow>[] = [{ id: 'all', label: 'All labels', test: () => true }, { id: 'await', label: 'Awaiting print', test: (l) => l.print_status !== 'printed' }, { id: 'printed', label: 'Printed', test: (l) => l.print_status === 'printed' }, { id: 'reprint', label: 'Reprinted', test: (l) => l.print_count > 1 }];
  const cols: Column<LabelRow>[] = [
    { id: 'c', header: 'Label', width: '170px', render: (l) => <b className="mono">{l.label_code}</b>, sort: (l) => l.label_code, csv: (l) => l.label_code }, { id: 't', header: 'Type', width: '140px', render: (l) => l.label_type.replace(/_/g, ' '), csv: (l) => l.label_type },
    { id: 'o', header: 'Order', width: '110px', render: (l) => l.order_ref ?? '—', csv: (l) => l.order_ref }, { id: 'b', header: 'Bin', width: '110px', render: (l) => <span className="mono">{l.bin_code ?? '—'}</span>, csv: (l) => l.bin_code },
    { id: 's', header: 'Status', width: '130px', render: (l) => <Status tone={l.print_status === 'printed' ? 'good' : 'medium'}>{l.print_status.replace('_', ' ')}</Status>, csv: (l) => l.print_status }, { id: 'n', header: 'Prints', width: '70px', align: 'r', render: (l) => <span className="num">{l.print_count}</span>, csv: (l) => l.print_count },
    { id: 'by', header: 'Printed by', width: '160px', render: (l) => l.printed_by ?? '—', csv: (l) => l.printed_by }, { id: 'at', header: 'Printed', width: '140px', render: (l) => <span className="dim">{l.printed_at ? dateTime(l.printed_at) : '—'}</span>, sort: (l) => l.printed_at, csv: (l) => l.printed_at }
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Labels</h1><p>Order, bin, stock, producer-movement and dispatch labels, with a print audit trail.</p></div><div className="row">{['Order', 'Bin', 'Stock', 'Producer movement', 'Dispatch'].map((t) => <Chip key={t}>{t}</Chip>)}</div></div>
      <Panel flush><DataTable<LabelRow> rows={labels.rows} columns={cols} rowKey={(l) => l.id} loading={labels.loading} error={labels.error} onRetry={() => void labels.refresh()} views={views} storageKey="labels" exportName="labels" searchText={(l) => [l.label_code, l.order_ref, l.bin_code, l.label_type].join(' ')}
        empty={<EmptyState icon="labels" title="No labels generated yet">Label generation, QR / barcode preview and single or batch printing arrive with the label workflow. The data model for labels, print counts and reprint history is already in place.</EmptyState>} /></Panel>
    </div>
  );
}
