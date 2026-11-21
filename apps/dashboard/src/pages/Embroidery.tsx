import { useState } from 'react';
import { EmptyState, Panel, Tabs } from '../ui/primitives';
import { DataTable, type BulkAction, type Column, type ViewDef } from '../ui/DataTable';
import { printProofSheets } from '../lib/proofSheet';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { href, navigate, tableStateFromQuery, type Route } from '../router';
import { shortDate } from '../lib/domain';
import { EmbroideryDialog, EmbStatus } from '../components/EmbroideryDialog';
import { areasFor, embCounts, embLight, embScore, embWords, SCOPE_TABS, sizeText, suggestionText, type EmbAreaRow } from '../lib/embroidery';

// Embroidery before production: every embroidery area on every active order, with whether the logo is new (a swatch is needed, sent to the customer to
// sign off), done before, or still to review. One tab for in-house orders and one for third-party orders; the process is the same.
export function EmbroideryPage({ route }: { route: Route }) {
  const areas = useView<EmbAreaRow>('ui_emb_areas'); const { role } = useCtx();
  const undecided = areasFor(areas.rows, 'unclassified');
  const tabs = SCOPE_TABS.filter((t) => t.id !== 'unclassified' || undecided.length > 0).map((t) => ({ id: t.id, label: t.label, count: areasFor(areas.rows, t.id).length }));
  const want = route.path[1]; const tab = tabs.some((t) => t.id === want) ? (want as string) : 'in_house'; const c = embCounts(areas.rows);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Embroidery</h1>
        <p>{c.total === 0 ? 'No embroidery on any active order.' : `${c.total} embroidery areas · ${c.todo} to do · ${c.busy} swatches under way · ${c.done} done${c.suggested ? ` · ${c.suggested} look like a logo we already hold` : ''}`}</p></div></div>
      <Tabs label="Embroidery sections" value={tab} tabs={tabs} onChange={(id) => navigate('embroidery/' + id)} />
      <AreasTab key={tab} rows={areasFor(areas.rows, tab)} loading={areas.loading} error={areas.error} onRetry={() => void areas.refresh()} role={role} route={route} />
    </div>
  );
}

function AreasTab({ rows, loading, error, onRetry, role, route }: { rows: EmbAreaRow[]; loading: boolean; error: string | null; onRetry: () => void; role: string | null | undefined; route: Route }) {
  const [open, setOpen] = useState<string | null>(null); const [blocked, setBlocked] = useState(false);
  // Anyone can print proof sheets; one page for each ticked area.
  const bulk: BulkAction<EmbAreaRow>[] = [{ id: 'proof', label: 'Print proof sheets', icon: 'labels', run: (picked) => setBlocked(!printProofSheets(picked)) }];
  const current = rows.find((r) => r.artwork_id === open) ?? null;
  const views: ViewDef<EmbAreaRow>[] = [
    { id: 'todo', label: 'To do', test: (r) => embLight(r.area_status) === 'red' }, { id: 'busy', label: 'Swatch under way', test: (r) => embLight(r.area_status) === 'amber' },
    { id: 'done', label: 'Done', test: (r) => embLight(r.area_status) === 'green' }, { id: 'all', label: 'All', test: () => true }
  ];
  const cols: Column<EmbAreaRow>[] = [
    { id: 'order', header: 'Order', width: '110px', render: (r) => <a className="mono" href={href('orders/' + r.order_ref.replace('#', ''))} onClick={(e) => e.stopPropagation()}><b>{r.order_ref}</b></a>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '180px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '100px', render: (r) => <span className="dim">{r.due_date ? shortDate(r.due_date) : '—'}</span>, sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'area', header: 'Placement', width: '130px', render: (r) => r.area, sort: (r) => r.area, csv: (r) => r.area },
    { id: 'logo', header: 'Logo', width: '70px', render: (r) => (r.thumbnail_url ? <img src={r.thumbnail_url} alt="" loading="lazy" style={{ maxWidth: 40, maxHeight: 40 }} /> : <span className="dim" aria-hidden>–</span>), hide: 'mobile' },
    { id: 'size', header: 'Stitches · size', width: '190px', render: (r) => <span className="dim">{sizeText(r)}</span>, sort: (r) => r.stitch_count, csv: (r) => sizeText(r), hide: 'mobile' },
    { id: 'status', header: 'Status', width: '210px', render: (r) => <EmbStatus s={r.area_status} />, sort: (r) => embScore(r), csv: (r) => embWords(r.area_status) },
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
    </>
  );
}
