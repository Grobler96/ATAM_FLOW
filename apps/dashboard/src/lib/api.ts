import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { N8N_BASE, SUPABASE_KEY, SUPABASE_URL } from '../config';
import type { ActionResult, ExceptionRow, HistoryRow, Role, StatusRow } from '../types';

export const supabase: SupabaseClient = createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: true, autoRefreshToken: true } });

export interface Snapshot { rows: ExceptionRow[]; status: StatusRow | null; role: Role | null; fetchedAt: number }

export async function loadSnapshot(): Promise<Snapshot> {
  const [ex, st, role] = await Promise.all([
    supabase.from('ui_exceptions').select('*').limit(2000),
    supabase.from('ui_status').select('*').maybeSingle(),
    supabase.rpc('ui_my_role')
  ]);
  if (ex.error) throw new Error(ex.error.message);
  if (st.error) throw new Error(st.error.message);
  return { rows: (ex.data ?? []) as ExceptionRow[], status: (st.data ?? null) as StatusRow | null, role: (role.data ?? null) as Role | null, fetchedAt: Date.now() };
}

export async function loadHistory(id: string): Promise<HistoryRow[]> {
  const { data, error } = await supabase.from('ui_exception_history').select('*').eq('exception_id', id).order('at', { ascending: true });
  if (error) throw new Error(error.message);
  return (data ?? []) as HistoryRow[];
}

export async function findOrderId(orderRef: string): Promise<string | null> {
  const { data } = await supabase.from('ui_order_accountability').select('order_id').eq('order_ref', orderRef.trim()).maybeSingle();
  return (data?.order_id as string | undefined) ?? null;
}

async function call(path: string, body: unknown): Promise<ActionResult> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) return { ok: false, error: 'You are signed out. Sign in again.' };
  let res: Response;
  try {
    res = await fetch(`${N8N_BASE}/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
  } catch {
    return { ok: false, error: 'Could not reach the server. Check your connection and try again.' };
  }
  let json: ActionResult | null = null;
  try { json = (await res.json()) as ActionResult; } catch { /* not JSON */ }
  if (res.status === 404) return { ok: false, error: 'This action is not switched on yet (its n8n workflow has not been published).' };
  if (res.status === 401) return { ok: false, error: 'Your session has expired. Sign in again.' };
  if (res.status === 403) return { ok: false, error: json?.error ?? 'Your role is not allowed to do that.' };
  if (!res.ok && !json) return { ok: false, error: `The server answered ${res.status}. Try again, and tell an admin if it keeps happening.` };
  return json ?? { ok: res.ok };
}

export const exceptionAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => call('exceptions', { action, params });
export const runCheckNow = (): Promise<ActionResult> => call('run-exceptions', {});
