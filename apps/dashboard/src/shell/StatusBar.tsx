import { useEffect, useState } from 'react';
import { useCtx } from '../data/context';
import { useView } from '../data/store';
import type { SyncRunRow } from '../data/types';
import { syncHealth } from './TopBar';

export function StatusBar() {
  const { role, email } = useCtx(); const sync = useView<SyncRunRow>('ui_sync_runs');
  const [online, setOnline] = useState(navigator.onLine); const [now, setNow] = useState(Date.now());
  useEffect(() => { const on = () => setOnline(true), off = () => setOnline(false); window.addEventListener('online', on); window.addEventListener('offline', off); const t = setInterval(() => setNow(Date.now()), 30_000); return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off); clearInterval(t); }; }, []);
  const h = syncHealth(sync.rows);
  return (
    <footer className="statusbar" role="contentinfo">
      <span className="row" style={{ gap: 6 }}><span className={`dot ${online ? 'good' : 'bad'}`} />{online ? 'Online' : 'Offline: showing last loaded data'}</span>
      <span className="hide-m">DecoNetwork data: {sync.rows.length ? (h.oldest < 1 ? 'just synced' : `up to ${h.oldest} min old`) : 'unknown'}</span>
      <span className="hide-m">Screen refreshed {new Date(now).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}</span>
      <span className="grow" /><span className="hide-m">{email} · {role ?? 'no role'}</span><span className="hide-m"><kbd>?</kbd> shortcuts</span>
    </footer>
  );
}
