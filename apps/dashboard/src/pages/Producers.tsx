import { useMemo, useState } from 'react';
import { EmptyState, Facts, Panel, Segmented, Status, Tag } from '../ui/primitives';
import { Drawer } from '../ui/overlay';
import { DataTable, type Column, type ViewDef } from '../ui/DataTable';
import { useView } from '../data/store';
import { navigate, tableStateFromQuery, type Route } from '../router';
import { METHOD_LABEL, money, pct, shortDate, TP_STATUS_LABEL, CUSTODY_LABEL } from '../lib/domain';
import { Num, OrderTags } from '../components/common';
import type { HeldRow, MovementRow, ProducerRow } from '../data/types';

interface DiscRow { id: string; disc_type: string; qty: number; status: string; movement_code: string; producer_name: string; order_ref: string; customer_name: string | null; blocks_completion: boolean }
type Mode = 'producers' | 'movements' | 'held' | 'discrepancies';

export function ProducersPage({ route }: { route: Route }) {
  const prod = useView<ProducerRow>('ui_producers'), moves = useView<MovementRow>('ui_tp_movements'), held = useView<HeldRow>('ui_producer_held_stock'), disc = useView<DiscRow>('ui_tp_discrepancies');
  const [mode, setMode] = useState<Mode>('producers'); const open = route.path[1] === 'movement' ? null : route.path[1]; const moveOpen = route.path[1] === 'movement' ? route.path[2] : null;
  const risk = (p: ProducerRow) => (p.late_returns > 0 || (p.on_time_rate != null && p.on_time_rate < 80) ? 'High' : p.on_time_rate == null ? 'Unknown' : 'Low');
  const pcols: Column<ProducerRow>[] = [
    { id: 'name', header: 'Producer', width: '210px', render: (p) => <b>{p.name}</b>, sort: (p) => p.name.toLowerCase(), csv: (p) => p.name }, { id: 'status', header: 'Status', width: '100px', render: (p) => <Status tone={p.is_active ? 'good' : 'critical'}>{p.is_active ? 'Active' : 'Inactive'}</Status>, csv: (p) => (p.is_active ? 'active' : 'inactive') },
    { id: 'cap', header: 'Capability', width: '210px', render: (p) => <span className="row wrap" style={{ gap: 4 }}>{p.capable_methods.map((m) => <Tag key={m}>{METHOD_LABEL[m] ?? m}</Tag>)}</span>, csv: (p) => p.capable_methods },
    { id: 'jobs', header: 'Open jobs', width: '90px', align: 'r', render: (p) => <Num v={p.open_jobs} dim0 />, sort: (p) => p.open_jobs, csv: (p) => p.open_jobs }, { id: 'held', header: 'Stock held', width: '96px', align: 'r', render: (p) => <Num v={p.units_held} dim0 />, sort: (p) => p.units_held, csv: (p) => p.units_held },
    { id: 'value', header: 'Value held', width: '100px', align: 'r', render: (p) => <span className="num">{money(p.value_held)}</span>, sort: (p) => p.value_held, csv: (p) => p.value_held }, { id: 'late', header: 'Overdue returns', width: '120px', align: 'r', render: (p) => <span className={`num ${p.late_returns ? 'bad' : 'dim'}`}>{p.late_returns}</span>, sort: (p) => p.late_returns, csv: (p) => p.late_returns },
    { id: 'ot', header: 'On time', width: '84px', align: 'r', render: (p) => <span className="num">{pct(p.on_time_rate)}</span>, sort: (p) => p.on_time_rate, csv: (p) => p.on_time_rate }, { id: 'disc', header: 'Discrepancy rate', width: '130px', align: 'r', render: (p) => <span className="num">{pct(p.discrepancy_rate)}</span>, sort: (p) => p.discrepancy_rate, csv: (p) => p.discrepancy_rate },
    { id: 'turn', header: 'Turnaround', width: '100px', align: 'r', render: (p) => <span className="num">{p.avg_turnaround_days ?? p.turnaround_days} d</span>, sort: (p) => p.turnaround_days, csv: (p) => p.turnaround_days }, { id: 'risk', header: 'Risk', width: '90px', render: (p) => <Status tone={risk(p) === 'High' ? 'critical' : risk(p) === 'Low' ? 'good' : ''} plain>{risk(p)}</Status>, csv: risk }
  ];
  const mviews: ViewDef<MovementRow>[] = [{ id: 'open', label: 'Open', test: (m) => !['closed', 'cancelled', 'checked'].includes(m.status) }, { id: 'overdue', label: 'Overdue returns', test: (m) => m.is_overdue }, { id: 'norecv', label: 'Receipt unconfirmed', test: (m) => m.status === 'dispatched' && !m.received_by_producer_at }, { id: 'disc', label: 'With discrepancies', test: (m) => m.open_discrepancies > 0 }, { id: 'all', label: 'All', test: () => true }];
  const mcols: Column<MovementRow>[] = [
    { id: 'ref', header: 'Movement', width: '130px', render: (m) => <b className="mono">{m.movement_code}</b>, sort: (m) => m.movement_code, csv: (m) => m.movement_code }, { id: 'type', header: 'Type', width: '150px', render: (m) => m.movement_type.replace(/_/g, ' '), csv: (m) => m.movement_type },
    { id: 'prod', header: 'Producer', width: '170px', render: (m) => m.producer_name, sort: (m) => m.producer_name, csv: (m) => m.producer_name }, { id: 'status', header: 'Status', width: '170px', render: (m) => <Status tone={m.is_overdue ? 'critical' : 'info'}>{TP_STATUS_LABEL[m.status] ?? m.status}</Status>, csv: (m) => m.status },
    { id: 'orders', header: 'Orders', width: '200px', render: (m) => <OrderTags refs={m.order_refs} max={3} />, csv: (m) => m.order_refs }, { id: 'sent', header: 'Sent', width: '70px', align: 'r', render: (m) => <Num v={m.units_sent} />, sort: (m) => m.units_sent, csv: (m) => m.units_sent },
    { id: 'back', header: 'Back (good)', width: '96px', align: 'r', render: (m) => <Num v={m.units_received_good} dim0 />, csv: (m) => m.units_received_good }, { id: 'out', header: 'Outstanding', width: '96px', align: 'r', render: (m) => <Num v={m.units_outstanding} dim0 />, sort: (m) => m.units_outstanding, csv: (m) => m.units_outstanding },
    { id: 'disp', header: 'Dispatched', width: '96px', render: (m) => shortDate(m.dispatch_date), sort: (m) => m.dispatch_date, csv: (m) => m.dispatch_date }, { id: 'exp', header: 'Expected back', width: '110px', render: (m) => shortDate(m.expected_return_date), sort: (m) => m.expected_return_date, csv: (m) => m.expected_return_date },
    { id: 'act', header: 'Actual back', width: '100px', render: (m) => <span className="dim">{shortDate(m.actual_return_date)}</span>, csv: (m) => m.actual_return_date }, { id: 'track', header: 'Courier / tracking', width: '170px', render: (m) => <span className="mono dim">{[m.carrier, m.tracking_ref].filter(Boolean).join(' ') || '—'}</span>, csv: (m) => m.tracking_ref },
    { id: 'rcpt', header: 'Receipt', width: '110px', render: (m) => m.received_by_producer_at ? <Status tone="good" plain>Confirmed</Status> : <span className="dim">—</span>, csv: (m) => m.received_by_producer_at }, { id: 'dd', header: 'Discrepancies', width: '110px', render: (m) => (m.open_discrepancies ? <Status tone="critical">{m.open_discrepancies}</Status> : <span className="dim">—</span>), csv: (m) => m.open_discrepancies }
  ];
  const noProducers = !prod.loading && prod.rows.length === 0;
  const emptyProducers = <EmptyState icon="producers" title="No producers set up yet">Add your third-party decorators (name, methods, turnaround, rate card) and every outbound movement, return and discrepancy will be tracked here.</EmptyState>;
  const heldRows = useMemo(() => held.rows, [held.rows]);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Producers</h1><p>Third-party decorators: who has what, what is due back, and how reliable they are.</p></div>
        <Segmented label="Producer section" value={mode} options={[{ id: 'producers', label: 'Producers' }, { id: 'movements', label: 'Movements' }, { id: 'held', label: 'Stock held' }, { id: 'discrepancies', label: `Discrepancies (${disc.rows.length})` }]} onChange={setMode} /></div>
      {mode === 'producers' && <Panel flush><DataTable<ProducerRow> rows={prod.rows} columns={pcols} rowKey={(p) => p.id} loading={prod.loading} error={prod.error} onRetry={() => void prod.refresh()} storageKey="producers" exportName="producers" searchText={(p) => [p.name, p.code, p.capable_methods.join(' ')].join(' ')}
        onRowClick={(p) => navigate('producers/' + p.id)} empty={emptyProducers} defaultSort={{ col: 'name', dir: 1 }} /></Panel>}
      {mode === 'movements' && <Panel flush><DataTable<MovementRow> rows={moves.rows} columns={mcols} rowKey={(m) => m.movement_id} loading={moves.loading} error={moves.error} onRetry={() => void moves.refresh()} views={mviews} storageKey="movements" exportName="producer-movements" defaultTab="open"
        searchText={(m) => [m.movement_code, m.producer_name, (m.order_refs ?? []).join(' '), m.tracking_ref].join(' ')} rowTone={(m) => (m.is_overdue ? 'critical' : m.open_discrepancies ? 'high' : '')} empty={<EmptyState icon="truck" title="No producer movements yet">Outbound consignments, returns and direct dispatches appear here once goods go to a producer.</EmptyState>} initial={tableStateFromQuery(route)} defaultSort={{ col: 'disp', dir: -1 }} /></Panel>}
      {mode === 'held' && <Panel title="Stock held by producers" flush>{heldRows.length === 0 ? <EmptyState icon="stock" title="Nothing is with a producer">Producer-held stock never counts as available warehouse stock; it appears here while goods are out.</EmptyState> :
        <div className="stack" style={{ gap: 0 }}>{heldRows.map((h, i) => <div key={i} className="row wrap" style={{ padding: '8px 16px', borderBottom: '1px solid var(--border)', justifyContent: 'space-between' }}><b>{h.producer_name}</b><span className="mono">{h.sku}</span><Tag>{CUSTODY_LABEL[h.location_state] ?? h.location_state}</Tag><span className="num">{h.qty}</span><OrderTags refs={h.orders} max={3} /></div>)}</div>}</Panel>}
      {mode === 'discrepancies' && <Panel title="Open producer discrepancies" flush>{disc.rows.length === 0 ? <EmptyState icon="check" title="No open producer discrepancies" /> : disc.rows.map((d) => <div key={d.id} className="row wrap" style={{ padding: '10px 16px', borderBottom: '1px solid var(--border)', justifyContent: 'space-between' }}><b>{d.producer_name}</b><span className="mono">{d.movement_code}</span><span>{d.disc_type} · {d.qty} · {d.order_ref} {d.customer_name}</span>{d.blocks_completion && <Status tone="high" plain>Blocks completion</Status>}</div>)}</Panel>}
      {noProducers && mode === 'producers' && <p className="dim">Producer rate cards are needed before the selection engine can recommend a producer.</p>}
      {open && <ProducerDrawer id={open} onClose={() => navigate('producers')} />}
      {moveOpen && <Drawer open onClose={() => navigate('producers')} title={<span className="mono">{moveOpen}</span>}><MovementDetail code={moveOpen} moves={moves.rows} /></Drawer>}
    </div>
  );
}

function MovementDetail({ code, moves }: { code: string; moves: MovementRow[] }) {
  const m = moves.find((x) => x.movement_code === code); if (!m) return <EmptyState icon="search" title="Movement not found" />;
  return <Facts items={[['Producer', m.producer_name], ['Type', m.movement_type.replace(/_/g, ' ')], ['Status', TP_STATUS_LABEL[m.status] ?? m.status], ['Units sent', m.units_sent], ['Back (good)', m.units_received_good], ['Damaged / rejected', `${m.units_damaged} / ${m.units_rejected}`], ['Outstanding', m.units_outstanding], ['Dispatched', shortDate(m.dispatch_date)], ['Expected back', shortDate(m.expected_return_date)], ['Courier', m.carrier], ['Tracking', m.tracking_ref], ['Receipt confirmed', m.received_by_producer_at ? new Date(m.received_by_producer_at).toLocaleString('en-GB') : 'Not yet']]} />;
}

function ProducerDrawer({ id, onClose }: { id: string; onClose: () => void }) {
  const prod = useView<ProducerRow>('ui_producers'), moves = useView<MovementRow>('ui_tp_movements'), held = useView<HeldRow>('ui_producer_held_stock');
  const p = prod.rows.find((x) => x.id === id); if (!p) return <Drawer open onClose={onClose} title="Producer"><EmptyState icon="search" title="Producer not found" /></Drawer>;
  const mv = moves.rows.filter((m) => m.producer_id === id), hs = held.rows.filter((h) => h.producer_id === id);
  return (
    <Drawer open onClose={onClose} wide title={p.name} subtitle={<Status tone={p.is_active ? 'good' : 'critical'}>{p.is_active ? 'Active' : 'Inactive'}</Status>}>
      <div className="stack" style={{ gap: 16 }}>
        <Facts items={[['Contact', p.contact_name], ['Email', p.email], ['Phone', p.phone], ['Address', p.address], ['Standard turnaround', `${p.turnaround_days} days`], ['Weekly capacity', p.weekly_capacity_units ? `${p.weekly_capacity_units} units` : 'not set'], ['Direct dispatch', p.can_direct_dispatch ? 'Yes' : 'No'], ['Emergency contact', 'Not recorded'], ['Backup producers', 'Not recorded']]} />
        <section className="stack"><h3>Capability</h3><div className="row wrap">{p.capable_methods.map((m) => <Tag key={m}>{METHOD_LABEL[m] ?? m}</Tag>)}</div></section>
        <section className="stack"><h3>Performance</h3><Facts items={[['On-time return rate', pct(p.on_time_rate)], ['Average turnaround', p.avg_turnaround_days ? `${p.avg_turnaround_days} days` : '—'], ['Discrepancy rate', pct(p.discrepancy_rate)], ['Overdue returns', p.late_returns], ['Orders blocked', p.orders_blocked], ['Quality pass rate', 'Not tracked yet']]} /></section>
        <section className="stack"><h3>Stock held ({p.units_held} units · {money(p.value_held)})</h3>{hs.length === 0 ? <p className="dim">Nothing held.</p> : hs.map((h, i) => <div key={i} className="row" style={{ justifyContent: 'space-between' }}><span className="mono">{h.sku}</span><Tag>{CUSTODY_LABEL[h.location_state] ?? h.location_state}</Tag><span className="num">{h.qty}</span></div>)}</section>
        <section className="stack"><h3>Movements ({mv.length})</h3>{mv.length === 0 ? <p className="dim">No movements yet.</p> : mv.slice(0, 15).map((m) => <div key={m.movement_id} className="row" style={{ justifyContent: 'space-between' }}><a className="mono" href={'#/producers/movement/' + m.movement_code}>{m.movement_code}</a><Status tone={m.is_overdue ? 'critical' : 'info'}>{TP_STATUS_LABEL[m.status] ?? m.status}</Status><span className="num dim">{m.units_sent} sent · back {shortDate(m.expected_return_date)}</span></div>)}</section>
        {(p.quality_notes || p.special_instructions) && <section className="stack"><h3>Notes</h3>{p.quality_notes && <p className="muted">{p.quality_notes}</p>}{p.special_instructions && <p className="muted">{p.special_instructions}</p>}</section>}
      </div>
    </Drawer>
  );
}
