import { exceptionActionTo, supabase } from './api';
import type { ActionResult } from '../types';

// Producer risk changes go through the audited "Producer risk actions" n8n workflow.
export const prAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('producer-risk', action, params);

export interface RiskRow { producer_id: string; name: string; is_active: boolean; is_suspended: boolean; suspended_reason: string | null; suspended_at: string | null; max_concurrent_jobs: number | null; emergency_contact: string | null; emergency_phone: string | null; last_contact_at: string | null; last_contact_note: string | null; units_held: number; units_in_transit: number; value_held: number; open_jobs: number; open_movements: number; on_time_rate: number | null; discrepancy_rate: number | null; pass_rate: number | null; overdue_returns: number; unconfirmed_receipts: number; risk_score: number; risk_rating: string; reasons: string[]; backup_codes: string[] | null }
export interface Recovery { ok: boolean; held: { movement_code: string; status: string; units: number; orders: string[] | null; expected_back: string | null; is_overdue: boolean }[]; alternatives: { name: string; turnaround_days: number; is_backup: boolean; has_rate: boolean }[]; options: { kind: string; text: string }[] }
export async function loadRecovery(id: string): Promise<Recovery | null> {
  const { data, error } = await supabase.rpc('ui_pr_recovery', { p_producer: id });
  if (error || !data || (data as Recovery).ok === false) return null;
  return data as Recovery;
}
export const RATING_TONE: Record<string, 'good' | 'medium' | 'high' | 'critical'> = { low: 'good', medium: 'medium', high: 'high', critical: 'critical' };
