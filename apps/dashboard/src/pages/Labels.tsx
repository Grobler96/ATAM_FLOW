import { useMemo, useState } from 'react';
import { Panel, Status, EmptyState, Button, Segmented, Field } from '../ui/primitives';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { FORMAT_LABEL, labelTypeName, whAction, type PrintFormat } from '../lib/warehouse';
import { printLabels } from '../lib/labelPrint';
import { LabelPreview } from '../components/LabelPreview';
import { GenerateLabelsDialog } from '../components/GenerateLabelsDialog';
import { navigate, tableStateFromQuery, type Route } from '../router';
import type { LabelPrintRow, LabelRow } from '../data/types';

const statusTone = (s: string) => (s === 'printed' ? 'good' : s === 'failed' ? 'critical' : 'medium') as 'good' | 'critical' | 'medium';

export function LabelsPage({ route }: { route: Route }) {
  const labels = useView<LabelRow>('ui_labels'); const prints = useView<LabelPrintRow>('ui_label_prints'); const { canAct } = useCtx();
  const [mode, setMode] = useState<'labels' | 'audit'>('labels'); const [gen, setGen] = useState(false); const [printSel, setPrintSel] = useState<LabelRow[] | null>(null);
  const views: ViewDef<LabelRow>[] = [{ id: 'await', label: 'Awaiting print', test: (l) => l.print_status !== 'printed' }, { id: 'all', label: 'All labels', test: () => true }, { id: 'printed', label: 'Printed', test: (l) => l.print_status === 'printed' }, { id: 'reprint', label: 'Reprinted', test: (l) => l.print_count > 1 }, { id: 'failed', label: 'Failed', test: (l) => l.print_status === 'failed' }];
  const cols: Column<LabelRow>[] = [
    { id: 'c', header: 'Label', width: '190px', render: (l) => <b className="mono">{l.label_code}</b>, sort: (l) => l.label_code, csv: (l) => l.label_code }, { id: 't', header: 'Type', width: '150px', render: (l) => labelTypeName(l.label_type), csv: (l) => l.label_type },
    { id: 'o', header: 'Order', width: '100px', render: (l) => l.order_ref ?? '—', csv: (l) => l.order_ref }, { id: 'b', header: 'Bin / ref', width: '130px', render: (l) => <span className="mono">{l.bin_code ?? l.ref ?? '—'}</span>, csv: (l) => l.bin_code ?? l.ref },
    { id: 's', header: 'Status', width: '120px', render: (l) => <Status tone={statusTone(l.print_status)}>{l.print_status}</Status>, csv: (l) => l.print_status }, { id: 'v', header: 'Version', width: '70px', align: 'r', render: (l) => <span className="num">v{l.version}</span>, csv: (l) => l.version },
    { id: 'n', header: 'Prints', width: '64px', align: 'r', render: (l) => <span className="num">{l.print_count}</span>, csv: (l) => l.print_count },
    { id: 'by', header: 'Printed by', width: '150px', render: (l) => <span className="dim">{l.printed_by?.replace('dashboard:', '') ?? '—'}</span>, csv: (l) => l.printed_by }, { id: 'at', header: 'Printed', width: '130px', render: (l) => <span className="dim">{l.printed_at ? dateTime(l.printed_at) : '—'}</span>, sort: (l) => l.printed_at, csv: (l) => l.printed_at }
  ];
  const pcols: Column<LabelPrintRow>[] = [
    { id: 'at', header: 'When', width: '140px', render: (p) => dateTime(p.printed_at), sort: (p) => p.printed_at, csv: (p) => p.printed_at }, { id: 'c', header: 'Label', width: '190px', render: (p) => <b className="mono">{p.label_code}</b>, csv: (p) => p.label_code },
    { id: 't', header: 'Type', width: '140px', render: (p) => labelTypeName(p.label_type), csv: (p) => p.label_type }, { id: 'k', header: 'Kind', width: '100px', render: (p) => (p.is_reprint ? <Status tone="medium">Reprint</Status> : <Status tone="good" plain>First print</Status>), csv: (p) => (p.is_reprint ? 'reprint' : 'first') },
    { id: 'f', header: 'Paper', width: '90px', render: (p) => p.format ?? '—', csv: (p) => p.format }, { id: 'n', header: 'Copies', width: '70px', align: 'r', render: (p) => <span className="num">{p.copies}</span>, csv: (p) => p.copies },
    { id: 'by', header: 'By', width: '170px', render: (p) => p.printed_by?.replace('dashboard:', '') ?? '—', csv: (p) => p.printed_by }, { id: 'r', header: 'Reason', width: '260px', render: (p) => p.reason ?? <span className="dim">—</span>, csv: (p) => p.reason }
  ];
  const awaiting = labels.rows.filter((l) => l.print_status !== 'printed').length; const open = route.path[1] ? labels.rows.find((l) => l.label_code === decodeURIComponent(route.path[1])) : null;
  const bulk = [{ id: 'print', label: 'Print selected', icon: 'labels', run: canAct ? (r: LabelRow[]) => setPrintSel(r) : undefined, disabledReason: 'Your role cannot print labels' }];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Labels</h1><p>{awaiting} awaiting print · order, bin, stock, producer-movement, pick and dispatch labels, each with a QR code and barcode.</p></div>
        <div className="row"><Segmented label="Labels section" value={mode} options={[{ id: 'labels', label: 'Labels' }, { id: 'audit', label: `Print history (${prints.rows.length})` }]} onChange={setMode} /><Button variant="primary" icon="plus" disabled={!canAct} title={canAct ? '' : 'Your role cannot generate labels'} onClick={() => setGen(true)}>Generate labels</Button></div></div>
      {mode === 'labels' && <Panel flush><DataTable<LabelRow> rows={labels.rows} columns={cols} rowKey={(l) => l.id} loading={labels.loading} error={labels.error} onRetry={() => void labels.refresh()} views={views} storageKey="labels" exportName="labels" bulk={bulk}
        searchText={(l) => [l.label_code, l.order_ref, l.bin_code, l.ref, l.label_type].join(' ')} searchPlaceholder="Search label, order, bin, SKU…" onRowClick={(l) => navigate('labels/' + encodeURIComponent(l.label_code))} activeKey={open?.id} defaultSort={{ col: 'c', dir: 1 }} initial={tableStateFromQuery(route)} defaultTab="await"
        empty={<EmptyState icon="labels" title="No labels yet" action={canAct ? <Button variant="primary" onClick={() => setGen(true)}>Generate labels</Button> : undefined}>Choose what to label (orders, bins, stock, producer movements) and the labels appear here ready to print.</EmptyState>} /></Panel>}
      {mode === 'audit' && <Panel flush><DataTable<LabelPrintRow> rows={prints.rows} columns={pcols} rowKey={(p) => p.id} loading={prints.loading} error={prints.error} onRetry={() => void prints.refresh()} storageKey="label-prints" exportName="label-prints" searchText={(p) => [p.label_code, p.order_ref, p.printed_by, p.reason].join(' ')} defaultSort={{ col: 'at', dir: -1 }}
        empty={<EmptyState icon="labels" title="Nothing printed yet">Every print and reprint is recorded here with who, when, paper size and the reason for reprints.</EmptyState>} /></Panel>}
      {open && !printSel && <Drawer open onClose={() => navigate('labels')} title={<span className="mono">{open.label_code}</span>} subtitle={`${labelTypeName(open.label_type)} · v${open.version} · ${open.print_status}`}><LabelDrawer label={open} canAct={canAct} onPrint={() => setPrintSel([open])} /></Drawer>}
      {open === undefined && route.path[1] && <Drawer open onClose={() => navigate('labels')} title="Label"><EmptyState icon="search" title="Label not found" /></Drawer>}
      {gen && <GenerateLabelsDialog open onClose={() => setGen(false)} />}
      {printSel && <PrintDialog labels={printSel} onClose={() => setPrintSel(null)} />}
    </div>
  );
}

function LabelDrawer({ label, canAct, onPrint }: { label: LabelRow; canAct: boolean; onPrint: () => void }) {
  const [fmt, setFmt] = useState<PrintFormat>('thermal'); const prints = useView<LabelPrintRow>('ui_label_prints'); const mine = prints.rows.filter((p) => p.label_code === label.label_code).sort((a, b) => b.printed_at.localeCompare(a.printed_at));
  return (<div className="stack">
    <div className="row"><Segmented label="Paper" value={fmt} options={[{ id: 'thermal', label: '100 × 150 mm' }, { id: 'A4', label: 'A4' }]} onChange={setFmt} /><span className="grow" /><Button variant="primary" icon="labels" disabled={!canAct} onClick={onPrint}>{label.print_count > 0 ? 'Reprint…' : 'Print…'}</Button></div>
    <LabelPreview label={label} format={fmt} />
    <p className="dim">QR content: <span className="mono">{label.qr_payload ?? '—'}</span></p>
    <h3>Print history</h3>
    {mine.length === 0 ? <p className="dim">Not printed yet.</p> : <ul className="plain">{mine.map((p) => <li key={p.id}>{dateTime(p.printed_at)} · {p.printed_by?.replace('dashboard:', '')} · {p.format} × {p.copies}{p.is_reprint ? ` · reprint: ${p.reason ?? ''}` : ''}</li>)}</ul>}
  </div>);
}

// Opens the browser print dialog, then asks the person to confirm what happened so the audit trail is true.
function PrintDialog({ labels, onClose }: { labels: LabelRow[]; onClose: () => void }) {
  const [fmt, setFmt] = useState<PrintFormat>('thermal'); const [copies, setCopies] = useState(1); const [reason, setReason] = useState(''); const [sent, setSent] = useState(false); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const toast = useToast(); const reprints = useMemo(() => labels.filter((l) => l.print_status === 'printed').length, [labels]);
  async function send() { setErr(null); if (reprints && reason.trim().length < 3) { setErr('Some of these were already printed. Give a reason for reprinting first.'); return; } const ok = await printLabels(labels, fmt, copies); if (!ok) setErr('The browser blocked the print window. Allow pop-ups for this site and try again.'); else setSent(true); }
  async function record(success: boolean) {
    setBusy(true); const codes = labels.map((l) => l.label_code);
    const r = success ? await whAction('mark_printed', { codes, reason, format: fmt, copies }) : await whAction('print_failed', { codes, reason: 'Print did not complete' });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'Could not record the print.')); return; }
    void refreshAll(); toast.push({ tone: success ? 'good' : 'info', title: success ? `${labels.length} label(s) recorded as printed` : 'Marked as not printed', body: success ? (reprints ? `${reprints} reprint(s) logged with your reason.` : undefined) : 'They stay in the awaiting-print list.' }); onClose();
  }
  return (
    <Modal open onClose={onClose} title={`Print ${labels.length} label(s)`}>
      <div className="stack">
        <Field label="Paper"><select className="select" value={fmt} onChange={(e) => setFmt(e.target.value as PrintFormat)} disabled={sent}>{(Object.keys(FORMAT_LABEL) as PrintFormat[]).map((f) => <option key={f} value={f}>{FORMAT_LABEL[f]}</option>)}</select></Field>
        <Field label="Copies of each"><input className="input" type="number" min={1} max={20} value={copies} onChange={(e) => setCopies(Math.max(1, Math.min(20, Number(e.target.value) || 1)))} disabled={sent} /></Field>
        {reprints > 0 && <Field label={`Why reprint? (${reprints} already printed)`}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. label damaged, details changed" disabled={sent} /></Field>}
        {labels.length === 1 && <LabelPreview label={labels[0]} format={fmt} />}
        {!sent && <p className="dim">This opens your browser’s print dialog. Afterwards you confirm whether it printed, so the history is accurate.</p>}
        {sent && <div className="callout" role="status">Did the labels print? Only confirm if they came out of the printer.</div>}
        {err && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{err}</div>}
        <div className="row">{!sent ? <><Button variant="primary" icon="labels" onClick={() => void send()}>Open print dialog</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></> : <><Button variant="good" disabled={busy} onClick={() => void record(true)}>Yes, they printed</Button><Button disabled={busy} onClick={() => void record(false)}>No, it failed</Button><Button variant="ghost" disabled={busy} onClick={() => setSent(false)}>Print again</Button></>}</div>
      </div>
    </Modal>
  );
}
