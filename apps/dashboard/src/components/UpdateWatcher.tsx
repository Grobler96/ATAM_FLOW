import { useEffect, useRef, useState } from 'react';
import { decideUpdate, isBusy, type Trigger } from '../lib/updateCheck';

const POLL_MS = 2 * 60 * 1000; const KEY = 'atam_flow_reloaded_for';
const current = typeof __BUILD_ID__ === 'undefined' ? '' : __BUILD_ID__;
const read = (): string | null => { try { return sessionStorage.getItem(KEY); } catch { return null; } };
const mark = (v: string) => { try { sessionStorage.setItem(KEY, v); } catch { /* private window: the loop guard is best effort */ } };
const busyNow = () => { const a = document.activeElement as HTMLElement | null; return isBusy({ dialogOpen: !!document.querySelector('[role="dialog"]'), activeTag: a?.tagName ?? null, activeEditable: !!a?.isContentEditable, activeType: a instanceof HTMLInputElement ? a.type : null }); };

// Refreshes the page by itself, at a safe moment, when a newer build has been published (see lib/updateCheck.ts).
export function UpdateWatcher() {
  const latest = useRef<string | null>(null); const [waiting, setWaiting] = useState(false);
  useEffect(() => {
    if (!current) return; // a local dev server has no build id
    const act = (trigger: Trigger) => {
      const action = decideUpdate({ current, latest: latest.current, busy: busyNow(), trigger, reloadedFor: read() });
      if (action === 'reload') { mark(latest.current!); window.location.reload(); } else setWaiting(action === 'banner');
    };
    const check = async (trigger: Trigger) => {
      try { const r = await fetch(`./version.json?t=${Date.now()}`, { cache: 'no-store' }); if (r.ok) { const j = await r.json() as { build?: string }; latest.current = j.build ?? null; } } catch { /* offline: try again later */ }
      act(trigger);
    };
    const timer = window.setInterval(() => { if (!document.hidden) void check('poll'); }, POLL_MS);
    const onShow = () => { if (!document.hidden) void check('return'); };
    const onNav = () => act('navigate');
    document.addEventListener('visibilitychange', onShow); window.addEventListener('hashchange', onNav);
    void check('poll');
    return () => { window.clearInterval(timer); document.removeEventListener('visibilitychange', onShow); window.removeEventListener('hashchange', onNav); };
  }, []);
  if (!waiting) return null;
  return <div className="callout" role="status" data-testid="update-ready" style={{ position: 'fixed', left: 16, bottom: 16, zIndex: 50, maxWidth: 420, display: 'flex', gap: 12, alignItems: 'center' }}>
    <span><b>A new version of Flow is ready</b>It refreshes by itself when you move to another page. Finish what you are doing first if you like.</span>
    <button className="btn primary" onClick={() => { if (latest.current) mark(latest.current); window.location.reload(); }}>Refresh now</button>
  </div>;
}
