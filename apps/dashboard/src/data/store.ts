import { useCallback, useEffect, useSyncExternalStore } from 'react';
import { supabase } from '../lib/api';
import { cutOffAt, needsCountCheck } from './cutoff';

// One shared cache for every page: a view is fetched once, shared by whoever needs it, refreshed every minute while somebody is looking at it,
// and a failed refresh keeps the last good data (so the UI can say "showing data from 3 minutes ago").
// `cut` is how many rows the list was cut off at (it hit its row limit, or the API returned fewer rows than exist); null when it is complete.
interface Entry { data: unknown[] | null; error: string | null; at: number; loading: boolean; subs: number; cut: number | null }
const cache = new Map<string, Entry>();
const listeners = new Set<() => void>();
const inflight = new Map<string, Promise<void>>();
const emit = () => listeners.forEach((l) => l());
let version = 0;

export function viewKey(name: string, limit = 5000): string { return `${name}:${limit}`; }

async function fetchView(name: string, limit: number): Promise<void> {
  const key = viewKey(name, limit);
  if (inflight.has(key)) return inflight.get(key);
  const cur = cache.get(key) ?? { data: null, error: null, at: 0, loading: true, subs: 0, cut: null };
  cache.set(key, { ...cur, loading: cur.data === null }); version++; emit();
  const p = (async () => {
    try {
      const { data, error } = await supabase.from(name).select('*').limit(limit);
      if (error) throw new Error(error.message);
      const rows = (data ?? []) as unknown[];
      // A big list that did not reach our limit may still have hit a server-side cap: only a count can tell, so ask (and only then).
      let total: number | null = null;
      if (needsCountCheck(rows.length, limit)) { try { const c = await supabase.from(name).select('*', { count: 'exact', head: true }); total = c.error ? null : c.count; } catch { total = null; } }
      cache.set(key, { ...(cache.get(key) as Entry), data: rows, cut: cutOffAt(rows.length, limit, total), error: null, at: Date.now(), loading: false });
    } catch (e) {
      cache.set(key, { ...(cache.get(key) as Entry), error: e instanceof Error ? e.message : 'Could not load', loading: false });
    } finally { inflight.delete(key); version++; emit(); }
  })();
  inflight.set(key, p); return p;
}

export function refreshAll(): Promise<void[]> {
  return Promise.all([...cache.keys()].filter((k) => (cache.get(k)?.subs ?? 0) > 0).map((k) => { const [n, l] = k.split(':'); return fetchView(n, Number(l)); }));
}
export function clearCache() { cache.clear(); version++; emit(); }

export interface ViewState<T> { rows: T[]; loading: boolean; error: string | null; at: number | null; refresh: () => Promise<void> }

export function useView<T = Record<string, unknown>>(name: string, opts: { limit?: number } = {}): ViewState<T> {
  const limit = opts.limit ?? 5000, key = viewKey(name, limit);
  useSyncExternalStore((cb) => { listeners.add(cb); return () => listeners.delete(cb); }, () => version);
  useEffect(() => {
    const e = cache.get(key) ?? { data: null, error: null, at: 0, loading: true, subs: 0, cut: null };
    cache.set(key, { ...e, subs: e.subs + 1 });
    if (e.cut !== null) { version++; emit(); }   // a cut-off list came back on screen: bring its warning back
    if (!e.data || Date.now() - e.at > 30_000) void fetchView(name, limit);
    const t = setInterval(() => { if (document.visibilityState === 'visible') void fetchView(name, limit); }, 60_000);
    return () => { clearInterval(t); const c = cache.get(key); if (c) { cache.set(key, { ...c, subs: Math.max(0, c.subs - 1) }); if (c.cut !== null) { version++; emit(); } } };
  }, [key, name, limit]);
  const e = cache.get(key);
  const refresh = useCallback(() => fetchView(name, limit), [name, limit]);
  return { rows: (e?.data ?? []) as T[], loading: !e || (e.loading && e.data === null), error: e?.error ?? null, at: e?.data ? e.at : null, refresh };
}

// The lists that are in use right now and were cut off, for the warning banner.
export function useCutOffViews(): { view: string; shown: number }[] {
  useSyncExternalStore((cb) => { listeners.add(cb); return () => listeners.delete(cb); }, () => version);
  return [...cache.entries()].filter(([, e]) => e.cut !== null && e.subs > 0).map(([k, e]) => ({ view: k.split(':')[0], shown: e.cut as number }));
}

export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(error.message);
  return data as T;
}
