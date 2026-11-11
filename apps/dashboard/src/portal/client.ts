import { createClient } from '@supabase/supabase-js';
import { SUPABASE_KEY, SUPABASE_URL } from '../config';

// A separate session store from the internal app, so signing in here never touches a team member's login.
export const sb = createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'atam-portal-auth' } });
export const BUCKET = 'producer-evidence';

export interface PortalJobRow { code: string; state: string; status: string; dispatch_date: string | null; expected_return_date: string | null; direct_to_customer: boolean; units: number; orders: { order_ref: string; customer: string | null }[] | null; unread: number }
export interface PortalItem { item_id: string; order_ref: string; customer: string | null; sku: string | null; product: string | null; colour: string | null; size: string | null; qty_sent: number; qty_outstanding: number; counted: number | null; damaged: number | null; issue: string | null; issue_note: string | null; issue_resolved: boolean }
export interface PortalJob { ok: boolean; code: string; state: string; status: string; direct_to_customer: boolean; dispatch_date: string | null; expected_return_date: string | null; carrier_in: string | null; tracking_in: string | null; return_tracking: string | null; customer_tracking: string | null; ship_to?: { order_ref: string; customer: string | null; address: string | null; shipping_method: string | null }[] | null; accepted_at: string | null; declined_reason: string | null; instructions: string | null; items: PortalItem[]; messages: { side: 'producer' | 'atam'; author: string | null; body: string; at: string }[]; evidence: { id: string; path: string; kind: string; caption: string | null; at: string }[]; history: { event: string; at: string; note: string | null }[] }
export interface Me { ok: boolean; producer: string; producer_id: string; user: string; instructions: string | null; idle_minutes?: number }
export const NOTICE_KEY = 'portal-notice';
export const setNotice = (m: string) => { try { sessionStorage.setItem(NOTICE_KEY, m); } catch { /* private mode */ } };
export const takeNotice = (): string | null => { try { const m = sessionStorage.getItem(NOTICE_KEY); if (m) sessionStorage.removeItem(NOTICE_KEY); return m; } catch { return null; } };

// Every portal call returns { ok, error } so screens can show a plain message.
export async function rpc<T = Record<string, unknown>>(fn: string, args: Record<string, unknown> = {}): Promise<{ ok: boolean; error?: string; needs_reason?: boolean; data?: T }> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) {
    const msg = error.message.replace(/^.*?ERROR:\s*/, '');
    // The database ended an idle session: sign out now so the sign-in page can say why.
    if (/inactivity/i.test(msg)) { setNotice(msg); void sb.auth.signOut(); }
    return { ok: false, error: msg };
  }
  const d = data as { ok?: boolean; error?: string; needs_reason?: boolean } | null;
  if (d && d.ok === false) return { ok: false, error: d.error ?? 'That did not work.', needs_reason: d.needs_reason };
  return { ok: true, data: data as T };
}
export const STATE_LABEL: Record<string, string> = { to_accept: 'Needs accepting', accepted: 'Accepted, goods on the way', checked_in: 'Goods checked in', in_production: 'In production', ready_to_ship: 'Ready to ship', sent_back: 'Sent back', done: 'Complete', declined: 'Declined' };
export const ISSUES: [string, string][] = [['short', 'Fewer than sent'], ['over', 'More than sent'], ['damaged', 'Damaged'], ['wrong_item', 'Wrong item'], ['wrong_size', 'Wrong size'], ['other', 'Something else']];
export const fmtDate = (s: string | null | undefined) => (s ? new Date(s).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '—');
export const fmtTime = (s: string) => new Date(s).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
