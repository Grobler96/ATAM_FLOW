import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { whAction } from '../lib/warehouse';
import type { BinRow, OrderToBinRow, OrderRow } from '../data/types';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const done = (toast: ReturnType<typeof useToast>, title: string, body?: string) => { void refreshAll(); toast.push({ tone: 'good', title, body }); };

// Put an order into a bin. Shows the system's suggestion and why; breaking a bin rule needs a manager/admin override and a reason.
export function PutAwayDialog({ onClose, orderId, binCode }: { onClose: () => void; orderId?: string; binCode?: string }) {
  const bins = useView<BinRow>('ui_bins'), toBin = useView<OrderToBinRow>('ui_orders_to_bin'), orders = useView<OrderRow>('ui_orders'); const { senior } = useCtx(); const toast = useToast();
  const [oid, setOid] = useState(orderId ?? ''); const [bin, setBin] = useState(binCode ?? ''); const [units, setUnits] = useState(''); const [reason, setReason] = useState(''); const [override, setOverride] = useState(false);
  const [sug, setSug] = useState<{ bin_code: string; why: string } | null>(null); const [alts, setAlts] = useState<string[]>([]); const [sugMsg, setSugMsg] = useState<string | null>(null);
  const [warn, setWarn] = useState<string | null>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const order = orders.rows.find((o) => o.id === oid);
  useEffect(() => { if (order && !units) setUnits(String(order.total_units || '')); }, [order, units]);
  useEffect(() => {
    if (!oid) { setSug(null); return; } let live = true;
    void whAction('suggest_bin', { order_id: oid, units: Number(units) || undefined }).then((r) => { if (!live) return; const s = (r as any).suggestion; setSug(s ?? null); setAlts(((r as any).alternatives ?? []).map((a: any) => a.bin_code)); setSugMsg(s ? null : String((r as any).message ?? r.error ?? '')); if (s && !bin) setBin(s.bin_code); });
    return () => { live = false; };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [oid]);
  async function go() {
    setBusy(true); setErr(null);
    const r: any = await whAction('assign_bin', { order_id: oid, bin_code: bin, units: Number(units), override, reason });
    setBusy(false);
    if (r.ok === false) { if (r.needs_override) { setWarn(String(r.error)); if (!senior) setErr('This breaks a bin rule. Ask a manager or admin to approve it, or choose another bin.'); return; } setErr(String(r.error ?? 'Could not put the order away.')); return; }
    done(toast, `${r.order_ref} put away in ${r.bin_code}`, r.overridden ? 'Rule override recorded with your reason.' : `${r.units_in_bin} unit(s) now in the bin.`); onClose();
  }
  const pickable = toBin.rows.length ? toBin.rows : [];
  return (
    <Modal open onClose={onClose} title="Put order away in a bin">
      <div className="stack">
        {!orderId && <Field label="Order"><select className="select" value={oid} onChange={(e) => { setOid(e.target.value); setUnits(''); setBin(''); setWarn(null); }}><option value="">Choose an order…</option>{pickable.length > 0 && <optgroup label="Not in a bin yet">{pickable.map((o) => <option key={o.order_id} value={o.order_id}>{o.order_ref} · {o.customer_name} · {o.total_units} units</option>)}</optgroup>}<optgroup label="Any open order">{orders.rows.filter((o) => !o.shipped_at && !pickable.some((p) => p.order_id === o.id)).slice(0, 300).map((o) => <option key={o.id} value={o.id}>{o.order_ref} · {o.customer_name}</option>)}</optgroup></select></Field>}
        {order && <p className="muted">{order.order_ref} · {order.customer_name} · {order.total_units} units</p>}
        {oid && (sug ? <div className="callout" role="status"><b>Suggested: <span className="mono">{sug.bin_code}</span></b><br />{sug.why}{alts.length > 0 && <><br /><span className="dim">Also possible: {alts.join(', ')}</span></>}</div> : sugMsg ? <div className="callout" role="status">{sugMsg}</div> : null)}
        <Field label="Bin"><input className="input mono" list="bin-options" value={bin} onChange={(e) => { setBin(e.target.value.toUpperCase()); setWarn(null); }} placeholder="e.g. STG-01" /><datalist id="bin-options">{bins.rows.filter((b) => b.is_active).map((b) => <option key={b.bin_id} value={b.bin_code}>{b.units_in_bin} in bin</option>)}</datalist></Field>
        <Field label="Units going into the bin"><input className="input" type="number" min={1} value={units} onChange={(e) => { setUnits(e.target.value); setWarn(null); }} /></Field>
        {warn && <div className="callout" role="alert"><b>Rule check:</b> {warn}{senior && <><label className="check" style={{ marginTop: 8 }}><input type="checkbox" checked={override} onChange={(e) => setOverride(e.target.checked)} />Override this rule</label>{override && <input className="input" style={{ marginTop: 6 }} placeholder="Reason for the override (required, recorded in the audit trail)" value={reason} onChange={(e) => setReason(e.target.value)} />}</>}</div>}
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={!oid || !bin || !Number(units) || busy || (!!warn && (!override || reason.trim().length < 5))} onClick={() => void go()}>{busy ? 'Saving…' : 'Put away'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

// Create a run of bins in a zone: prefix + numbers, optional capacity.
export function CreateBinsDialog({ onClose }: { onClose: () => void }) {
  const [zone, setZone] = useState('STG'); const [prefix, setPrefix] = useState('STG'); const [count, setCount] = useState('10'); const [cap, setCap] = useState(''); const [type, setType] = useState('bin_bay'); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r: any = await whAction('create_bins', { zone, prefix, count: Number(count), capacity: cap ? Number(cap) : null, location_type: type }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'Could not create the bins.')); return; } done(toast, `${r.created} bin(s) created`, `Starting at ${r.first_code}. Generate their labels from the Labels page.`); onClose(); }
  return (
    <Modal open onClose={onClose} title="Create bins">
      <div className="stack">
        <Field label="Zone"><select className="select" value={zone} onChange={(e) => setZone(e.target.value)}><option value="RECV">Receiving (RECV)</option><option value="STG">Staging (STG)</option><option value="WIP">Work in progress (WIP)</option><option value="DISP">Dispatch (DISP)</option></select></Field>
        <Field label="Bin prefix (letters/numbers)"><input className="input mono" value={prefix} onChange={(e) => setPrefix(e.target.value.toUpperCase())} maxLength={8} /></Field>
        <Field label="How many"><input className="input" type="number" min={1} max={200} value={count} onChange={(e) => setCount(e.target.value)} /></Field>
        <Field label="Type"><select className="select" value={type} onChange={(e) => setType(e.target.value)}>{['bin_bay', 'box', 'bucket', 'shelf', 'pallet', 'cage', 'staging', 'receiving'].map((t) => <option key={t} value={t}>{t.replace('_', ' ')}</option>)}</select></Field>
        <Field label="Capacity in units (blank = no limit)"><input className="input" type="number" min={1} value={cap} onChange={(e) => setCap(e.target.value)} /></Field>
        <p className="dim">Bins are numbered on from the last one with this prefix (for example STG-01, STG-02…). Creating them again never duplicates a bin.</p>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || !prefix || !Number(count)} onClick={() => void go()}>{busy ? 'Creating…' : 'Create bins'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

// Anything that needs a short written reason: release, empty, status change, move.
export function ReasonDialog({ title, intro, confirm, action, params, presets, extra, onClose }: { title: string; intro: string; confirm: string; action: string; params: Record<string, unknown>; presets: string[]; extra?: React.ReactNode; onClose: () => void }) {
  const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  async function go() { setBusy(true); setErr(null); const r = await whAction(action, { ...params, reason }); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } done(toast, title, r.note); onClose(); }
  return (
    <Modal open onClose={onClose} title={title}>
      <div className="stack"><p>{intro}</p>{extra}
        <div className="row wrap">{presets.map((p) => <button key={p} className="chip" onClick={() => setReason(p)}>{p}</button>)}</div>
        <Field label="Reason (recorded in the audit trail)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || reason.trim().length < 3} onClick={() => void go()}>{busy ? 'Working…' : confirm}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
