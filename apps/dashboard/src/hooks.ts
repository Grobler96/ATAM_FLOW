import { useCallback, useEffect, useRef, useState } from 'react';
import { REFRESH_MS } from './config';
import { loadSnapshot, type Snapshot } from './lib/api';

export interface SnapshotState { snap: Snapshot | null; error: string | null; loading: boolean; refreshing: boolean; online: boolean; refresh: () => Promise<void> }

// Loads on mount, then every minute and whenever the tab regains focus. A failed refresh keeps the last good data and says so.
export function useSnapshot(enabled: boolean): SnapshotState {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [online, setOnline] = useState(typeof navigator === 'undefined' ? true : navigator.onLine);
  const busy = useRef(false);

  const refresh = useCallback(async () => {
    if (busy.current) return;
    busy.current = true; setRefreshing(true);
    try { setSnap(await loadSnapshot()); setError(null); }
    catch (e) { setError(e instanceof Error ? e.message : 'Could not load data'); }
    finally { busy.current = false; setRefreshing(false); setLoading(false); }
  }, []);

  useEffect(() => {
    if (!enabled) return;
    void refresh();
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, REFRESH_MS);
    const onFocus = () => void refresh();
    const on = () => { setOnline(true); void refresh(); }; const off = () => setOnline(false);
    window.addEventListener('focus', onFocus); window.addEventListener('online', on); window.addEventListener('offline', off);
    return () => { clearInterval(t); window.removeEventListener('focus', onFocus); window.removeEventListener('online', on); window.removeEventListener('offline', off); };
  }, [enabled, refresh]);

  return { snap, error, loading, refreshing, online, refresh };
}
