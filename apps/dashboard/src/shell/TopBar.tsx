import { useEffect, useRef, useState } from 'react';
import { Icon } from '../ui/Icon';
import { Button, Segmented } from '../ui/primitives';
import { RANGES, useCtx } from '../data/context';
import { useView } from '../data/store';
import { supabase } from '../lib/api';
import { WORKFLOWS, type WorkflowDef } from '../lib/workflows';
import { navigate } from '../router';
import { dateTime, minutesSince } from '../lib/format';
import type { NotificationRow, SyncRunRow } from '../data/types';

const WINDOWS: Record<string, number> = { sync_orders: 150, sync_stock: 400, sync_purchase_orders: 400 };
const NAMES: Record<string, string> = { sync_orders: 'Orders', sync_stock: 'Stock', sync_purchase_orders: 'Purchase orders' };

export function syncHealth(rows: SyncRunRow[]) {
  const items = Object.keys(WINDOWS).map((w) => { const r = rows.find((x) => x.workflow === w); const m = minutesSince(r?.last_ok_at ?? null); const bad = r?.last_status === 'failed'; return { w, name: NAMES[w], mins: m, state: bad ? 'bad' : m === null || m > WINDOWS[w] ? 'warn' : 'good', err: bad ? r?.last_error : null } as const; });
  const worst = items.some((i) => i.state === 'bad') ? 'bad' : items.some((i) => i.state === 'warn') ? 'warn' : 'good';
  const oldest = Math.max(...items.map((i) => i.mins ?? 0));
  return { items, worst, oldest };
}

export function TopBar({ onMenu, onCollapse, onSearch, onCreatePo, onGenerateLabels, onNewMovement, onRun, running, canRun, email }: { onMenu: () => void; onCollapse: () => void; onSearch: () => void; onCreatePo: () => void; onGenerateLabels: () => void; onNewMovement: () => void; onRun: (d: WorkflowDef) => void; running: string | null; canRun: (d: WorkflowDef) => boolean; email: string | null }) {
  const { range, setRange, role, canAct } = useCtx();
  const [open, setOpen] = useState<'quick' | 'sync' | 'bell' | 'user' | null>(null);
  const sync = useView<SyncRunRow>('ui_sync_runs'); const notes = useView<NotificationRow>('ui_notifications');
  const wrap = useRef<HTMLDivElement>(null);
  useEffect(() => { const c = (e: MouseEvent) => { if (!wrap.current?.contains(e.target as Node)) setOpen(null); }; const k = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(null); }; document.addEventListener('click', c); window.addEventListener('keydown', k); return () => { document.removeEventListener('click', c); window.removeEventListener('keydown', k); }; }, []);
  const h = syncHealth(sync.rows);
  const unread = notes.rows.filter((n) => !n.read_at && n.severity !== 'info').length;
  const toggle = (k: typeof open) => (e: React.MouseEvent) => { e.stopPropagation(); setOpen(open === k ? null : k); };
  return (
    <header className="topbar" ref={wrap}>
      <Button variant="ghost" icon="panel" onClick={onMenu} className="menu-btn" aria-label="Open menu" />
      <Button variant="ghost" icon="panel" onClick={onCollapse} aria-label="Collapse sidebar" className="hide-m" />
      <button className="cmd" onClick={onSearch} aria-label="Search everything (press / or Ctrl+K)"><Icon name="search" size={15} /><span className="grow">Search orders, SKUs, POs, bins, producers…</span><span className="kbds"><kbd>/</kbd> <kbd>⌘K</kbd></span></button>
      <span className="grow" />
      <Button icon="labels" onClick={() => window.dispatchEvent(new CustomEvent('atamflow:scan'))} aria-label="Scan a label"><span className="hide-m">Scan</span></Button>
      <div className="hide-m"><Segmented label="Time range" value={range} options={RANGES} onChange={setRange} /></div>
      <div style={{ position: 'relative' }}>
        <Button icon="bolt" variant="primary" onClick={toggle('quick')} aria-haspopup="menu" aria-expanded={open === 'quick'}><span className="hide-m">Quick actions</span></Button>
        {open === 'quick' && <div className="pop panel" role="menu">
          <h3>Run a workflow</h3>
          {WORKFLOWS.map((w) => <button key={w.id} className="item" role="menuitem" disabled={!canRun(w) || !!running} onClick={() => { setOpen(null); onRun(w); }}><Icon name={w.icon} /><span><b>{w.label}</b><small>{canRun(w) ? w.description : 'Not available for your role'}</small></span></button>)}
          <h3>Create</h3>
          <button className="item" role="menuitem" disabled={!canAct} onClick={() => { setOpen(null); onCreatePo(); }}><Icon name="plus" /><span><b>Purchase order</b><small>From orders waiting for stock</small></span></button>
          <button className="item" role="menuitem" disabled={!canAct} onClick={() => { setOpen(null); onNewMovement(); }}><Icon name="truck" /><span><b>Producer movement</b><small>Send goods to a producer</small></span></button>
          <button className="item" role="menuitem" disabled={!canAct} onClick={() => { setOpen(null); onGenerateLabels(); }}><Icon name="labels" /><span><b>Generate labels</b><small>Order, bin, stock, producer, dispatch</small></span></button>
        </div>}
      </div>
      <div style={{ position: 'relative' }}>
        <button className="pill" onClick={toggle('sync')} aria-haspopup="dialog" aria-expanded={open === 'sync'} aria-label="Sync status"><span className={`dot ${h.worst}`} /><span className="hide-m num">{sync.rows.length === 0 ? 'Sync unknown' : h.worst === 'bad' ? 'Sync failed' : h.worst === 'warn' ? 'Sync late' : `Synced ${h.oldest < 1 ? 'now' : h.oldest + ' min ago'}`}</span></button>
        {open === 'sync' && <div className="pop panel" role="dialog" aria-label="Sync status"><h3>DecoNetwork sync</h3>
          {h.items.map((i) => <div key={i.w} className="item" style={{ cursor: 'default' }}><span className={`dot ${i.state}`} /><span><b>{i.name}</b><small>{i.err ? `Failed: ${i.err}` : i.mins === null ? 'Never succeeded' : `Last success ${i.mins < 1 ? 'just now' : i.mins + ' min ago'}`}</small></span></div>)}
          <button className="item" onClick={() => { setOpen(null); navigate('exceptions'); }}><Icon name="exceptions" /><span>Sync problems appear in Exceptions</span></button></div>}
      </div>
      <div style={{ position: 'relative' }}>
        <span className="bell"><Button variant="ghost" icon="bell" onClick={toggle('bell')} aria-label={`Notifications${unread ? `, ${unread} unread` : ''}`} />
          {unread > 0 && <span className="count num" aria-hidden="true">{unread > 9 ? '9+' : unread}</span>}</span>
        {open === 'bell' && <div className="pop panel" role="dialog" aria-label="Notifications" style={{ maxHeight: 440, overflow: 'auto' }}><h3>Notifications</h3>
          {notes.rows.length === 0 && <div className="state"><p>Nothing new.</p></div>}
          {notes.rows.slice(0, 15).map((n) => <div key={n.id} className="item" style={{ cursor: 'default', alignItems: 'flex-start' }}><span className={`dot ${n.severity === 'critical' ? 'bad' : n.severity === 'warning' ? 'warn' : ''}`} style={{ marginTop: 6 }} /><span><b>{n.title}</b><small>{n.body}</small><small>{dateTime(n.created_at)}</small></span></div>)}
        </div>}
      </div>
      <div style={{ position: 'relative' }}>
        <Button variant="ghost" icon="user" onClick={toggle('user')} aria-label="Your account" />
        {open === 'user' && <div className="pop panel" role="menu"><div className="item" style={{ cursor: 'default' }}><Icon name="user" /><span><b>{email}</b><small>Role: {role ?? 'none'}</small></span></div>
          <button className="item" role="menuitem" onClick={() => void supabase.auth.signOut()}><Icon name="arrow" /><span>Sign out</span></button></div>}
      </div>
    </header>
  );
}
