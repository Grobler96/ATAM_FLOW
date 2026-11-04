import { useState } from 'react';
import { Panel, Facts, Skeleton } from '../ui/primitives';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import type { SettingRow } from '../data/types';

export function SettingsPage() {
  const s = useView<SettingRow>('ui_settings'); const { role, email } = useCtx(); const [openKey, setOpenKey] = useState<string | null>(null);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Settings</h1><p>Every weight, threshold, deadline and assumption the engines use. They are read-only here; they are changed in the database for now, and each is explained so nothing is a black box.</p></div></div>
      <Panel title="Your account" icon="user"><Facts items={[['Signed in as', email], ['Role', role ?? 'none'], ['What your role can do', role === 'admin' || role === 'manager' ? 'Everything, including write-offs, overrides and supplier choices' : role === 'viewer' ? 'View only' : 'Work exceptions, run workflows for your area, create POs']]} /></Panel>
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
