import { Drawer } from '../ui/overlay';
import { Button, EmptyState, Facts, Panel, Skeleton, Status } from '../ui/primitives';
import { DataTable, type Column, type FilterDef, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { dateTime } from '../lib/format';
import { money, shortDate } from '../lib/domain';
import { defectFix, defectLabel, logFor, logLabel, penCounts, recentLog, severityTone, sortedDefects, waitText, type PenLogRow, type PenRow } from '../lib/pen';

// Read-only view of the holding pen. The database decides who is in it; a held order is left out of planning and cannot be dispatched or
// completed until the problem is fixed in DecoNetwork, and it leaves by itself after the next sync. Nothing here changes an order.
const orderPath = (ref: string) => 'orders/' + ref.replace('#', '');

export function PenPage({ route }: { route: Route }) {
  const pen = useView<PenRow>('ui_pen'); const log = useView<PenLogRow>('ui_pen_log');
  const open = route.path[1]; const openCase = open ? pen.rows.find((r) => r.case_key === open) ?? null : null; const c = penCounts(pen.rows);
  const views: ViewDef<PenRow>[] = [{ id: 'all', label: 'All', test: () => true }, { id: 'overdue', label: 'Overdue', test: (r) => r.is_overdue }, { id: 'unowned', label: 'No owner', test: (r) => !r.owner }, { id: 'notin', label: 'Not in ATAM_FLOW yet', test: (r) => !r.in_flow }];
  const codes = [...new Set(pen.rows.flatMap((r) => r.defects.map((d) => d.code)))].sort();
  const filters: FilterDef<PenRow>[] = [{ id: 'problem', label: 'Problem', options: codes.map((v) => ({ value: v, label: defectLabel(v) })), test: (r, v) => r.defects.some((d) => d.code === v) }];
  const cols: Column<PenRow>[] = [
    { id: 'order', header: 'Order', width: '120px', render: (r) => <b className="mono">{r.order_ref}</b>, sort: (r) => r.order_ref, csv: (r) => r.order_ref },
    { id: 'cust', header: 'Customer', width: '170px', render: (r) => r.customer_name ?? <span className="dim">—</span>, sort: (r) => r.customer_name, csv: (r) => r.customer_name },
    { id: 'due', header: 'Due', width: '150px', render: (r) => (r.is_overdue ? <Status tone="critical">Overdue {shortDate(r.due_date)}</Status> : <span className="dim">{r.due_date ? shortDate(r.due_date) : 'No date'}</span>), sort: (r) => r.due_date, csv: (r) => r.due_date },
    { id: 'problems', header: 'What is wrong', width: '360px', render: (r) => { const ds = sortedDefects(r); return <span className="row" style={{ gap: 6, flexWrap: 'nowrap' }}>{ds.slice(0, 2).map((d) => <Status key={d.code} tone={severityTone(d.severity)}>{defectLabel(d.code)}</Status>)}{ds.length > 2 && <span className="dim">+{ds.length - 2} more</span>}</span>; }, sort: (r) => r.severity_rank, csv: (r) => r.defects.map((d) => defectLabel(d.code)).join('; ') },
    { id: 'wait', header: 'Held for', width: '100px', render: (r) => <span className="dim">{waitText(r.age_hours)}</span>, sort: (r) => r.age_hours, csv: (r) => r.age_hours, hide: 'mobile' },
    { id: 'owner', header: 'Owner', width: '130px', render: (r) => r.owner ?? <span className="dim">Nobody yet</span>, sort: (r) => r.owner, csv: (r) => r.owner, hide: 'mobile' },
    { id: 'flow', header: 'In ATAM_FLOW', width: '120px', render: (r) => (r.in_flow ? <span className="dim">Yes</span> : <Status tone="info">Not yet</Status>), csv: (r) => r.in_flow, hide: 'mobile' }
  ];
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Holding pen</h1>
        <p>{c.total === 0 ? 'Nothing is being held back.' : `${c.total} order${c.total === 1 ? '' : 's'} held back`}{c.overdue ? ` · ${c.overdue} overdue` : ''}{c.notInFlow ? ` · ${c.notInFlow} not in ATAM_FLOW yet` : ''}</p></div></div>
      <div className="callout soft">An order goes into the pen when something is wrong with its data. While it is held it is left out of production planning and cannot be dispatched or completed. DecoNetwork is never changed from here: put the problem right there and the order leaves the pen by itself after the next sync. This screen is read-only. It covers every order, whether third-party or in-house.</div>
      <Panel flush>
        <DataTable<PenRow> rows={pen.rows} columns={cols} rowKey={(r) => r.case_key} loading={pen.loading} error={pen.error} onRetry={() => void pen.refresh()} views={views} filters={filters} storageKey="pen" exportName="holding-pen" defaultTab="all"
          searchText={(r) => [r.order_ref, r.customer_name, r.owner, r.defects.map((d) => defectLabel(d.code)).join(' ')].join(' ')} searchPlaceholder="Search order, customer, problem…"
          onRowClick={(r) => navigate('pen/' + r.case_key)} activeKey={open ?? null} rowTone={(r) => ((r.severity_rank ?? 0) >= 4 ? 'critical' : (r.severity_rank ?? 0) === 3 || r.is_overdue ? 'high' : '')}
          defaultSort={{ col: 'due', dir: 1 }} initial={tableStateFromQuery(route)}
          empty={<EmptyState icon="check" title="The holding pen is empty">No order is being held back for a data problem.</EmptyState>} />
      </Panel>
      <Panel title="Recent activity" icon="info" flush>{log.loading ? <div style={{ padding: 16 }}><Skeleton h={60} /></div> : log.rows.length === 0 ? <p className="dim" style={{ padding: 16, margin: 0 }}>No orders have entered or left the pen yet.</p>
        : recentLog(log.rows).map((l) => <div key={l.id} className="row wrap" style={{ padding: '8px 16px', borderBottom: '1px solid var(--border)', gap: 12 }}><span className="dim" style={{ minWidth: 130 }}>{dateTime(l.at)}</span><b className="mono" style={{ minWidth: 90 }}>{l.order_ref}</b><Status>{logLabel(l.kind)}</Status><span className="dim grow">{l.detail ?? ''}{l.actor ? ` · ${l.actor}` : ''}</span></div>)}</Panel>
      {open && <PenDrawer row={openCase} loading={pen.loading} log={log.rows} onClose={() => navigate('pen')} />}
    </div>
  );
}

function PenDrawer({ row, loading, log, onClose }: { row: PenRow | null; loading: boolean; log: PenLogRow[]; onClose: () => void }) {
  if (!row) return <Drawer open onClose={onClose} title="Held order">{loading ? <Skeleton h={120} /> : <EmptyState icon="check" title="This order is no longer in the pen">It was put right, or it is not held any more. See Recent activity on the Holding pen page.</EmptyState>}</Drawer>;
  const mine = logFor(log, row.case_key);
  return (
    <Drawer open onClose={onClose} title={<span className="row wrap" style={{ gap: 10 }}><span className="mono">{row.order_ref}</span>{row.is_overdue && <Status tone="critical">Overdue</Status>}{!row.in_flow && <Status tone="info">Not in ATAM_FLOW yet</Status>}</span>} subtitle={`${row.customer_name ?? 'No customer'} · held for ${waitText(row.age_hours)}`}>
      <div className="stack" style={{ gap: 16 }}>
        <Facts items={[['Due', row.due_date ? shortDate(row.due_date) : 'No date'], ['Units', row.units == null ? '—' : row.units.toLocaleString('en-GB')], ['Value', money(row.order_value)], ['DecoNetwork status code', row.source_status == null ? '—' : String(row.source_status)],
          ['Shipping method', row.shipping_method ?? '—'], ['Delivery address', row.ship_address ?? 'None on the order'], ['Held since', dateTime(row.first_seen_at)], ['Owner', row.owner ?? 'Nobody yet']]} />
        <section className="stack"><h3>Why it is held</h3>
          {row.defects.length === 0 ? <p className="dim">No open problems are listed.</p> : sortedDefects(row).map((d) => <div key={d.code} className="callout soft stack" style={{ gap: 4 }}><div className="row wrap" style={{ gap: 10 }}><Status tone={severityTone(d.severity)}>{defectLabel(d.code)}</Status><span className="dim">{d.severity}</span></div>{d.detail && <div>{d.detail}</div>}<div className="dim">{defectFix(d.code)}</div></div>)}</section>
        {row.waived.length > 0 && <section className="stack"><h3>Problems waived on this order</h3>{row.waived.map((w) => <div key={w.defect} className="callout soft"><b>{defectLabel(w.defect)}</b><div>{w.reason}</div><div className="dim">By {w.by} on {dateTime(w.at)}</div></div>)}</section>}
        {row.note && <section className="stack"><h3>Note</h3><div className="callout soft">{row.note}<div className="dim">{row.note_by ?? 'Someone'}{row.note_at ? ` on ${dateTime(row.note_at)}` : ''}</div></div></section>}
        <section className="stack"><h3>History</h3>{mine.length === 0 ? <p className="dim">Nothing recorded yet.</p> : mine.map((l) => <div key={l.id} className="row wrap" style={{ gap: 12 }}><span className="dim" style={{ minWidth: 130 }}>{dateTime(l.at)}</span><Status>{logLabel(l.kind)}</Status><span className="dim grow">{l.detail ?? ''}{l.actor ? ` · ${l.actor}` : ''}</span></div>)}</section>
        <p className="dim" style={{ margin: 0 }}>Assigning an owner, adding a note and waiving a problem are not available on this screen yet.</p>
        <div className="row">{row.in_flow && <Button variant="primary" onClick={() => navigate(orderPath(row.order_ref))}>Open the order</Button>}<Button variant="ghost" onClick={onClose}>Close</Button></div>
      </div>
    </Drawer>
  );
}
