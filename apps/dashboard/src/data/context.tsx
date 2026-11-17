import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Role } from '../types';

export type RangeId = 'today' | 'week' | 'month' | 'all';
export const RANGES: { id: RangeId; label: string }[] = [{ id: 'today', label: 'Today' }, { id: 'week', label: 'This week' }, { id: 'month', label: 'This month' }, { id: 'all', label: 'All' }];

export type RoleStatus = 'loading' | 'ok' | 'none' | 'error';
export interface Ctx { roleStatus: RoleStatus; retryRole: () => void; range: RangeId; setRange: (r: RangeId) => void; role: Role | null; email: string | null; canAct: boolean; senior: boolean; inRange: (iso: string | null) => boolean }
const C = createContext<Ctx>({ roleStatus: 'ok', retryRole: () => undefined, range: 'all', setRange: () => undefined, role: null, email: null, canAct: false, senior: false, inRange: () => true });
export const useCtx = () => useContext(C);

const dayStart = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
export function rangeBounds(r: RangeId, now = new Date()): [number, number] {
  const s = dayStart(now), day = 86400000;
  if (r === 'today') return [-Infinity, s + day];                       // overdue work still counts as "today's problem"
  if (r === 'week') return [-Infinity, s + (7 - ((now.getDay() + 6) % 7)) * day];
  if (r === 'month') return [-Infinity, new Date(now.getFullYear(), now.getMonth() + 1, 1).getTime()];
  return [-Infinity, Infinity];
}

export function ContextProvider({ role, email, roleStatus = 'ok', retryRole = () => undefined, children }: { role: Role | null; email: string | null; roleStatus?: RoleStatus; retryRole?: () => void; children: ReactNode }) {
  const [range, setRange] = useState<RangeId>(() => { try { return (localStorage.getItem('atamflow.range') as RangeId) || 'all'; } catch { return 'all'; } });
  useEffect(() => { try { localStorage.setItem('atamflow.range', range); } catch { /* storage unavailable */ } }, [range]);
  const value = useMemo<Ctx>(() => {
    const [lo, hi] = rangeBounds(range);
    return { roleStatus, retryRole, range, setRange, role, email, canAct: role !== null && role !== 'viewer', senior: role === 'admin' || role === 'manager', inRange: (iso) => (iso ? Date.parse(iso) >= lo && Date.parse(iso) < hi : range === 'all') };
  }, [range, role, email, roleStatus, retryRole]);
  return <C.Provider value={value}>{children}</C.Provider>;
}
