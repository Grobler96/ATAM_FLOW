import { useCallback, useEffect, useSyncExternalStore } from 'react';
import { supabase } from '../lib/api';

// One shared cache for every page: a view is fetched once, shared by whoever needs it, refreshed every minute while somebody is looking at it,
// and a failed refresh keeps the last good data (so the UI can say "showing data from 3 minutes ago").
interface Entry { data: unknown[] | null; error: string | null; at: number; loading: boolean; subs: number }
const cache = new Map<string, Entry>();
const listeners = new Set<() => void>();
const inflight = new Map<string, Promise<void>>();
const emit = () => listeners.forEach((l) => l());
let version = 0;

export function viewKey(name: string, limit = 5000): string { return `${name}:${limit}`; }

async function fetchView(name: string, limit: number): Promise<void> {
  const key = viewKey(name, limit);
  if (inflight.has(key)) return inflight.get(key);
  const cur = cache.get(key) ?? { data: null, error: null, at: 0, loading: true, subs: 0 };
  cache.set(key, { ...cur, loading: cur.data === null }); version++; emit();
  const p = (async () => {
    try {
      const { data, error } = await supabase.from(name).select('*').limit(limit);
      if (error) throw new Error(error.message);
      cache.set(key, { ...(cache.get(key) as Entry), data: (data ?? []) as unknown[], error: null, at: Date.now(), loading: false });
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
    const e = cache.get(key) ?? { data: null, error: null, at: 0, loading: true, subs: 0 };
    cache.set(key, { ...e, subs: e.subs + 1 });
    if (!e.data || Date.now() - e.at > 30_000) void fetchView(name, limit);
    const t = setInterval(() => { if (document.visibilityState === 'visible') void fetchView(name, limit); }, 60_000);
    return () => { clearInterval(t); const c = cache.get(key); if (c) cache.set(key, { ...c, subs: Math.max(0, c.subs - 1) }); };
  }, [key, name, limit]);
  const e = cache.get(key);
  const refresh = useCallback(() => fetchView(name, limit), [name, limit]);
  return { rows: (e?.data ?? []) as T[], loading: !e || (e.loading && e.data === null), error: e?.error ?? null, at: e?.data ? e.at : null, refresh };
}

export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(error.message);
  return data as T;
}
