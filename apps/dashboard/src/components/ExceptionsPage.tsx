import { useEffect, useMemo, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase, runCheckNow } from '../lib/api';
import { useSnapshot } from '../hooks';
import { STALE_AFTER_MIN } from '../config';
import { AGE_BUCKETS, DEFAULT_FILTERS, SORTS, VIEWS, ageCounts, applyFilters, kpis, toCsv, viewCounts, type Filters, type SortKey } from '../lib/filters';
import { gbp, minutesSince } from '../lib/format';
import type { ExceptionRow } from '../types';
import { ExceptionCard } from './ExceptionCard';
import { DetailDrawer } from './DetailDrawer';
import { RaiseDialog } from './RaiseDialog';

export function ExceptionsPage({ session }: { session: Session }) {
  const { snap, error, loading, refreshing, online, refresh } = useSnapshot(true);
  const [filters, setFilters] = useState<Filters>(DEFAULT_FILTERS);
  const [openId, setOpenId] = useState<string | null>(null);
  const [raising, setRaising] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const me = session.user.email ?? null;
  const role = snap?.role ?? null;
  const canAct = role !== null && role !== 'viewer';

  useEffect(() => { if (!toast) return; const t = setTimeout(() => setToast(null), 5000); return () => clearTimeout(t); }, [toast]);

  const rows = snap?.rows ?? [];
  const shown = useMemo(() => applyFilters(rows, filters, me), [rows, filters, me]);
  const counts = useMemo(() => viewCounts(rows), [rows]);
  const ages = useMemo(() => ageCounts(rows), [rows]);
  const k = useMemo(() => kpis(rows), [rows]);
  const open = openId ? rows.find((r) => r.id === openId) ?? null : null;

  const lastMin = minutesSince(snap?.status?.last_detection_at ?? null);
  const stale = snap ? lastMin === null || lastMin > STALE_AFTER_MIN : false;
  const set = <K extends keyof Filters>(key: K, value: Filters[K]) => setFilters((f) => ({ ...f, [key]: value }));

  async function checkNow() {
    setChecking(true);
    const r = await runCheckNow();
    setToast(r.ok === false ? (r.error ?? 'The check did not run.') : 'Check complete. The list has been updated.');
    await refresh(); setChecking(false);
  }
  function exportCsv() {
    const blob = new Blob([toCsv(shown)], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `atam-flow-exceptions-${new Date().toISOString().slice(0, 10)}.csv`; a.click(); URL.revokeObjectURL(a.href);
  }

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand"><span className="logo" aria-hidden="true" />ATAM_FLOW</div>
        <nav aria-label="Pages"><a className="active" href="#/exceptions" aria-current="page">Exceptions</a></nav>
        <div className="who"><span className="muted who-name">{me}{role ? ` · ${role}` : ''}</span><button className="btn small" onClick={() => void supabase.auth.signOut()}>Sign out</button></div>
      </header>

      {!online && <div className="banner warn" role="status">You are offline. Showing the last data loaded{snap ? ` at ${new Date(snap.fetchedAt).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}` : ''}.</div>}
      {error && online && <div className="banner bad" role="alert">Could not refresh: {error}. {snap ? 'Showing the last data loaded.' : ''} <button className="link" onClick={() => void refresh()}>Try again</button></div>}
      {stale && <div className="banner warn" role="status">{lastMin === null ? 'The automatic check has never run.' : `The automatic check last ran ${lastMin >= 120 ? Math.round(lastMin / 60) + ' hours' : lastMin + ' minutes'} ago.`} This list may be out of date.</div>}
      {role === 'viewer' && <div className="banner info" role="status">You have view-only access.</div>}

      <main className="page">
        <div className="page-head">
          <div><h1>Exceptions &amp; issues</h1>
            <p className="muted">{snap ? <>Checked {lastMin === null ? 'never' : lastMin < 1 ? 'just now' : lastMin + ' min ago'}{refreshing ? ' · refreshing…' : ''}</> : 'Loading…'}</p></div>
          <div className="actions">
            {canAct && <button className="btn primary" onClick={() => setRaising(true)}>Raise an issue</button>}
            {canAct && <button className="btn" onClick={() => void checkNow()} disabled={checking}>{checking ? 'Checking…' : 'Check now'}</button>}
            <button className="btn" onClick={exportCsv} disabled={!shown.length}>Export CSV</button>
          </div>
        </div>

        <section className="kpis" aria-label="Summary">
          <Kpi label="Open" value={k.open} onClick={() => setFilters(DEFAULT_FILTERS)} />
          <Kpi label="Critical" value={k.critical} tone="critical" onClick={() => setFilters({ ...DEFAULT_FILTERS, view: 'critical' })} />
          <Kpi label="High" value={k.high} tone="high" />
          <Kpi label="Overdue" value={k.overdue} tone="bad" active={filters.overdueOnly} onClick={() => set('overdueOnly', !filters.overdueOnly)} />
          <Kpi label="Blocking orders" value={k.blocking} tone="bad" active={filters.blockingOnly} onClick={() => set('blockingOnly', !filters.blockingOnly)} />
          <Kpi label="No owner" value={k.unowned} tone="warn" active={filters.unownedOnly} onClick={() => set('unownedOnly', !filters.unownedOnly)} />
          <Kpi label="At stake" text={gbp(k.atStake)} />
        </section>

        <div className="chips" role="tablist" aria-label="Issue groups">
          {VIEWS.map((v) => (
            <button key={v.id} role="tab" aria-selected={filters.view === v.id} className={`chip ${filters.view === v.id ? 'on' : ''} ${counts[v.id] === 0 ? 'zero' : ''}`}
              onClick={() => set('view', v.id)} title={v.hint}>{v.label} <b>{counts[v.id] ?? 0}</b></button>
          ))}
        </div>

        <div className="toolbar">
          <input type="search" className="search" placeholder="Search order, SKU, PO, person…" aria-label="Search" value={filters.search} onChange={(e) => set('search', e.target.value)} />
          <label className="sort">Sort <select value={filters.sort} onChange={(e) => set('sort', e.target.value as SortKey)}>{SORTS.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}</select></label>
          <button className={`chip small ${filters.mineOnly ? 'on' : ''}`} aria-pressed={filters.mineOnly} onClick={() => set('mineOnly', !filters.mineOnly)}>Mine</button>
        </div>

        <div className="aging" aria-label="Age of open issues">
          <span className="muted">Age</span>
          {AGE_BUCKETS.map((b) => (
            <button key={b} className={`chip small ${filters.age === b ? 'on' : ''}`} aria-pressed={filters.age === b} onClick={() => set('age', filters.age === b ? null : b)}>{b} <b>{ages[b]}</b></button>
          ))}
        </div>

        {loading ? <div className="state" role="status">Loading issues…</div>
          : !snap ? <div className="state bad" role="alert">Could not load the issues.{error ? ' ' + error : ''}<br /><button className="btn" onClick={() => void refresh()}>Try again</button></div>
          : shown.length === 0 ? <div className="state">{rows.length === 0 ? 'Nothing is wrong right now. Everything the system tracks is accounted for.' : 'No issues match these filters.'}
              {rows.length > 0 && <><br /><button className="btn" onClick={() => setFilters(DEFAULT_FILTERS)}>Clear filters</button></>}</div>
          : <><p className="muted count" aria-live="polite">Showing {shown.length} of {rows.length}</p>
              <ul className="list">{shown.map((e: ExceptionRow) => <ExceptionCard key={e.id} e={e} onOpen={(x) => setOpenId(x.id)} />)}</ul></>}
      </main>

      {open && <DetailDrawer e={open} role={role} me={me} canAct={canAct} onClose={() => setOpenId(null)} onChanged={async (msg) => { setToast(msg); await refresh(); }} />}
      {raising && <RaiseDialog me={me} onClose={() => setRaising(false)} onDone={async (msg) => { setRaising(false); setToast(msg); await refresh(); }} />}
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  );
}

function Kpi({ label, value, text, tone, active, onClick }: { label: string; value?: number; text?: string; tone?: string; active?: boolean; onClick?: () => void }) {
  const body = <><span className="kpi-v">{text ?? value}</span><span className="kpi-l">{label}</span></>;
  return onClick ? <button className={`kpi ${tone ?? ''} ${active ? 'on' : ''} ${value === 0 ? 'zero' : ''}`} aria-pressed={active} onClick={onClick}>{body}</button>
                 : <div className={`kpi ${tone ?? ''} ${value === 0 ? 'zero' : ''}`}>{body}</div>;
}
