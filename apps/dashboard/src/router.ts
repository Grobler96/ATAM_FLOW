import { useSyncExternalStore } from 'react';

export interface Route { path: string[]; query: URLSearchParams; raw: string }
const subscribe = (cb: () => void) => { window.addEventListener('hashchange', cb); return () => window.removeEventListener('hashchange', cb); };
const snapshot = () => location.hash;

export function parseHash(hash: string): Route {
  const h = hash.replace(/^#\/?/, ''); const [p, q] = h.split('?');
  return { path: p.split('/').filter(Boolean).map(decodeURIComponent), query: new URLSearchParams(q ?? ''), raw: hash };
}
export function useRoute(): Route { return parseHash(useSyncExternalStore(subscribe, snapshot)); }
export const href = (path: string, query?: Record<string, string | undefined>): string => {
  const q = Object.entries(query ?? {}).filter(([, v]) => v).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v as string)}`).join('&');
  return '#/' + path.replace(/^\//, '') + (q ? '?' + q : '');
};
export const navigate = (path: string, query?: Record<string, string | undefined>) => { location.hash = href(path, query); };

// ?view=overdue&f.status=a,b&q=text  ->  what the data tables start with
export function tableStateFromQuery(r: Route): { tab?: string; filters?: Record<string, string[]>; search?: string } {
  const filters: Record<string, string[]> = {};
  r.query.forEach((v, k) => { if (k.startsWith('f.')) filters[k.slice(2)] = v.split(',').filter(Boolean); });
  return { tab: r.query.get('view') ?? undefined, filters: Object.keys(filters).length ? filters : undefined, search: r.query.get('q') ?? undefined };
}

export interface NavItem { id: string; label: string; icon: string; chord: string }
export const NAV: NavItem[] = [
  { id: 'home', label: 'Command Centre', icon: 'home', chord: 'h' }, { id: 'orders', label: 'Orders', icon: 'orders', chord: 'o' }, { id: 'production', label: 'Production', icon: 'production', chord: 'p' }, { id: 'quality', label: 'Quality', icon: 'check', chord: 'q' },
  { id: 'stock', label: 'Stock', icon: 'stock', chord: 's' }, { id: 'purchasing', label: 'Purchasing', icon: 'purchasing', chord: 'u' }, { id: 'producers', label: 'Producers', icon: 'producers', chord: 'r' },
  { id: 'goods-in', label: 'Goods in', icon: 'stock', chord: 'i' }, { id: 'warehouse', label: 'Warehouse / Bins', icon: 'warehouse', chord: 'w' }, { id: 'artwork', label: 'Artwork & Job Packs', icon: 'artwork', chord: 'a' }, { id: 'exceptions', label: 'Exceptions', icon: 'exceptions', chord: 'e' },
  { id: 'labels', label: 'Labels', icon: 'labels', chord: 'l' }, { id: 'analytics', label: 'Analytics', icon: 'analytics', chord: 'n' }, { id: 'settings', label: 'Settings', icon: 'settings', chord: 't' }
];
