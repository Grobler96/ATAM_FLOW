import { useState } from 'react';
import { Button, EmptyState, Facts, Status } from '../ui/primitives';
import { Drawer, useToast } from '../ui/overlay';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { shortDate, TP_STATUS_LABEL } from '../lib/domain';
import { canBookReturn, canCancel, canCheck, EVENT_LABEL, LIFECYCLE, nextSteps, type StepDef } from '../lib/movements';
import { whAction } from '../lib/warehouse';
import { prAction } from '../lib/producerRisk';
import { OrderLink } from '../components/common';
import { CourierPanel } from '../components/CourierPanel';
import { PortalThread } from '../components/PortalPanels';
import { CheckDialog, DirectDispatchDialog, ResolveDialog, ReturnDialog, StepDialog } from '../components/MovementDialogs';
import { ReasonDialog } from '../components/WarehouseDialogs';
import type { MovementRow } from '../data/types';

interface Item { item_id: string; movement_code: string; order_ref: string; customer_name: string | null; sku: string | null; product_name: string | null; colour: string | null; size: string | null; qty_sent: number; qty_expected_back: number; qty_received_back: number; qty_damaged: number; qty_rejected: number; qty_checked_ok: number; qty_outstanding: number; qty_awaiting_check: number }
interface Ev { id: number; movement_code: string; at: string; event: string; actor: string | null; note: string | null }
interface Disc { id: string; disc_type: string; qty: number; status: string; movement_code: string; order_ref: string }

export function MovementDrawer({ code, onClose }: { code: string; onClose: () => void }) {
  const moves = useView<MovementRow>('ui_tp_movements'); const items = useView<Item>('ui_tp_items'); const events = useView<Ev>('ui_tp_events'); const discs = useView<Disc>('ui_tp_discrepancies'); const { canAct, senior } = useCtx(); const toast = useToast();
  const [dlg, setDlg] = useState<null | { k: 'step'; step: StepDef } | { k: 'return' } | { k: 'check' } | { k: 'direct' } | { k: 'cancel' } | { k: 'resolve'; d: Disc }>(null);
  const m = moves.rows.find((x) => x.movement_code === code);
  if (!m) return <Drawer open onClose={onClose} title={<span className="mono">{code}</span>}>{moves.loading ? <p className="dim">Loading…</p> : <EmptyState icon="search" title="Movement not found" />}</Drawer>;
  const its = items.rows.filter((i) => i.movement_code === code); const evs = events.rows.filter((e) => e.movement_code === code).sort((a, b) => a.at.localeCompare(b.at)); const ds = discs.rows.filter((d) => d.movement_code === code);
  const direct = m.movement_type === 'direct_dispatch_to_customer'; const idx = LIFECYCLE.indexOf(m.status); const steps = nextSteps(m.status);
  const dis = !canAct; const why = dis ? 'Your role cannot change consignments' : undefined; const close = () => { setDlg(null); void refreshAll(); };
  async function labels() { const r = await whAction('generate_labels', { type: 'producer', refs: [code] }); if (r.ok === false) toast.push({ tone: 'bad', title: 'Could not make labels', body: String(r.error) }); else { void refreshAll(); toast.push({ tone: 'good', title: 'Labels ready', body: 'Outbound, consignment and job-sheet content is waiting in the Labels page.', href: '#/labels?view=await', linkLabel: 'Open Labels' }); } }
  return (
    <Drawer open onClose={onClose} wide title={<span className="mono">{code}</span>} subtitle={<>{m.producer_name} · <Status tone={m.is_overdue ? 'critical' : m.status === 'cancelled' ? 'low' : 'info'}>{TP_STATUS_LABEL[m.status] ?? m.status}</Status></>}>
      <div className="stack" style={{ gap: 16 }}>
        {m.status !== 'cancelled' && idx >= 0 && <ol className="plain row wrap" aria-label="Progress" style={{ gap: 6, listStyle: 'none', padding: 0 }}>{LIFECYCLE.filter((s) => !(direct && ['in_transit_back', 'returned', 'checked'].includes(s))).map((s, i) => <li key={s}><Status tone={i < idx ? 'good' : s === m.status ? 'info' : ''} plain>{i < idx ? '✓ ' : ''}{TP_STATUS_LABEL[s] ?? s}</Status></li>)}</ol>}
        <div className="row wrap">
          {steps.map((s) => <Button key={s.event} size="sm" variant={s === steps[0] ? 'primary' : ''} disabled={dis} title={why} onClick={() => setDlg({ k: 'step', step: s })}>{s.label}</Button>)}
          {!direct && canBookReturn(m.status) && <Button size="sm" disabled={dis} title={why} onClick={() => setDlg({ k: 'return' })}>Book return in</Button>}
          {!direct && canCheck(m.status) && <Button size="sm" variant="primary" disabled={dis} title={why} onClick={() => setDlg({ k: 'check' })}>Check returned goods</Button>}
          {direct && ['received_by_producer', 'in_production', 'production_complete'].includes(m.status) && <Button size="sm" variant="primary" disabled={dis} title={why} onClick={() => setDlg({ k: 'direct' })}>Producer shipped to customer</Button>}
          <Button size="sm" icon="labels" disabled={dis} title={why} onClick={() => void labels()}>Generate labels</Button>
          {m.status !== 'cancelled' && <Button size="sm" disabled={dis} title={why} onClick={async () => { const r: any = await prAction('job_sheet', { code }); toast.push(r.ok === false ? { tone: 'bad', title: 'Could not draft the job sheet', body: String(r.error) } : r.already_queued ? { tone: 'info', title: 'Already waiting', body: String(r.message) } : { tone: 'good', title: 'Job sheet drafted', body: r.no_recipient ? 'This producer has no email address yet, so it is saved as a draft. Add one, then approve it under Emails.' : 'Review and approve it under Purchasing → Emails. Nothing has been sent.', href: '#/purchasing', linkLabel: 'Open Emails' }); void refreshAll(); }}>Draft job sheet email</Button>}
          {canCancel(m.status) && <Button size="sm" variant="danger" disabled={dis} title={why} onClick={() => setDlg({ k: 'cancel' })}>Cancel consignment</Button>}
        </div>
        {steps.length === 0 && !canBookReturn(m.status) && !canCheck(m.status) && !canCancel(m.status) && <p className="dim">{m.status === 'closed' || m.status === 'checked' ? 'This consignment is complete.' : m.status === 'cancelled' ? 'This consignment was cancelled.' : 'Nothing to do on this consignment right now.'}</p>}
        <Facts items={[['Type', m.movement_type.replace(/_/g, ' ')], ['Units sent', m.units_sent], ['Back (good)', m.units_received_good], ['Damaged / rejected', `${m.units_damaged} / ${m.units_rejected}`], ['Outstanding', m.units_outstanding], ['Dispatched', shortDate(m.dispatch_date)], ['Expected back', shortDate(m.expected_return_date)], ['Courier / tracking', [m.carrier, m.tracking_ref].filter(Boolean).join(' ') || null], ['Producer received', m.received_by_producer_at ? dateTime(m.received_by_producer_at) : null]]} />
        <section className="stack"><h3>Lines</h3><div style={{ overflowX: 'auto' }}><table className="table" style={{ minWidth: 620 }}><thead><tr><th>Order</th><th>SKU</th><th className="r">Sent</th><th className="r">Good back</th><th className="r">Damaged</th><th className="r">Wrong</th><th className="r">Outstanding</th><th className="r">To check</th></tr></thead>
          <tbody>{its.map((i) => <tr key={i.item_id}><td><OrderLink r={i.order_ref} /><div className="dim">{i.customer_name}</div></td><td><span className="mono">{i.sku}</span><div className="dim">{[i.colour, i.size].filter(Boolean).join(' · ')}</div></td><td className="r num">{i.qty_sent}</td><td className="r num">{i.qty_received_back}</td><td className="r num">{i.qty_damaged}</td><td className="r num">{i.qty_rejected}</td><td className="r num">{i.qty_outstanding}</td><td className="r num">{i.qty_awaiting_check}</td></tr>)}</tbody></table></div></section>
        {ds.length > 0 && <section className="stack"><h3>Open discrepancies</h3>{ds.map((d) => <div key={d.id} className="row" style={{ gap: 12 }}><Status tone="critical">{d.disc_type}</Status><span className="grow">{d.qty} unit(s) · {d.order_ref}</span><Button size="sm" disabled={!senior} title={senior ? undefined : 'Only a manager or admin can resolve a discrepancy'} onClick={() => setDlg({ k: 'resolve', d })}>Resolve…</Button></div>)}</section>}
        <PortalThread code={code} />
        <CourierPanel code={code} />
        <section className="stack"><h3>Timeline</h3>{evs.length === 0 ? <p className="dim">No events yet.</p> : <ul className="plain">{evs.map((e) => <li key={e.id}><span className="dim">{dateTime(e.at)}</span> · <b>{EVENT_LABEL[e.event] ?? e.event.replace(/_/g, ' ')}</b> · {e.actor?.replace('dashboard:', '') ?? 'system'}{e.note ? <span className="muted"> — {e.note}</span> : null}</li>)}</ul>}</section>
      </div>
      {dlg?.k === 'step' && <StepDialog code={code} step={dlg.step} onClose={close} />}
      {dlg?.k === 'return' && <ReturnDialog code={code} items={its} onClose={close} />}
      {dlg?.k === 'check' && <CheckDialog code={code} items={its} onClose={close} />}
      {dlg?.k === 'direct' && <DirectDispatchDialog code={code} onClose={close} />}
      {dlg?.k === 'resolve' && <ResolveDialog id={dlg.d.id} label={`${dlg.d.disc_type} on ${dlg.d.order_ref}`} onClose={close} />}
      {dlg?.k === 'cancel' && <ReasonDialog path="movements" title={`Cancel ${code}`} intro="The garments go back to their orders and become sendable again. The consignment stays in history." confirm="Cancel consignment" action="cancel_movement" params={{ code }} presets={['Customer changed the order', 'Wrong goods picked', 'Producer unavailable']} onClose={close} />}
    </Drawer>
  );
}
