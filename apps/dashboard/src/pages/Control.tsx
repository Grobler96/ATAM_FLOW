import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, EmptyState, Field, Panel, Skeleton, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { loadPreview, SCOPE_HELP, SCOPE_LABEL, setSwitch, type OrderScopeRow, type Preview, type ScopeLogRow, type SwitchRow } from '../lib/scope';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

// One place to see and change what ATAM_FLOW looks after. Every change shows what it touches first, needs a reason, and is logged.
export function ControlPage() {
  const sw = useView<SwitchRow>('ui_scope_switches'); const log = useView<ScopeLogRow>('ui_scope_log'); const scopes = useView<OrderScopeRow>('ui_order_scope'); const { role } = useCtx();
  const admin = role === 'admin'; const [target, setTarget] = useState<SwitchRow | null>(null);
  const master = sw.rows.find((s) => s.key === 'inhouse.master'); const methods = sw.rows.filter((s) => s.key !== 'inhouse.master').sort((a, b) => a.sort_order - b.sort_order);
  const counts = scopes.rows.reduce<Record<string, number>>((m, r) => { m[r.scope] = (m[r.scope] ?? 0) + 1; return m; }, {});
  const overrides = scopes.rows.filter((r) => r.source === 'override');
  const logs = [...log.rows].sort((a, b) => b.at.localeCompare(a.at)).slice(0, 25);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Control</h1><p>What ATAM_FLOW looks after. Changes are recorded with who, when and why, and can be undone.</p></div></div>
      {!admin && <div className="callout" role="status">Only an admin can change the switches. You can see what they are set to and who changed them.</div>}

      <Panel title="In-house production" icon="settings">
        {sw.loading || !master ? <Skeleton h={60} /> : <div className="stack">
          <div className="row wrap" style={{ gap: 12 }}>
            <Status tone={master.enabled ? 'good' : 'high'}>{master.enabled ? 'On' : 'Off'}</Status>
            <span className="grow">{master.enabled ? 'Your own machines are planned by the scheduler.' : 'Third-party only: the scheduler plans nothing in-house, and machine problems are not raised. Nothing is deleted.'}</span>
            <Button variant={master.enabled ? 'danger' : 'primary'} disabled={!admin} title={admin ? '' : 'Admin only'} onClick={() => setTarget(master)}>{master.enabled ? 'Switch off…' : 'Switch on…'}</Button>
          </div>
          <p className="dim">{master.changed_at ? `Last changed ${dateTime(master.changed_at)} by ${master.changed_by ?? '—'}: ${master.reason ?? ''}` : 'Never changed.'}</p>
        </div>}
      </Panel>

      <Panel title="By process" icon="production">
        <p className="dim" style={{ marginTop: 0 }}>A process is planned in-house only when both the master switch and its own switch are on. Use these when you outsource one process and keep others.</p>
        <div className="stack" style={{ gap: 6 }}>
          {methods.map((m) => (
            <div key={m.key} className="row wrap" style={{ gap: 12 }}>
              <b style={{ minWidth: 150 }}>{m.label}</b><Status tone={m.enabled ? 'good' : 'high'} plain>{m.enabled ? 'In-house' : 'Producers only'}</Status>
              <span className="dim grow">{m.changed_at ? `${dateTime(m.changed_at)} · ${m.changed_by ?? '—'} · ${m.reason ?? ''}` : ''}</span>
              <Button size="sm" disabled={!admin} onClick={() => setTarget(m)}>{m.enabled ? 'Switch off…' : 'Switch on…'}</Button>
            </div>))}
        </div>
      </Panel>

      <Panel title="Orders by scope" icon="orders">
        <div className="row wrap" style={{ gap: 18 }}>
          {(['third_party', 'in_house', 'unclassified', 'out_of_scope'] as const).map((k) => <div key={k} style={{ minWidth: 160 }}><div style={{ fontSize: 24, fontWeight: 600 }}>{counts[k] ?? 0}</div><b>{SCOPE_LABEL[k]}</b><div className="dim">{SCOPE_HELP[k]}</div></div>)}
        </div>
        <p className="dim">The DecoNetwork "priority order" shield will set Third-party automatically once it is connected. Until then, set an order's scope by hand from its Changes &amp; control tab. A manual setting always wins over the shield.</p>
        {overrides.length > 0 && <><h3>Set by hand ({overrides.length})</h3><div className="stack" style={{ gap: 2 }}>{overrides.slice(0, 15).map((o) => <div key={o.order_id} className="row wrap" style={{ gap: 10 }}><a className="mono" href={'#/orders/' + o.order_ref.replace('#', '')}>{o.order_ref}</a><Status tone="info" plain>{SCOPE_LABEL[o.scope]}</Status><span className="dim grow">{o.scope_reason} · {o.scope_by} · {o.scope_at ? dateTime(o.scope_at) : ''}</span></div>)}</div></>}
      </Panel>

      <Panel title="Recent changes" icon="clock">
        {logs.length === 0 ? <EmptyState icon="clock" title="Nothing changed yet" /> : <div className="stack" style={{ gap: 2 }}>{logs.map((l) => <div key={l.id} className="row wrap" style={{ gap: 10 }}><span className="dim" style={{ minWidth: 130 }}>{dateTime(l.at)}</span><b>{l.target}</b><span className="muted">{l.was} → {l.now}</span><span className="dim grow">{l.actor} · {l.reason}</span></div>)}</div>}
      </Panel>
      {target && <SwitchDialog sw={target} onClose={() => { setTarget(null); void refreshAll(); }} />}
    </div>
  );
}

function SwitchDialog({ sw, onClose }: { sw: SwitchRow; onClose: () => void }) {
  const to = !sw.enabled; const [pv, setPv] = useState<Preview | null | undefined>(undefined); const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast();
  useEffect(() => { let live = true; void loadPreview(sw.key, to).then((p) => { if (live) setPv(p); }); return () => { live = false; }; }, [sw.key, to]);
  async function go() { setBusy(true); setErr(null); const r = await setSwitch(sw.key, to, reason); setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title: `${sw.label} switched ${to ? 'on' : 'off'}`, body: 'Re-plan production to apply it. Your reason is recorded.' }); onClose(); }
  return (
    <Modal open onClose={onClose} title={`Switch ${sw.label.toLowerCase()} ${to ? 'on' : 'off'}`}>
      <div className="stack">
        <h3>What this affects</h3>
        {pv === undefined ? <Skeleton h={50} /> : pv === null ? <p className="dim">Could not work out the effect. You can still go ahead.</p> : <ul className="plain">
          <li>{pv.planned_steps} planned job step(s) across {pv.orders} order(s) {to ? 'will be planned again at the next re-plan' : 'drop out of the plan at the next re-plan (nothing is deleted)'}.</li>
          {!to && pv.exceptions_cleared > 0 && <li>{pv.exceptions_cleared} machine exception(s) will clear.</li>}
          {!to && pv.running_steps > 0 && <li><b>{pv.running_steps} job(s) are running on the floor.</b> Finish or stop them first.</li>}
        </ul>}
        <Field label="Why? (recorded)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="For example: launching with third-party work only" /></Field>
        {err && <Err m={err} />}
        <div className="row"><Button variant={to ? 'primary' : 'danger'} disabled={busy || reason.trim().length < 5 || !!pv?.blocked_by_running} onClick={() => void go()}>{busy ? 'Saving…' : `Switch ${to ? 'on' : 'off'}`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
        <p className="dim">You can reverse this at any time from this page.</p>
      </div>
    </Modal>
  );
}
