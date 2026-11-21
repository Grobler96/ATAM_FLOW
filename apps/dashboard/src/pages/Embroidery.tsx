import { useState } from 'react';
import { EmptyState, Panel, Tabs } from '../ui/primitives';
import { DataTable, type BulkAction, type Column, type ViewDef } from '../ui/DataTable';
import { printProofSheets } from '../lib/proofSheet';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { shortDate } from '../lib/domain';
import { EmbroideryDialog, EmbStatus } from '../components/EmbroideryDialog';
import { BulkKnownDialog, DecoUpdateDialog } from '../components/EmbroideryDeco';
import { bulkKnownCandidates, canChangeEmbroidery, decoAffected, decoCounts, decoWords, isStale, areasFor, embCounts, embLight, embScore, embWords, SCOPE_TABS, sizeText, suggestionText, type EmbAreaRow, type EmbDesignRow } from '../lib/embroidery';
import { dateTime } from '../lib/format';

// Embroidery before production: every embroidery area on every active order, with whether the logo is new (a swatch is needed, sent to the customer to
// sign off), done before, or still to review. One tab for in-house orders and one for third-party orders; the process is the same.
export function EmbroideryPage({ route }: { route: Route }) {
  const areas = useView<EmbAreaRow>('ui_emb_areas'), designs = useView<EmbDesignRow>('ui_emb_designs'); const { role } = useCtx(); const dc = decoCounts(designs.rows, areas.rows);
  const undecided = areasFor(areas.rows, 'unclassified');
  const tabs = [...SCOPE_TABS.filter((t) => t.id !== 'unclassified' || undecided.length > 0).map((t) => ({ id: t.id as string, label: t.label, count: areasFor(areas.rows, t.id).length })), { id: 'deco', label: 'Files to update in DecoNetwork', count: dc.toUpdate }];
  const want = route.path[1]; const tab = tabs.some((t) => t.id === want) ? (want as string) : 'in_house'; const c = embCounts(areas.rows);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Embroidery</h1>
        <p>{c.total === 0 ? 'No embroidery on any active order.' : `${dc.toUpdate ? dc.toUpdate + ' file' + (dc.toUpdate === 1 ? '' : 's') + ' to update in DecoNetwork (' + dc.orders + ' order' + (dc.orders === 1 ? '' : 's') + ' carrying the old file) · ' : ''}${c.total} embroidery areas · ${c.todo} to do · ${c.busy} swatches under way · ${c.done} done${c.suggested ? ` · ${c.suggested} look like a logo we already hold` : ''}`}</p></div></div>
      <Tabs label="Embroidery sections" value={tab} tabs={tabs} onChange={(id) => navigate('embroidery/' + id)} />
      {tab === 'deco' ? <DecoTab designs={designs.rows} areas={areas.rows} loading={designs.loading} error={designs.error} onRetry={() => void designs.refresh()} role={role} route={route} /> : <AreasTab key={tab} rows={areasFor(areas.rows, tab)} loading={areas.loading} error={areas.error} onRetry={() => void areas.refresh()} role={role} route={route} />}
    </div>
  );
}

function AreasTab({ rows, loading, error, onRetry, role, route }: { rows: EmbAreaRow[]; loading: boolean; error: string | null; onRetry: () => void; role: string | null | undefined; route: Route }) {
  const [open, setOpen] = useState<string | null>(null); const [blocked, setBlocked] = useState(false); const [known, setKnown] = useState<EmbAreaRow[] | null>(null); const canWrite = canChangeEmbroidery(role);
  // Anyone can print proof sheets; one page for each ticked area.
  const bulk: BulkAction<EmbAreaRow>[] = [{ id: 'proof', label: 'Print proof sheets', icon: 'labels', run: (picked) => setBlocked(!printProofSheets(picked)) },
    { id: 'known', label: 'We have done these logos before', icon: 'check', run: canWrite ? (picked) => setKnown(bulkKnownCandidates(picked)) : undefined, disabledReason: canWrite ? undefined : 'Managers, admins and production planners only' }];
  const current = rows.find((r) => r.artwork_id === open) ?? null;
  const views: ViewDef<EmbAreaRow>[] = [
    { id: 'todo', label: 'To do', test: (r) => embLight(r.area_status) === 'red' }, { id: 'busy', label: 'Swatch under way', test: (r) => embLight(r.area_status) === 'amber' },
    { id: 'done', label: 'Done', test: (r) => embLight(r.area_status) === 'green' }, { id: 'stale', label: 'Old file in DecoNetwork', test: isStale }, { id: 'all', label: 'All', test: () => true }
  ];
  const cols: Column<EmbAreaRow>[] = [
    { id: 'order', header: 'Order', width: '110px', render: (r) => <a className="mono" href={href('orders/' + r.order_ref.replace('#', ''))} onClick={(e) => e.stopPropagation()}><b>{r.order_ref}</b></a>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '180px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '100px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'area', header: 'Placement', width: '130px', render: (r) => r.area, sort: (r) => r.area, csv: (r) => r.area },
    { id: 'logo', header: 'Logo', width: '70px', render: (r) => (r.thumbnail_url ? <img src={r.thumbnail_url} alt="" loading="lazy" style={{ maxWidth: 40, maxHeight: 40 }} /> : <span className="dim" aria-hidden>–</span>), hide: 'mobile' },
    { id: 'size', header: 'Stitches · size', width: '190px', render: (r) => <span className="dim">{sizeText(r)}</span>, sort: (r) => r.stitch_count, csv: (r) => sizeText(r), hide: 'mobile' },
    { id: 'status', header: 'Status', width: '230px', render: (r) => <span className="row wrap" style={{ gap: 4 }}><EmbStatus s={r.area_status} />{isStale(r) && <span className="chip" title="DecoNetwork still holds the old file for this logo">⚠ Old file</span>}</span>, sort: (r) => embScore(r), csv: (r) => embWords(r.area_status) },
    { id: 'design', header: 'Design', width: '260px', render: (r) => r.design_name ? <span>{r.design_name}{(r.design_round ?? 1) > 1 ? ` · round ${r.design_round}` : ''}</span> : r.suggested_design_id ? <span className="dim">{suggestionText(r)}</span> : <span className="dim">New or not checked yet</span>, csv: (r) => r.design_name ?? suggestionText(r) }
  ];
  return (
    <>
      <div className="callout soft">A <b>new logo</b> needs a physical swatch, sent to the customer to sign off. A logo we have <b>done before</b> does not. Open an area to say which it is: <b>✕ red</b> not started, <b>! amber</b> swatch under way, <b>✓ green</b> done. Flow suggests a match when the same customer has the same artwork or stitch count and size, but a person always confirms. Orders before September 2026 are not in Flow, so those logos look new until marked as done before.</div>
      {blocked && <div className="callout" role="alert">The proof sheets could not open. Allow pop-ups for this site and try again.</div>}
      <Panel flush>
        <DataTable<EmbAreaRow> rows={rows} columns={cols} rowKey={(r) => r.artwork_id} loading={loading} error={error} onRetry={onRetry} views={views} bulk={bulk} storageKey="embroidery" exportName="embroidery" defaultTab="todo"
          searchText={(r) => [r.order_ref, r.customer_name, r.area, r.design_name, embWords(r.area_status)].join(' ')} searchPlaceholder="Search order, customer or logo…" onRowClick={(r) => setOpen(r.artwork_id)} defaultSort={{ col: 'status', dir: -1 }} initial={tableStateFromQuery(route)}
          empty={<EmptyState icon="check" title="Nothing here">No embroidery matches this view.</EmptyState>} />
      </Panel>
      {current && <EmbroideryDialog row={current} role={role} onClose={() => setOpen(null)} />}
      {known && <BulkKnownDialog rows={known} onClose={() => setKnown(null)} />}
    </>
  );
}

// The log of embroidery files that were reworked in Flow and have to be replaced in DecoNetwork. DecoNetwork is updated by hand; ticking it off records who and when.
function DecoTab({ designs, areas, loading, error, onRetry, role, route }: { designs: EmbDesignRow[]; areas: EmbAreaRow[]; loading: boolean; error: string | null; onRetry: () => void; role: string | null | undefined; route: Route }) {
  const [open, setOpen] = useState<string | null>(null); const rows = designs.filter((d) => d.deco_status === 'update_needed' || d.deco_status === 'updated'); const current = rows.find((d) => d.id === open) ?? null;
  const views: ViewDef<EmbDesignRow>[] = [{ id: 'todo', label: 'To update', test: (d) => d.deco_status === 'update_needed' }, { id: 'done', label: 'Updated (log)', test: (d) => d.deco_status === 'updated' }];
  const cols: Column<EmbDesignRow>[] = [
    { id: 'cust', header: 'Customer', width: '190px', render: (d) => d.customer_name ?? <span className="dim">—</span>, sort: (d) => d.customer_name, csv: (d) => d.customer_name },
    { id: 'design', header: 'Logo', width: '250px', render: (d) => <b>{d.name}</b>, sort: (d) => d.name, csv: (d) => d.name },
    { id: 'file', header: 'Approved file', width: '130px', render: (d) => (d.approved_thumbnail_url ? <img src={d.approved_thumbnail_url} alt="" loading="lazy" style={{ maxWidth: 36, maxHeight: 36 }} /> : <span className="dim">{d.approved_file_format ? d.approved_file_format.toUpperCase() : '—'}</span>), hide: 'mobile' },
    { id: 'round', header: 'Round', width: '70px', render: (d) => d.round, sort: (d) => d.round, csv: (d) => String(d.round) },
    { id: 'approved', header: 'Approved', width: '130px', render: (d) => <span className="dim">{d.approved_at ? dateTime(d.approved_at) : '—'}</span>, sort: (d) => d.approved_at ?? null, csv: (d) => d.approved_at ?? null },
    { id: 'orders', header: 'Orders carrying the old file', width: '170px', render: (d) => (d.deco_status === 'update_needed' ? decoAffected(areas, d.id).length : <span className="dim">—</span>), sort: (d) => decoAffected(areas, d.id).length },
    { id: 'state', header: 'DecoNetwork', width: '230px', render: (d) => <span className={d.deco_status === 'updated' ? '' : 'warn'}>{decoWords(d.deco_status)}{d.deco_status === 'updated' && d.deco_updated_at ? ` · ${dateTime(d.deco_updated_at)}` : ''}</span>, csv: (d) => decoWords(d.deco_status) }
  ];
  return (
    <>
      <div className="callout soft">When a logo's file is <b>reworked</b> for a job and uploaded into Flow, it is right for that job, but DecoNetwork still holds the <b>old</b> file, so the next order for that logo could use it. Every approved reworked file lands here. Replace it in DecoNetwork, then tick it off. Until you do, any order carrying the old file is warned on the other tabs. Flow cannot change files in DecoNetwork: that is done by hand.</div>
      <Panel flush>
        <DataTable<EmbDesignRow> rows={rows} columns={cols} rowKey={(d) => d.id} loading={loading} error={error} onRetry={onRetry} views={views} storageKey="embroidery-deco" exportName="deconetwork-files-to-update" defaultTab="todo"
          searchText={(d) => [d.name, d.customer_name].join(' ')} searchPlaceholder="Search logo or customer…" onRowClick={(d) => setOpen(d.id)} defaultSort={{ col: 'approved', dir: 1 }} initial={tableStateFromQuery(route)}
          empty={<EmptyState icon="check" title="Nothing to update">No approved file is waiting to be replaced in DecoNetwork.</EmptyState>} />
      </Panel>
      {current && <DecoUpdateDialog design={current} areas={areas} role={role} onClose={() => setOpen(null)} />}
    </>
  );
}
