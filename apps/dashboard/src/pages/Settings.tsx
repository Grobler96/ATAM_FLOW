import { useState } from 'react';
import { Panel, Facts, Skeleton } from '../ui/primitives';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { money } from '../lib/domain';
import { rulesFrom } from '../lib/purchasing';
import type { SettingRow } from '../data/types';

// The purchasing rules in plain words. Read-only: there is no screen action that changes them, and the chasing switch in particular stays off
// because no emails are being sent yet (chases are only ever drafts that wait for review).
function PurchasingRulesPanel({ rows, loading }: { rows: SettingRow[]; loading: boolean }) {
  const r = rulesFrom(rows);
  return (
    <Panel title="Purchasing rules" icon="settings">
      {loading ? <Skeleton h={90} /> : <div className="stack">
        <Facts items={[
          ['Approval limit', `${money(r.approve_over_value, 2)}. A manager or admin can approve a PO up to this; over it, only an admin can.`],
          ['Approving your own PO', r.no_self_approval ? 'Not allowed, unless an admin gives a reason (which is recorded).' : 'Allowed.'],
          ['Invoice tolerance', `An invoice may differ from what was received by ${r.invoice_tolerance_pct}% or ${money(r.invoice_tolerance_value, 2)}, whichever is larger.`],
          ['Chase a PO when', `it is at least ${r.chase_min_days_late} days late (or sent and not acknowledged for a day), and again after ${r.chase_repeat_days} days.`]]} />
        <div className="stack" style={{ gap: 4 }}>
          <label className="check"><input type="checkbox" role="switch" checked={r.chase_enabled} disabled readOnly aria-describedby="chase-why" /> Scheduled chasing: {r.chase_enabled ? 'on' : 'off'}</label>
          <span id="chase-why" className="dim">{r.chase_enabled ? 'It is on in the database. Chases are only ever saved as drafts for you to review; nothing is sent. This switch cannot be changed from here.' : 'Switched off, and it cannot be switched on from here. No emails are being sent yet; when chasing is on, it only saves drafts for you to review.'}</span>
        </div>
        <p className="dim" style={{ margin: 0 }}>These are placeholder values until the business sets real ones. Today they are changed in the database; the current values and when they last changed are listed below under purchasing.rules.</p>
      </div>}
    </Panel>
  );
}

export function SettingsPage() {
  const s = useView<SettingRow>('ui_settings'); const { role, email } = useCtx(); const [openKey, setOpenKey] = useState<string | null>(null);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Settings</h1><p>Every weight, threshold, deadline and assumption the engines use. They are read-only here; they are changed in the database for now, and each is explained so nothing is a black box.</p></div></div>
      <Panel title="Your account" icon="user"><Facts items={[['Signed in as', email], ['Role', role ?? 'none'], ['What your role can do', role === 'admin' || role === 'manager' ? 'Everything, including write-offs, overrides and supplier choices' : role === 'viewer' ? 'View only' : 'Work exceptions, run workflows for your area, create POs']]} /></Panel>
      <PurchasingRulesPanel rows={s.rows} loading={s.loading} />
      <Panel title="Engine and automation settings" icon="settings" count={s.rows.length} flush>
        {s.loading ? <div style={{ padding: 16 }}><Skeleton h={90} /></div> : s.rows.map((r) => (
          <div key={r.key} style={{ borderBottom: '1px solid var(--border)' }}>
            <button className="row" style={{ width: '100%', padding: '12px 16px', background: 'none', border: 0, textAlign: 'left', gap: 12 }} onClick={() => setOpenKey(openKey === r.key ? null : r.key)} aria-expanded={openKey === r.key}>
              <b className="mono" style={{ minWidth: 220 }}>{r.key}</b><span className="muted grow">{r.description}</span><span className="dim">{dateTime(r.updated_at)}</span></button>
            {openKey === r.key && <pre className="mono" style={{ margin: 0, padding: '0 16px 16px', overflow: 'auto', color: 'var(--text-2)', fontSize: 12 }}>{JSON.stringify(r.value, null, 2)}</pre>}
          </div>))}
      </Panel>
    </div>
  );
}
