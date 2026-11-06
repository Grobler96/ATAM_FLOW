import { supabase } from './api';
import { opsAction } from './orderChanges';

export interface SwitchRow { key: string; label: string; enabled: boolean; sort_order: number; changed_by: string | null; changed_at: string | null; reason: string | null }
export interface ScopeLogRow { id: number; at: string; kind: 'switch' | 'order'; target: string; was: string | null; now: string | null; actor: string | null; reason: string | null }
export interface OrderScopeRow { order_id: string; order_ref: string; scope: 'third_party' | 'in_house' | 'out_of_scope' | 'unclassified'; source: 'override' | 'deco_flag' | 'none'; third_party_flag: boolean | null; scope_override: string | null; scope_reason: string | null; scope_by: string | null; scope_at: string | null }
export interface Preview { ok: boolean; label: string; currently: boolean; to: boolean; planned_steps: number; orders: number; running_steps: number; exceptions_cleared: number; blocked_by_running: boolean }

export const SCOPE_LABEL: Record<string, string> = { third_party: 'Third-party', in_house: 'In-house', out_of_scope: 'Out of scope', unclassified: 'Unclassified' };
export const SCOPE_HELP: Record<string, string> = {
  third_party: 'Goes to a producer. The in-house planner leaves it alone.',
  in_house: 'Done on your own machines and planned by the scheduler.',
  out_of_scope: 'ATAM_FLOW ignores it: not planned, and no exceptions are raised for it.',
  unclassified: 'No DecoNetwork flag and no decision yet. Treated as in-house work when in-house production is on.'
};
export async function loadPreview(key: string, enabled: boolean): Promise<Preview | null> {
  const { data, error } = await supabase.rpc('ui_sc_preview', { p_key: key, p_enabled: enabled });
  if (error || !data || (data as Preview).ok === false) return null;
  return data as Preview;
}
export const setSwitch = (key: string, enabled: boolean, reason: string) => opsAction('set_switch', { key, enabled, reason });
export const setOrderScope = (orderId: string, scope: string | null, reason: string) => opsAction('set_scope', { order_id: orderId, scope, reason });
