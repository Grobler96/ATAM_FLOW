import { exceptionActionTo, supabase } from './api';
import type { ActionResult } from '../types';

// Order reviews, holds and priority changes go through the audited "Operations actions" n8n workflow.
export const opsAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('operations', action, params);

export interface ChangeRow { id: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_status: string; field: string; label: string; old_value: string | null; new_value: string | null; detected_at: string; status_at_change: string | null; severity: 'info' | 'warning' | 'high'; status: 'new' | 'reviewed' | 'accepted' | 'dismissed'; reviewed_by: string | null; reviewed_at: string | null; review_note: string | null }
export interface Impact { ok: boolean; order_ref: string; status: string; allocated_units: number; consignments: string[]; bins: string[]; printed_labels: number; steps_waiting: number; steps_in_progress: number; stale_job_packs: number; open_rework: number; actions: string[] }
export async function loadImpact(orderId: string): Promise<Impact | null> {
  const { data, error } = await supabase.rpc('ui_oc_impact', { p_order: orderId });
  if (error || !data || (data as Impact).ok === false) return null;
  return data as Impact;
}
export const PRIORITY_NAMES = ['Normal', 'High', 'Rush', 'Critical'];

export interface CourierEvent { id: string; movement_code: string; carrier: string | null; direction: string; event: string; at: string; note: string | null; recorded_by: string | null }
export interface CourierClaim { id: string; claim_ref: string; movement_code: string; kind: string; carrier: string | null; tracking_ref: string | null; value_claimed: number | null; amount_recovered: number | null; status: string; note: string | null; opened_by: string | null; opened_at: string; age_days: number; closed_note: string | null }
export const COURIER_EVENTS: [string, string][] = [['collected', 'Collected by courier'], ['delivered', 'Delivered'], ['failed_attempt', 'Failed delivery attempt'], ['delayed', 'Delayed'], ['wrong_address', 'Wrong address'], ['partial', 'Partly delivered'], ['damaged', 'Damaged'], ['lost', 'Lost'], ['note', 'Note only']];
export const COURIER_LABEL: Record<string, string> = Object.fromEntries(COURIER_EVENTS);

export interface PortalUser { id: string; producer_id: string; producer: string; email: string; name: string | null; is_active: boolean; has_signed_in: boolean; invited_at: string; last_seen_at: string | null; personal_email?: boolean; last_sign_in_at?: string | null; new_device_30d?: boolean }
export interface PortalSignIn { id: number; at: string; event: 'first_sign_in' | 'signed_in' | 'new_device' | 'refused'; email: string | null; producer: string | null; ip: string | null; ua: string | null; note: string | null }
export interface PortalMessage { id: string; movement_code: string; side: 'producer' | 'atam'; author: string | null; body: string; created_at: string }
export interface PortalReceipt { id: string; movement_code: string; sku: string | null; colour: string | null; size: string | null; qty_sent: number; qty_counted: number; qty_damaged: number; issue: string | null; note: string | null; received_by: string | null; received_at: string; resolved_at: string | null; resolved_by: string | null; resolution_note: string | null }
export interface PortalEvidence { id: string; movement_code: string; sku: string | null; storage_path: string; kind: string; caption: string | null; uploaded_by: string | null; created_at: string }
