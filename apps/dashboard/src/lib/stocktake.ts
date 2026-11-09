import { opsAction } from './orderChanges';
import type { ActionResult } from '../types';
import type { Tone } from '../ui/primitives';

export interface StockTakeRow {
  id: string; take_ref: string; name: string; scope_kind: string; scope_detail: string | null; status: 'counting' | 'review' | 'closed' | 'cancelled'; created_by: string; created_at: string;
  review_at: string | null; review_by: string | null; closed_at: string | null; closed_by: string | null; close_note: string | null; cancelled_at: string | null; cancelled_by: string | null; cancel_reason: string | null;
  dn_adjusted_at: string | null; dn_adjusted_by: string | null; dn_note: string | null; lines: number; counted_lines: number; matched_lines: number | null; open_lines: number | null; recount_lines: number | null;
  net_units: number | null; net_value: number | null; shortfall_value: number | null; needs_correction: boolean;
}
export type LineStatus = 'to_count' | 'counted' | 'matched' | 'recount_needed' | 'recounted' | 'accepted';
export interface StockTakeLine {
  id: string; take_id: string; take_ref: string; take_status: string; stock_item_id: string; sku: string; product_name: string | null; colour: string | null; size: string | null; location: string | null; unit_cost: number; added_in_count: boolean;
  expected_qty: number | null; counted_qty: number | null; counted_by: string | null; counted_at: string | null; recount_qty: number | null; recount_by: string | null; recount_at: string | null; final_qty: number | null;
  variance: number | null; variance_value: number | null; status: LineStatus; accept_reason: string | null; accepted_by: string | null; accepted_at: string | null;
}
export const TAKE_LABEL: Record<StockTakeRow['status'], string> = { counting: 'Counting', review: 'In review', closed: 'Closed', cancelled: 'Cancelled' };
export const TAKE_TONE: Record<StockTakeRow['status'], Tone> = { counting: 'info', review: 'medium', closed: 'good', cancelled: '' };
export const LINE_LABEL: Record<LineStatus, string> = { to_count: 'To count', counted: 'Counted', matched: 'Matches', recount_needed: 'Needs a recount', recounted: 'Recounted', accepted: 'Accepted' };
export const LINE_TONE: Record<LineStatus, Tone> = { to_count: '', counted: 'info', matched: 'good', recount_needed: 'high', recounted: 'medium', accepted: 'good' };

export type Scope = { kind: 'all' } | { kind: 'location'; location: string } | { kind: 'skus'; skus: string[] } | { kind: 'high_value'; top: number };
// Writes go through the Operations actions workflow, which checks the caller's role (and whether they count as a manager); the database checks the rest.
export const stocktakeStart = (name: string, scope: Scope): Promise<ActionResult> => opsAction('stocktake_start', { name, scope });
export const stocktakeCount = (take_id: string, sku: string, qty: number): Promise<ActionResult> => opsAction('stocktake_count', { take_id, sku, qty });
export const stocktakeReview = (take_id: string): Promise<ActionResult> => opsAction('stocktake_review', { take_id });
export const stocktakeRecount = (take_id: string, sku: string, qty: number): Promise<ActionResult> => opsAction('stocktake_recount', { take_id, sku, qty });
export const stocktakeAccept = (line_id: string, reason: string): Promise<ActionResult> => opsAction('stocktake_accept', { line_id, reason });
export const stocktakeAcceptSmall = (take_id: string, reason: string): Promise<ActionResult> => opsAction('stocktake_accept_small', { take_id, reason });
export const stocktakeClose = (take_id: string, note?: string): Promise<ActionResult> => opsAction('stocktake_close', { take_id, note });
export const stocktakeCancel = (take_id: string, reason: string): Promise<ActionResult> => opsAction('stocktake_cancel', { take_id, reason });
export const stocktakeAdjusted = (take_id: string, note?: string): Promise<ActionResult> => opsAction('stocktake_adjusted', { take_id, note });

// "A1, B2 c3" -> ['A1','B2','C3']
export const parseSkuList = (text: string): string[] => [...new Set(text.split(/[\s,;]+/).map((x) => x.trim().toUpperCase()).filter(Boolean))];
