import { useMemo, useState } from 'react';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { Button, EmptyState, Facts, Field, Panel, Progress, Skeleton, Status, Tabs, Tag } from '../ui/primitives';
import { useView } from '../data/store';
import { useRpcList } from '../data/useRpcList';
import { useCtx } from '../data/context';
import { href } from '../router';
import { exceptionActionTo } from '../lib/api';
import { gbp, deadlineText, dateTime } from '../lib/format';
import { CUSTODY_LABEL, METHOD_LABEL, money, PO_STATUS_LABEL, shortDate, stockStatus, TP_STATUS_LABEL, PRIORITY } from '../lib/domain';
import { DueCell, StatusCell, OrderLink, Num } from '../components/common';
import { SelectionCompare } from '../components/SelectionCompare';
import type { ExceptionRow } from '../types';
import type { AllocationDecision, ArtworkStatusRow, ArtworkVersionRow, BinRow, CustodyRow, JobPackRow, MovementRow, OrderLineRow, OrderRow, PoRow, QueueRow, SelectionRow, TpOrderRow } from '../data/types';

type Tab = 'overview' | 'lines' | 'artwork' | 'production' | 'producer' | 'purchasing' | 'warehouse' | 'exceptions' | 'history';
interface Hist { at: string; kind: string; title: string; detail: string; actor: string | null }
interface Acc { order_id: string; owner: string; location: string | null; next_action: string | null }

// Turns an engine's score breakdown into labelled bars: this is the "why" behind a recommendation.
export function ScoreBars({ parts }: { parts: Record<string, unknown> | null }) {
  const items = Object.entries(parts ?? {}).filter(([, v]) => typeof v === 'number').map(([k, v]) => [k, v as number] as const).filter(([k]) => !['pct_on_hand', 'pct_covered', 'incoming_qty'].includes(k));
  if (!items.length) return null; const max = Math.max(1, ...items.map(([, v]) => Math.abs(v)));
  return <div className="stack" style={{ gap: 4 }}>{items.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1])).map(([k, v]) => <div key={k} style={{ display: 'grid', gridTemplateColumns: '150px 1fr 48px', gap: 8, alignItems: 'center', fontSize: 12 }}><span className="muted">{k.replace(/_/g, ' ')}</span><Progress value={(Math.abs(v) / max) * 100} tone={v < 0 ? 'bad' : 'good'} /><span className="num" style={{ textAlign: 'right' }}>{v > 0 ? '+' : ''}{v}</span></div>)}</div>;
}

export function OrderDrawer({ orderRef, onClose }: { orderRef: string; onClose: () => void }) {
  const orders = useView<OrderRow>('ui_orders'); const o = orders.rows.find((x) => x.order_ref === orderRef || x.order_ref === '#' + orderRef) ?? null;
  const [tab, setTab] = useState<Tab>('overview');
  const lines = useView<OrderLineRow>('ui_order_lines'), decisions = useView<AllocationDecision>('ui_allocation_decisions'), queue = useView<QueueRow>('ui_production_queue'), custody = useView<CustodyRow>('ui_custody');
  const artStat = useView<ArtworkStatusRow>('ui_artwork_status'), artVer = useView<ArtworkVersionRow>('ui_artwork_versions'), packs = useView<JobPackRow>('ui_job_packs');
  const tpo = useView<TpOrderRow>('ui_tp_orders'), moves = useView<MovementRow>('ui_tp_movements'), pos = useView<PoRow>('ui_purchase_orders'), sel = useView<SelectionRow>('ui_selection');
  const bins = useView<BinRow>('ui_bins'), ex = useView<ExceptionRow>('ui_exceptions'), acc = useView<Acc>('ui_order_accountability');
  const hist = useRpcList<Hist>('ui_order_history', { p_order: o?.id ?? '00000000-0000-0000-0000-000000000000' }, [o?.id], 0);
  const { canAct } = useCtx(); const toast = useToast();
  const [compare, setCompare] = useState(false); const [pin, setPin] = useState<QueueRow | null>(null); const [pinRank, setPinRank] = useState('1'); const [pinWhy, setPinWhy] = useState(''); const [pinBusy, setPinBusy] = useState(false); const [pinErr, setPinErr] = useState<string | null>(null);

  const d = useMemo(() => {
    if (!o) return null;
    const ref = o.order_ref;
    return { lines: lines.rows.filter((l) => l.order_id === o.id), dec: decisions.rows.find((x) => x.order_id === o.id), steps: queue.rows.filter((q) => q.order_id === o.id).sort((a, b) => a.step_no - b.step_no), cust: custody.rows.filter((c) => c.order_id === o.id),
      art: artStat.rows.find((a) => a.order_id === o.id), versions: artVer.rows.filter((v) => v.order_ref === ref), packs: packs.rows.filter((p) => p.order_ref === ref), tp: tpo.rows.find((t) => t.order_id === o.id),
      moves: moves.rows.filter((m) => (m.order_refs ?? []).includes(ref)), pos: pos.rows.filter((p) => (p.source_orders ?? []).includes(ref)), sel: sel.rows.find((s) => s.order_id === o.id), bins: bins.rows.filter((b) => (b.order_refs ?? []).includes(ref)),
      ex: ex.rows.filter((e) => e.order_refs.includes(ref)), acc: acc.rows.find((a) => a.order_id === o.id) };
  }, [o, lines.rows, decisions.rows, queue.rows, custody.rows, artStat.rows, artVer.rows, packs.rows, tpo.rows, moves.rows, pos.rows, sel.rows, bins.rows, ex.rows, acc.rows]);

  async function savePin() {
    if (!pin || !o) return; setPinBusy(true); setPinErr(null);
    const r = await exceptionActionTo('production', 'pin', { order_id: o.id, method: pin.method_code, rank: Number(pinRank), reason: pinWhy });
    setPinBusy(false);
    if (r.ok === false) { setPinErr(String(r.error)); return; }
    toast.push({ tone: 'good', title: 'Override saved', body: 'Re-plan production to apply it. Your reason is in the audit trail.' }); setPin(null); setPinWhy('');
  }

  if (!o) return <Drawer open onClose={onClose} title={`Order ${orderRef}`}>{orders.loading ? <div className="stack"><Skeleton h={20} /><Skeleton h={20} w="70%" /><Skeleton h={120} /></div> : <EmptyState icon="search" title="Order not found">It may be dispatched, cancelled or not synced yet.</EmptyState>}</Drawer>;
  const ss = stockStatus(o);
  const tabs: { id: Tab; label: string; count?: number }[] = [{ id: 'overview', label: 'Overview' }, { id: 'lines', label: 'Lines & stock', count: d!.lines.length }, { id: 'artwork', label: 'Artwork', count: d!.versions.length }, { id: 'production', label: 'Production', count: d!.steps.length },
    { id: 'producer', label: 'Producer', count: d!.moves.length }, { id: 'purchasing', label: 'Purchasing', count: d!.pos.length }, { id: 'warehouse', label: 'Warehouse', count: d!.bins.length }, { id: 'exceptions', label: 'Exceptions', count: d!.ex.length }, { id: 'history', label: 'History' }];

  return (
    <Drawer open onClose={onClose} wide title={<span className="row wrap" style={{ gap: 10 }}>{o.order_ref}<StatusCell s={o.order_status} />{o.is_overdue && <Status tone="critical">Overdue</Status>}</span>} subtitle={`${o.customer_name ?? 'No customer'}${o.customer_po ? ' · PO ' + o.customer_po : ''}`}
      header={<Tabs label="Order sections" value={tab} tabs={tabs} onChange={setTab} />}>
      {tab === 'overview' && d && <div className="stack" style={{ gap: 16 }}>
        <Facts items={[['Due / dispatch', <DueCell key="d" days={o.days_to_due} date={o.due_date} />], ['Priority', `${PRIORITY[o.priority]?.label}${o.is_vip ? ' · VIP' : ''}`], ['Units', <Num key="u" v={o.total_units} />], ['Value', money(o.order_value)], ['Methods', o.decoration_methods.map((m) => METHOD_LABEL[m] ?? m).join(', ') || 'None recorded'],
          ['Stock', <Status key="s" tone={ss.tone}>{ss.label}</Status>], ['Shipping', o.shipping_method], ['Ordered', shortDate(o.order_date)], ['Last updated', dateTime(o.updated_at)], ['Status reason', o.status_reason], ['Notes', o.production_notes]]} />
        {d.acc && <div className="callout soft"><b>Owner · location · next action</b><div className="row wrap" style={{ gap: 18 }}><span><span className="fact-l">Owner</span><br />{d.acc.owner}</span><span><span className="fact-l">Where it is</span><br />{d.acc.location ?? <span className="warn">Unknown</span>}</span><span><span className="fact-l">Next action</span><br />{d.acc.next_action ?? <span className="warn">Unknown: needs a decision</span>}</span></div></div>}
        <Panel title="Why the system says this" icon="info">
          <div className="stack">
            <div><h3>Stock allocation</h3>{d.dec ? <><div className="row" style={{ margin: '6px 0' }}><Status tone={d.dec.decision === 'allocate' ? 'good' : d.dec.decision === 'blocked' ? 'critical' : 'medium'}>{d.dec.decision}</Status>{d.dec.score != null && <span className="dim num">score {d.dec.score}</span>}</div><p className="muted">{d.dec.reason}</p><div style={{ marginTop: 8 }}><ScoreBars parts={d.dec.score_breakdown} /></div></> : <p className="dim">The allocation engine has not looked at this order (it is not waiting for stock).</p>}</div>
            <div><h3>Production sequence</h3>{d.steps.length === 0 ? <p className="dim">Not scheduled.</p> : d.steps.map((s) => <div key={s.step_id} className="callout soft" style={{ marginBottom: 6 }}><b>{METHOD_LABEL[s.method_code] ?? s.method_code}: position #{s.sequence_position ?? '–'}{s.is_overridden && s.recommended_position != null ? ` (system recommends #${s.recommended_position})` : ''}</b><span className="muted">{s.reason ?? s.blocked_reason ?? 'No reason recorded.'}</span><div style={{ marginTop: 6 }}><ScoreBars parts={s.score_breakdown} /></div></div>)}</div>
            <div><h3>Supplier & producer</h3>{d.sel ? <><p className="muted">{d.sel.explanation}</p><p className="dim num">{d.sel.supplier_plan} + {d.sel.route_name} · {money(d.sel.total_cost, 2)} · margin {d.sel.margin_pct}%</p></> : <p className="dim">No supplier/producer comparison saved yet. Use Purchasing → Compare options.</p>}</div>
          </div>
        </Panel>
        {d.ex.length > 0 && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.45)', background: 'var(--critical-soft)' }}><b>{d.ex.length} open exception(s)</b>{d.ex.slice(0, 3).map((e) => <div key={e.id}><a href={href('exceptions/' + e.exc_ref)}>{e.exc_ref}</a> · {e.type_label}</div>)}</div>}
      </div>}

      {tab === 'lines' && d && <div className="stack" style={{ gap: 14 }}>
        {d.lines.length === 0 ? <EmptyState title="No lines" /> : <div style={{ overflow: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}><thead><tr className="dim" style={{ textAlign: 'left' }}>{['SKU', 'Product', 'Colour', 'Size', 'Needed', 'Produced', 'On hand', 'Incoming', 'Short'].map((h) => <th key={h} style={{ padding: '6px 8px' }}>{h}</th>)}</tr></thead>
          <tbody>{d.lines.map((l) => <tr key={l.id} style={{ borderTop: '1px solid var(--border)' }}><td className="mono" style={{ padding: '6px 8px' }}><a href={href('stock/' + encodeURIComponent(l.sku ?? ''))}>{l.sku}</a></td><td style={{ padding: '6px 8px' }}>{l.product_name}</td><td style={{ padding: '6px 8px' }}>{l.colour}</td><td style={{ padding: '6px 8px' }}>{l.size}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_required}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_produced}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_allocated_on_hand}</td><td className="num" style={{ padding: '6px 8px' }}>{l.qty_allocated_incoming}</td><td className={`num ${l.qty_shortage ? 'bad' : 'dim'}`} style={{ padding: '6px 8px' }}>{l.qty_shortage}</td></tr>)}</tbody></table></div>}
        <h3>Where the garments are</h3>
        {d.cust.length === 0 ? <p className="dim">No custody record yet: nothing has left the warehouse for this order.</p> : <div className="stack">{Object.entries(d.cust.reduce<Record<string, number>>((m, c) => { m[c.location_state] = (m[c.location_state] ?? 0) + c.qty; return m; }, {})).map(([s, q]) => <div key={s} className="row" style={{ justifyContent: 'space-between' }}><span>{CUSTODY_LABEL[s] ?? s}</span><b className="num">{q}</b></div>)}</div>}
      </div>}

      {tab === 'artwork' && d && <div className="stack">
        <div className="row wrap"><Status tone={d.art && d.art.blocking_issues === 0 ? 'good' : 'high'}>{d.art ? (d.art.blocking_issues === 0 ? 'Ready' : `${d.art.blocking_issues} issue(s)`) : 'No decoration'}</Status>{d.art?.issue_types && <span className="muted">{d.art.issue_types.replace(/_/g, ' ')}</span>}{d.art && <span className="dim">{d.art.approved}/{d.art.areas} areas approved</span>}</div>
        {d.versions.length === 0 ? <EmptyState icon="artwork" title="No artwork recorded">Artwork is pulled from DecoNetwork once the artwork fetch is connected, or can be uploaded by hand.</EmptyState> : d.versions.map((v) => <div key={v.id} className="row" style={{ justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--border)' }}><span><b>{v.area}</b> <span className="dim">v{v.version}{v.is_current ? '' : ' (old)'} · {v.process ?? '—'} · {v.file_format ?? '—'}{v.stitch_count ? ` · ${v.stitch_count.toLocaleString('en-GB')} stitches` : ''}</span></span><span className="row"><Status tone={v.approval_status === 'approved' ? 'good' : 'medium'}>{v.approval_status}</Status><Status plain>{v.storage_status.replace('_', ' ')}</Status></span></div>)}
        <h3>Job packs</h3>{d.packs.length === 0 ? <p className="dim">No job pack built yet.</p> : d.packs.map((p) => <div key={p.id} className="row" style={{ justifyContent: 'space-between' }}><span className="mono">{p.pack_ref} v{p.version} · {p.producer_name}</span><span className="row"><Status tone={p.status === 'ready' || p.status === 'sent' ? 'good' : 'high'}>{p.status}</Status>{p.is_stale && <Status tone="critical" plain>stale</Status>}</span></div>)}
        <p className="dim">Previewing, replacing and downloading files arrives with the artwork file workflow.</p>
      </div>}

      {tab === 'production' && d && <div className="stack">
        {d.steps.length === 0 ? <EmptyState icon="production" title="Not scheduled">{o.order_status === 'awaiting_stock' ? 'It joins the schedule once its stock is secured.' : 'Re-plan production to include it.'}</EmptyState> : d.steps.map((s) => (
          <Panel key={s.step_id} title={`${METHOD_LABEL[s.method_code] ?? s.method_code} · step ${s.step_no}`} actions={<><Status tone={s.is_late ? 'critical' : s.status === 'blocked' ? 'high' : 'info'}>{s.is_late ? 'Predicted late' : s.status}</Status>{s.is_bottleneck && <Status tone="high" plain>Bottleneck</Status>}</>}>
            <div className="stack"><Facts items={[['Machine', s.machine_code ?? 'Unassigned'], ['Units', s.units], ['Planned start', s.planned_start ? dateTime(s.planned_start) : '—'], ['Planned end', s.planned_end ? dateTime(s.planned_end) : '—'], ['Batch', s.batch_code], ['Estimated time', s.est_minutes ? `${Math.round(s.est_minutes)} min + ${Math.round(s.setup_minutes ?? 0)} setup` : '—']]} />
              <div className="callout soft"><b>System recommendation: position #{s.recommended_position ?? '–'}{s.is_overridden ? ` · currently pinned at #${s.sequence_position}` : ''}</b><span className="muted">{s.reason ?? s.blocked_reason}</span><div style={{ marginTop: 6 }}><ScoreBars parts={s.score_breakdown} /></div></div>
              {canAct && <div className="row"><Button size="sm" onClick={() => { setPin(s); setPinRank(String(s.sequence_position ?? 1)); }}>Override position…</Button>{s.is_overridden && <Tag>Manual override active</Tag>}</div>}</div>
          </Panel>))}
      </div>}

      {tab === 'producer' && d && <div className="stack">
        {d.tp ? <Facts items={[['Producer', d.tp.producer_name], ['Stage', d.tp.tp_status ? TP_STATUS_LABEL[d.tp.tp_status] ?? d.tp.tp_status : '—'], ['Movement', d.tp.movement_code], ['Expected return', shortDate(d.tp.expected_return_date)], ['Return overdue', d.tp.is_return_overdue ? 'Yes' : 'No'], ['At risk of missing due date', d.tp.at_risk_of_missing_due_date ? 'Yes' : 'No']]} /> : <EmptyState icon="producers" title="Not with a producer">This order is produced in-house or has not been routed yet.</EmptyState>}
        {d.moves.map((m) => <div key={m.movement_id} className="row wrap" style={{ justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid var(--border)' }}><span><b className="mono">{m.movement_code}</b> <span className="dim">{m.producer_name} · {m.units_sent} sent · {m.units_received_good} back</span></span><span className="row"><Status tone={m.is_overdue ? 'critical' : 'info'}>{TP_STATUS_LABEL[m.status] ?? m.status}</Status>{m.is_overdue && <span className="bad num">{m.days_overdue}d overdue</span>}</span></div>)}
      </div>}

      {tab === 'purchasing' && d && <div className="stack">
        <div className="row"><p className="muted grow">Compare suppliers and production routes for this order, with what-if costs.</p>{canAct && <Button variant="primary" icon="purchasing" onClick={() => setCompare(true)}>Compare options</Button>}</div>
        {d.sel && <div className="callout soft"><b>Saved recommendation ({d.sel.status})</b><span className="muted">{d.sel.explanation}</span></div>}
        <h3>Purchase orders buying stock for this order</h3>
        {d.pos.length === 0 ? <p className="dim">No ATAM_FLOW PO is linked to this order.</p> : d.pos.map((p) => <div key={p.po_id} className="row" style={{ justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--border)' }}><a className="mono" href={href('purchasing/' + p.po_id)}>{p.po_ref}</a><span className="muted">{p.supplier}</span><Status tone={p.is_late ? 'critical' : 'info'}>{p.po_status ? PO_STATUS_LABEL[p.po_status] : p.delivery_status}</Status><span className="num dim">{p.units_outstanding} outstanding · due {shortDate(p.expected_date)}</span></div>)}
      </div>}

      {tab === 'warehouse' && d && (d.bins.length === 0 ? <EmptyState icon="warehouse" title="Not in a bin">{bins.rows.length === 0 ? 'No bins have been set up yet.' : 'This order has no bin assigned.'}</EmptyState> : <div className="stack">{d.bins.map((b) => <div key={b.bin_id} className="row" style={{ justifyContent: 'space-between' }}><a className="mono" href={href('warehouse/' + b.bin_code)}>{b.bin_code}</a><span className="muted">{b.zone_name ?? b.zone_code}</span><Status>{b.status}</Status><span className="num dim">{b.units_in_bin} units</span></div>)}</div>)}

      {tab === 'exceptions' && d && (d.ex.length === 0 ? <EmptyState icon="check" title="No open exceptions" /> : <div className="stack">{d.ex.map((e) => <div key={e.id} className="callout soft"><div className="row wrap"><Status tone={e.severity as 'critical'}>{e.severity}</Status><b>{e.type_label}</b><a href={href('exceptions/' + e.exc_ref)}>{e.exc_ref}</a><span className={e.is_overdue ? 'bad' : 'dim'}>{deadlineText(e.response_deadline, e.is_overdue)}</span></div><p className="muted">{e.description}</p>{e.recommended_action && <p className="dim">→ {e.recommended_action}</p>}{e.financial_impact != null && <p className="dim num">{gbp(e.financial_impact)} at stake</p>}</div>)}</div>)}

      {tab === 'history' && (hist.loading ? <div className="stack"><Skeleton h={16} /><Skeleton h={16} w="80%" /><Skeleton h={16} w="60%" /></div> : hist.rows.length === 0 ? <EmptyState icon="clock" title="No history recorded yet" /> :
        <ul className="timeline">{hist.rows.map((h, i) => <li key={i} className={'k-' + h.kind}><b style={{ textTransform: 'capitalize' }}>{h.title}</b><span className="dim"> · {h.actor ?? 'system'} · {dateTime(h.at)}</span>{h.detail && <div className="muted">{h.detail}</div>}</li>)}</ul>)}

      <SelectionCompare open={compare} onClose={() => setCompare(false)} orderId={o.id} orderRef={o.order_ref} />
      <Modal open={!!pin} onClose={() => setPin(null)} title="Override production position">
        {pin && <div className="stack"><div className="callout soft"><b>System recommendation: position #{pin.recommended_position ?? '–'}</b><span className="muted">{pin.reason}</span></div>
          <Field label="Pin this job to position"><input className="input" inputMode="numeric" value={pinRank} onChange={(e) => setPinRank(e.target.value)} /></Field>
          <Field label="Why are you overriding the recommendation? (required)"><textarea className="textarea" rows={3} value={pinWhy} onChange={(e) => setPinWhy(e.target.value)} /></Field>
          {pinErr && <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{pinErr}</div>}
          <p className="dim">The override is marked on the schedule, the recommendation stays visible, and your name and reason go in the audit trail.</p>
          <div className="row"><Button variant="primary" disabled={!pinWhy.trim() || pinBusy} onClick={() => void savePin()}>{pinBusy ? 'Saving…' : 'Save override'}</Button><Button variant="ghost" onClick={() => setPin(null)}>Cancel</Button></div></div>}
      </Modal>
      <span className="sr-only"><OrderLink r={o.order_ref} /></span>
    </Drawer>
  );
}
