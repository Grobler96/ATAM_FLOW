import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { setOrderScope } from '../lib/scope';
import { planMakeThirdParty, reasonOk, summarise, type TpCandidate, type TpResult } from '../lib/makeThirdParty';
import type { OrderDecoratorRow } from '../data/types';

const PRESETS = ['Customer wants it decorated by a third party', 'Too big for the in-house machines', 'Not marked as a priority in DecoNetwork'];

// Switches the ticked orders to third-party in one go, with one reason. It uses the same audited per-order scope setting as the order drawer, so the
// rules are unchanged: it wins over DecoNetwork's Priority flag, and each order is recorded separately.
export function MakeThirdPartyDialog({ rows, onClose }: { rows: TpCandidate[]; onClose: () => void }) {
  const dec = useView<OrderDecoratorRow>('ui_order_decorator_named'); const toast = useToast();
  const plan = useMemo(() => planMakeThirdParty(rows), [rows]);
  const defaultName = dec.rows.find((d) => d.scope === 'third_party' && d.is_default && d.producer_name)?.producer_name ?? null;
  const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [done, setDone] = useState<TpResult | null>(null);

  async function go() {
    setBusy(true); const res: TpResult = { ok: [], failed: [] };
    for (const o of plan.toSwitch) {
      const r = await setOrderScope(o.id, 'third_party', reason.trim());
      if (r.ok === false) res.failed.push({ ref: o.ref, error: String(r.error ?? 'That did not work.') }); else res.ok.push(o.ref);
    }
    setBusy(false); setDone(res); void refreshAll();
    if (res.ok.length) toast.push({ tone: res.failed.length ? 'info' : 'good', title: summarise(res), body: 'They now show under 3PD Orders. Re-plan production to apply it.' });
  }
  return (
    <Modal open onClose={onClose} title="Make third-party">
      <div className="stack">
        {!done && <>
          <p><b>{plan.toSwitch.length}</b> order{plan.toSwitch.length === 1 ? '' : 's'} will be treated as third-party: <span className="mono">{plan.toSwitch.slice(0, 12).map((o) => o.ref).join(', ')}{plan.toSwitch.length > 12 ? ` and ${plan.toSwitch.length - 12} more` : ''}</span>.</p>
          <p className="dim">They are left out of in-house planning and go to {defaultName ? <b>{defaultName}</b> : 'the default decorator'} unless you change the decorator on the order. This overrides DecoNetwork's Priority flag for these orders, and each one is recorded in the audit trail.</p>
          {plan.already.length > 0 && <p className="dim">{plan.already.length} ticked order{plan.already.length === 1 ? ' is' : 's are'} already third-party and will be skipped.</p>}
          {plan.outOfScope.length > 0 && <p className="warn" role="status">{plan.outOfScope.length} ticked order{plan.outOfScope.length === 1 ? ' is' : 's are'} marked out of scope ({plan.outOfScope.map((o) => o.ref).join(', ')}) and will not be changed. Change those one at a time from the order if you mean to.</p>}
          <Field label="Why? (recorded in the audit trail)">
            <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} list="tp-reasons" placeholder="At least 5 characters" />
            <datalist id="tp-reasons">{PRESETS.map((p) => <option key={p} value={p} />)}</datalist>
          </Field>
          <div className="row"><Button variant="primary" disabled={busy || plan.toSwitch.length === 0 || !reasonOk(reason)} onClick={() => void go()}>{busy ? 'Switching…' : `Make ${plan.toSwitch.length} third-party`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
        </>}
        {done && <>
          <p role="status"><b>{summarise(done)}</b></p>
          {done.failed.length > 0 && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{done.failed.map((f) => <div key={f.ref}><b>{f.ref}</b>: {f.error}</div>)}</div>}
          <div className="row"><Button variant="primary" onClick={onClose}>Done</Button></div>
        </>}
      </div>
    </Modal>
  );
}
