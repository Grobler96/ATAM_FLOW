import { useState } from 'react';
import { Panel, Segmented, Status } from '../ui/primitives';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { shortDate, plural } from '../lib/domain';
import { dateTime } from '../lib/format';
import { OrderLink } from '../components/common';
import { EmptyState } from '../ui/primitives';
import type { ArtworkStatusRow, ArtworkVersionRow, JobPackRow } from '../data/types';

type Mode = 'orders' | 'versions' | 'packs';
export function ArtworkPage({ route }: { route: Route }) {
  const st = useView<ArtworkStatusRow>('ui_artwork_status'), ver = useView<ArtworkVersionRow>('ui_artwork_versions'), packs = useView<JobPackRow>('ui_job_packs'); const [mode, setMode] = useState<Mode>('orders');
  const views: ViewDef<ArtworkStatusRow>[] = [{ id: 'all', label: 'All decorated orders', test: () => true }, { id: 'missing', label: 'Missing artwork', test: (a) => a.areas === 0 }, { id: 'unapproved', label: 'Unapproved', test: (a) => a.areas > 0 && a.approved < a.areas }, { id: 'issues', label: 'Has file issues', test: (a) => a.blocking_issues > 0 && a.areas > 0 }, { id: 'ready', label: 'Ready', test: (a) => a.blocking_issues === 0 }, { id: 'nopack', label: 'Ready, no job pack', test: (a) => a.blocking_issues === 0 && !a.pack_status }];
  const cols: Column<ArtworkStatusRow>[] = [
    { id: 'o', header: 'Order', width: '110px', render: (a) => <OrderLink r={a.order_ref} />, sort: (a) => a.order_ref, csv: (a) => a.order_ref }, { id: 'c', header: 'Customer', width: '210px', render: (a) => a.customer_name, csv: (a) => a.customer_name },
    { id: 'd', header: 'Due', width: '90px', render: (a) => shortDate(a.due_date), sort: (a) => a.due_date, csv: (a) => a.due_date }, { id: 'areas', header: 'Areas', width: '80px', align: 'r', render: (a) => <span className="num">{a.approved}/{a.areas}</span>, csv: (a) => `${a.approved}/${a.areas}` },
    { id: 'stored', header: 'Stored', width: '80px', align: 'r', render: (a) => <span className="num">{a.stored}/{a.areas}</span>, csv: (a) => a.stored },
    { id: 'st', header: 'Status', width: '150px', render: (a) => <Status tone={a.blocking_issues === 0 ? 'good' : a.areas === 0 ? 'high' : 'medium'}>{a.blocking_issues === 0 ? 'Ready' : a.areas === 0 ? 'No artwork' : `${a.blocking_issues} issue(s)`}</Status>, sort: (a) => a.blocking_issues, csv: (a) => a.blocking_issues },
    { id: 'iss', header: 'Issues', width: '320px', render: (a) => <span className="muted">{a.issue_types?.replace(/_/g, ' ') ?? '—'}</span>, csv: (a) => a.issue_types }, { id: 'pack', header: 'Job pack', width: '120px', render: (a) => (a.pack_status ? <Status tone={a.pack_status === 'blocked' ? 'high' : 'good'} plain>{a.pack_status}</Status> : <span className="dim">none</span>), csv: (a) => a.pack_status }
  ];
  const vcols: Column<ArtworkVersionRow>[] = [
    { id: 'o', header: 'Order', width: '110px', render: (v) => <OrderLink r={v.order_ref} />, sort: (v) => v.order_ref, csv: (v) => v.order_ref }, { id: 'a', header: 'Area', width: '150px', render: (v) => v.area, csv: (v) => v.area }, { id: 'p', header: 'Process', width: '100px', render: (v) => v.process ?? '—', csv: (v) => v.process },
    { id: 'v', header: 'Version', width: '90px', render: (v) => <span className="num">v{v.version}{v.is_current ? '' : ' (old)'}</span>, sort: (v) => v.version, csv: (v) => v.version }, { id: 'f', header: 'Format', width: '90px', render: (v) => v.file_format ?? '—', csv: (v) => v.file_format },
    { id: 's', header: 'Stitches', width: '90px', align: 'r', render: (v) => <span className="num">{v.stitch_count?.toLocaleString('en-GB') ?? '—'}</span>, sort: (v) => v.stitch_count, csv: (v) => v.stitch_count }, { id: 'ap', header: 'Approval', width: '110px', render: (v) => <Status tone={v.approval_status === 'approved' ? 'good' : 'medium'} plain>{v.approval_status}</Status>, csv: (v) => v.approval_status },
    { id: 'st', header: 'File', width: '130px', render: (v) => v.storage_status.replace('_', ' '), csv: (v) => v.storage_status }, { id: 'src', header: 'Source', width: '110px', render: (v) => v.source, csv: (v) => v.source }, { id: 'at', header: 'Created', width: '130px', render: (v) => <span className="dim">{dateTime(v.created_at)}</span>, sort: (v) => v.created_at, csv: (v) => v.created_at }
  ];
  const pcols: Column<JobPackRow>[] = [
    { id: 'r', header: 'Pack', width: '130px', render: (p) => <b className="mono">{p.pack_ref}</b>, sort: (p) => p.pack_ref, csv: (p) => p.pack_ref }, { id: 'o', header: 'Order', width: '110px', render: (p) => <OrderLink r={p.order_ref} />, csv: (p) => p.order_ref }, { id: 'p', header: 'Producer', width: '190px', render: (p) => p.producer_name, csv: (p) => p.producer_name },
    { id: 'v', header: 'Version', width: '80px', render: (p) => `v${p.version}`, csv: (p) => p.version }, { id: 's', header: 'Status', width: '120px', render: (p) => <Status tone={p.status === 'blocked' ? 'high' : 'good'}>{p.status}</Status>, csv: (p) => p.status }, { id: 'st', header: 'Stale', width: '90px', render: (p) => (p.is_stale ? <Status tone="critical" plain>stale</Status> : <span className="dim">—</span>), csv: (p) => p.is_stale },
    { id: 'i', header: 'Issues', width: '80px', align: 'r', render: (p) => <span className="num">{p.issue_count}</span>, csv: (p) => p.issue_count }, { id: 'b', header: 'Built', width: '130px', render: (p) => <span className="dim">{dateTime(p.built_at)}</span>, sort: (p) => p.built_at, csv: (p) => p.built_at }, { id: 'sent', header: 'Sent', width: '130px', render: (p) => (p.sent_at ? dateTime(p.sent_at) : <span className="dim">not sent</span>), csv: (p) => p.sent_at }
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Artwork & Job Packs</h1><p>Is every decorated order ready to produce, and has the producer got the right files? {plural(st.rows.filter((a) => a.blocking_issues > 0).length, 'order')} need artwork attention.</p></div>
        <Segmented label="Artwork section" value={mode} options={[{ id: 'orders', label: 'Orders' }, { id: 'versions', label: 'File versions' }, { id: 'packs', label: 'Job packs' }]} onChange={setMode} /></div>
      {mode === 'orders' && <Panel flush><DataTable<ArtworkStatusRow> rows={st.rows} columns={cols} rowKey={(a) => a.order_id} loading={st.loading} error={st.error} onRetry={() => void st.refresh()} views={views} storageKey="artwork" exportName="artwork-status" searchText={(a) => [a.order_ref, a.customer_name, a.issue_types].join(' ')}
        onRowClick={(a) => navigate('orders/' + a.order_ref.replace('#', ''))} defaultSort={{ col: 'd', dir: 1 }} initial={tableStateFromQuery(route)} rowTone={(a) => (a.blocking_issues > 0 ? 'high' : '')} /></Panel>}
      {mode === 'versions' && <Panel flush><DataTable<ArtworkVersionRow> rows={ver.rows} columns={vcols} rowKey={(v) => v.id} loading={ver.loading} error={ver.error} storageKey="artwork-versions" exportName="artwork-versions" searchText={(v) => [v.order_ref, v.area, v.process].join(' ')}
        empty={<EmptyState icon="artwork" title="No artwork files yet">Files appear here as they are pulled from DecoNetwork or uploaded. Every change creates a new version and the history is kept.</EmptyState>} /></Panel>}
      {mode === 'packs' && <Panel flush><DataTable<JobPackRow> rows={packs.rows} columns={pcols} rowKey={(p) => p.id} loading={packs.loading} error={packs.error} storageKey="job-packs" exportName="job-packs" searchText={(p) => [p.pack_ref, p.order_ref, p.producer_name].join(' ')}
        empty={<EmptyState icon="artwork" title="No job packs yet">A job pack is built for a producer once an order's artwork is approved and stored.</EmptyState>} /></Panel>}
      <p className="dim">Preview, download, replace/upload and “send to producer” need the artwork file workflows (the DecoNetwork artwork fetch is waiting for credentials), so they are read-only here for now.</p>
    </div>
  );
}
