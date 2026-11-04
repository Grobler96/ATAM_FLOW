import { N8N_BASE } from '../config';
import { supabase } from './api';
import type { Role } from '../types';

export interface WorkflowDef { id: string; label: string; description: string; path: string; roles: Role[]; icon: string; resultLink?: string; summarise: (r: Record<string, any>) => string }
const n = (v: unknown) => (typeof v === 'number' ? v : 0);

export const WORKFLOWS: WorkflowDef[] = [
  { id: 'sync-orders', label: 'Sync DecoNetwork orders', description: 'Pull open orders and lines from DecoNetwork', path: 'sync-orders', roles: ['admin', 'manager'], icon: 'refresh', resultLink: 'orders',
    summarise: (r) => r.summary ? `${n(r.summary.orders_changed ?? r.orders_changed)} order(s) changed, ${n(r.summary.lines_changed ?? r.lines_changed)} line(s) changed.` : 'Orders synced.' },
  { id: 'sync-stock', label: 'Sync stock levels', description: 'Refresh stock on hand from DecoNetwork', path: 'sync-stock', roles: ['admin', 'manager', 'warehouse'], icon: 'stock', resultLink: 'stock', summarise: () => 'Stock levels refreshed.' },
  { id: 'sync-pos', label: 'Sync purchase orders', description: 'Refresh purchase orders and inbound quantities', path: 'sync-purchase-orders', roles: ['admin', 'manager', 'warehouse'], icon: 'purchasing', resultLink: 'purchasing', summarise: () => 'Purchase orders refreshed.' },
  { id: 'allocate', label: 'Allocate stock', description: 'Reserve stock and incoming POs to the orders that need them most', path: 'run-allocation', roles: ['admin', 'manager', 'warehouse'], icon: 'box', resultLink: 'orders',
    summarise: (r) => { const s = r.summary ?? {}; return `${n(s.orders_considered)} order(s) considered: ${n(s.allocate)} fully allocated, ${n(s.partial)} partial, ${n(s.hold)} held, ${n(s.blocked)} blocked.`; } },
  { id: 'scheduler', label: 'Re-plan production', description: 'Recalculate the production sequence and machine plan', path: 'run-scheduler', roles: ['admin', 'manager', 'production'], icon: 'production', resultLink: 'production',
    summarise: (r) => { const s = r.summary ?? {}; return `${n(s.orders_planned)} order(s) planned over ${n(s.batches)} batch(es); ${n(s.steps_late)} step(s) predicted late.`; } },
  { id: 'exceptions', label: 'Check for exceptions', description: 'Run every exception detector now', path: 'run-exceptions', roles: ['admin', 'manager', 'warehouse', 'production'], icon: 'exceptions', resultLink: 'exceptions',
    summarise: (r) => `${n(r.detection?.open_now)} open exception(s), ${n(r.detection?.critical_open)} critical.` }
];

export interface RunResult { ok: boolean; message: string; detail?: Record<string, any> }

export async function runWorkflow(def: WorkflowDef, body: Record<string, unknown> = {}): Promise<RunResult> {
  const { data } = await supabase.auth.getSession(); const token = data.session?.access_token;
  if (!token) return { ok: false, message: 'You are signed out. Sign in again.' };
  let res: Response;
  try { res = await fetch(`${N8N_BASE}/${def.path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }); }
  catch { return { ok: false, message: 'Could not reach n8n. Check your connection and try again.' }; }
  let json: Record<string, any> | null = null; try { json = await res.json(); } catch { /* not JSON */ }
  if (res.status === 404) return { ok: false, message: 'This workflow is not switched on yet (it has not been published in n8n).' };
  if (res.status === 401) return { ok: false, message: 'Your session has expired. Sign in again.' };
  if (res.status === 403) return { ok: false, message: json?.error ?? 'Your role is not allowed to run this.' };
  if (!res.ok || json?.ok === false) return { ok: false, message: json?.error ?? `The workflow reported a problem (HTTP ${res.status}).`, detail: json ?? undefined };
  return { ok: true, message: def.summarise(json ?? {}), detail: json ?? undefined };
}
