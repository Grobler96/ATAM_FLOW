import { useCallback, useEffect, useState } from 'react';
import { rpc } from './store';

export function useRpcList<T>(fn: string, args: Record<string, unknown> = {}, deps: unknown[] = [], every = 60_000) {
  const [rows, setRows] = useState<T[]>([]); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const key = JSON.stringify(args);
  const load = useCallback(async () => { try { setRows((await rpc<T[]>(fn, args)) ?? []); setError(null); } catch (e) { setError(e instanceof Error ? e.message : 'Could not load'); } finally { setLoading(false); } }, [fn, key]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { setLoading(true); void load(); const t = every ? setInterval(() => { if (document.visibilityState === 'visible') void load(); }, every) : undefined; return () => { if (t) clearInterval(t); }; }, [load, every, ...deps]); // eslint-disable-line react-hooks/exhaustive-deps
  return { rows, loading, error, reload: load };
}
