import { exceptionActionTo, supabase } from './api';
import type { ActionResult } from '../types';

// Every supplier-resilience change goes through the audited "Supplier actions" n8n workflow.
export const spAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('suppliers', action, params);

export interface Advice { ok: boolean; error?: string; sku: string; units_short: number; orders_affected: number; earliest_due: string | null; days_to_due: number | null; on_hand: number; on_order: number;
  incoming: { po_id: string; po_ref: string; supplier: string | null; qty: number; expected_date: string | null; on_time_rate: number | null; is_late: boolean; before_due: boolean }[];
  alternatives: { id: string; alt_sku: string; product: string | null; colour: string | null; size: string | null; on_hand: number; free: number; needs_customer_ok: boolean; notes: string | null }[];
  offers: { supplier_id: string; supplier: string; unit_cost: number | null; lead_days: number | null; min_qty: number; stock_available: number | null; on_time_rate: number | null; has_email: boolean; arrives_before_due: boolean }[];
  recommendation: { action: string; text: string } }
export async function loadAdvice(sku: string): Promise<Advice | null> {
  const { data, error } = await supabase.rpc('ui_shortage_advice', { p_sku: sku });
  if (error || !data || (data as Advice).ok === false) return null;
  return data as Advice;
}
export interface AltRow { id: string; sku: string; alt_sku: string; alt_product: string | null; alt_colour: string | null; alt_size: string | null; alt_on_hand: number | null; needs_customer_ok: boolean; notes: string | null; created_by: string | null; created_at: string }
export interface OfferRow { id: string; supplier_id: string; supplier: string; sku: string; supplier_sku: string | null; unit_cost: number | null; min_qty: number; stock_available: number | null; lead_days: number | null; updated_at: string }
export const ACTION_LABEL: Record<string, string> = { wait: 'Wait', substitute: 'Substitute', reorder: 'Reorder', split: 'Split the order', tell_customer: 'Tell the customer' };
