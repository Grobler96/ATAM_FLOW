import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status, Tag } from '../ui/primitives';
import { exceptionActionTo } from '../lib/api';
import { money, shortDate } from '../lib/domain';
import { useCtx } from '../data/context';

interface Option { key: string; supplier_plan: string; route: { name: string; type: string; supplier_direct_to_producer: boolean }; costs: { total: number; blanks: number; supplier_delivery: number; decoration: number; transport_to_producer: number; transport_back: number; stock_on_hand_value: number };
  revenue: number; profit: number; margin_pct: number | null; cost_per_unit: number | null; timeline: { total_days: number; ready_date: string; slack_days: number | null }; risk: { score: number; flags: { code: string; text: string }[] };
  score: number; incomplete: boolean; late: boolean; labels: string[]; score_parts: Record<string, number> }
interface Result { ok?: boolean; options: Option[]; recommended_key: string | null; selected_key: string | null; explanation: string; rejected: { what: string; reason: string }[]; error?: string }

// Compares every supplier x production route for one order, with what-if inputs. Choosing a row is instant (all options are calculated together);
// changing costs or quantity asks the engine again. Choosing something other than the recommendation needs a reason, and the choice is audited.
export function SelectionCompare({ open, onClose, orderId, orderRef }: { open: boolean; onClose: () => void; orderId: string; orderRef: string }) {
  const [res, setRes] = useState<Result | null>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const [key, setKey] = useState<string | null>(null); const [adj, setAdj] = useState('0'); const [mult, setMult] = useState('1'); const [reason, setReason] = useState('');
  const { senior } = useCtx(); const toast = useToast();

  async function run(overrides?: Record<string, unknown>) {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('selection', 'recommend', { order_id: orderId, overrides }) as unknown as Result & { ok?: boolean };
    setBusy(false);
    if (r.ok === false || !r.options) { setErr(r.error ?? 'Could not compare options.'); return; }
    setRes(r); setKey(r.selected_key ?? r.recommended_key);
  }
  const cur = res?.options.find((o) => o.key === key) ?? null; const rec = res?.options.find((o) => o.key === res.recommended_key) ?? null;
  const whatIf = useMemo(() => adj !== '0' || mult !== '1', [adj, mult]);
  async function confirm() {
    if (!cur) return;
    const r = await exceptionActionTo('selection', 'confirm', { order_id: orderId, key: cur.key, reason: reason || undefined });
    if (r.ok === false) { setErr(String(r.error)); return; }
    toast.push({ tone: 'good', title: 'Choice confirmed', body: `${cur.supplier_plan} + ${cur.route.name}. Next: create the PO, then build the job pack.` }); onClose();
  }
  return (
    <Modal open={open} onClose={onClose} title={`Supplier & producer options · ${orderRef}`}>
      <div className="stack" style={{ minWidth: 0 }}>
        {!res && !busy && !err && <div className="row"><p className="muted grow">Compares every supplier and production route on landed cost, margin, speed and risk.</p><Button variant="primary" onClick={() => void run()}>Compare options</Button></div>}
        {busy && <p className="muted" role="status">Calculating…</p>}
        {err && <div className="callout" role="alert" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }}>{err}</div>}
        {res && <>
          <div className="callout"><b>Recommendation</b><span>{res.explanation}</span></div>
          <div style={{ overflow: 'auto', maxHeight: 280 }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
            <thead><tr className="dim" style={{ textAlign: 'left' }}>{['Supplier', 'Route', 'Cost', 'Margin', 'Ready', 'Risk', 'Score'].map((h) => <th key={h} style={{ padding: '4px 8px' }}>{h}</th>)}</tr></thead>
            <tbody>{res.options.map((o) => <tr key={o.key} onClick={() => setKey(o.key)} style={{ cursor: 'pointer', background: key === o.key ? 'var(--accent-soft)' : undefined, opacity: o.incomplete ? 0.55 : 1 }}>
              <td style={{ padding: '6px 8px' }}>{o.supplier_plan} {o.labels.map((l) => <Tag key={l}>{l}</Tag>)}</td><td style={{ padding: '6px 8px' }}>{o.route.name}{o.route.supplier_direct_to_producer ? ' (direct)' : ''}</td>
              <td className="num" style={{ padding: '6px 8px' }}>{o.incomplete ? 'incomplete' : money(o.costs.total, 2)}</td><td className="num" style={{ padding: '6px 8px' }}>{o.margin_pct == null ? '—' : o.margin_pct + '%'}</td>
              <td className="num" style={{ padding: '6px 8px' }}>{shortDate(o.timeline.ready_date)}{o.late && <Status tone="critical" plain> late</Status>}</td><td className="num" style={{ padding: '6px 8px' }}>{o.risk.score}</td><td className="num" style={{ padding: '6px 8px' }}>{o.score}</td></tr>)}</tbody></table></div>
          {cur && <div className="facts"><div><dt>Total cost</dt><dd className="num">{money(cur.costs.total, 2)} ({money(cur.cost_per_unit, 2)}/unit)</dd></div><div><dt>Profit</dt><dd className="num">{money(cur.profit, 2)}{cur.margin_pct != null ? ` · ${cur.margin_pct}%` : ''}</dd></div>
            <div><dt>Blanks / delivery</dt><dd className="num">{money(cur.costs.blanks, 2)} / {money(cur.costs.supplier_delivery, 2)}</dd></div><div><dt>Decoration</dt><dd className="num">{money(cur.costs.decoration, 2)}</dd></div>
            <div><dt>Transport</dt><dd className="num">{money(cur.costs.transport_to_producer + cur.costs.transport_back, 2)}</dd></div><div><dt>Ready</dt><dd className="num">{shortDate(cur.timeline.ready_date)} · {cur.timeline.slack_days == null ? '' : cur.timeline.slack_days + ' days spare'}</dd></div></div>}
          {cur && cur.risk.flags.length > 0 && <div className="row wrap">{cur.risk.flags.map((f) => <Tag key={f.code} block={['late', 'incomplete'].includes(f.code)}>{f.text}</Tag>)}</div>}
          {res.rejected.length > 0 && <details className="dim"><summary>{res.rejected.length} option(s) ruled out</summary><ul>{res.rejected.map((r) => <li key={r.what}>{r.what}: {r.reason}</li>)}</ul></details>}
          <div className="row wrap"><Field label="Blank cost change %"><input className="input" style={{ width: 110 }} inputMode="decimal" value={adj} onChange={(e) => setAdj(e.target.value)} /></Field><Field label="Quantity ×"><input className="input" style={{ width: 90 }} inputMode="decimal" value={mult} onChange={(e) => setMult(e.target.value)} /></Field>
            <Button style={{ alignSelf: 'end' }} onClick={() => void run({ supplier_cost_adjust_pct: Number(adj) || 0, qty_multiplier: Number(mult) || 1 })} disabled={busy}>Recalculate what-if</Button></div>
          {whatIf && <p className="dim">What-if figures are not saved and cannot be confirmed.</p>}
          {senior && cur && !whatIf && !cur.incomplete && <div className="stack"><Field label={cur.key === rec?.key ? 'Note (optional)' : 'Why not the recommendation? (required)'}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
            <div className="row"><Button variant="primary" disabled={cur.key !== rec?.key && !reason.trim()} onClick={() => void confirm()}>Confirm this choice</Button><span className="dim">Recorded in the audit trail. This does not raise a PO or move stock.</span></div></div>}
        </>}
      </div>
    </Modal>
  );
}
