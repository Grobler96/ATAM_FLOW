import { exceptionActionTo } from './api';
import type { ActionResult } from '../types';

// Every quality change goes through the audited "Quality actions" n8n workflow.
export const qcAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('quality', action, params);

export interface QcQueueRow { order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_status: string; total_units: number; pending_checks: number; last_result: string | null; open_rework: number; replacements_open: number }
export interface QcCheckRow { id: string; check_ref: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_line_id: string | null; sku: string | null; gate: string; checkpoint_pct: number | null; status: string; units_checked: number | null; units_failed: number | null; defect_type: string | null; cause: string | null; producer_name: string | null; movement_code: string | null; notes: string | null; evidence: { url: string; name?: string }[]; due_by: string | null; checked_by: string | null; checked_at: string | null; created_at: string; results: { criterion: string; passed: boolean; note: string | null }[]; is_overdue: boolean }
export interface ReworkRow { id: string; rework_ref: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_line_id: string | null; sku: string | null; units: number; defect_type: string; cause: string; outcome: string; status: string; units_fixed: number; units_scrapped: number; assigned_to: string | null; replacement_status: string; replacement_note: string | null; notes: string | null; cancel_reason: string | null; producer_name: string | null; movement_code: string | null; check_ref: string | null; created_by: string | null; created_at: string; completed_at: string | null; age_hours: number }
export interface CriterionRow { id: string; method_code: string | null; name: string; description: string | null; sort_order: number; is_active: boolean }
export interface ProducerQualityRow { producer_id: string; checks: number; units_checked: number; units_failed: number; pass_rate: number | null; open_rework: number; rework_units: number }

export const GATES: { id: string; label: string }[] = [{ id: 'pre_production', label: 'Before production' }, { id: 'in_line', label: 'During production' }, { id: 'final', label: 'Final check' }, { id: 'producer_return', label: 'Returned from producer' }, { id: 'recheck', label: 'Re-check after rework' }];
export const gateLabel = (g: string): string => GATES.find((x) => x.id === g)?.label ?? g;
export const DEFECTS = ['stitching', 'placement', 'colour', 'print_quality', 'garment_damage', 'wrong_garment', 'wrong_size', 'contamination', 'artwork', 'other'];
export const CAUSES: { id: string; label: string }[] = [{ id: 'operator', label: 'Operator error' }, { id: 'machine', label: 'Machine fault' }, { id: 'garment', label: 'Faulty garment' }, { id: 'artwork', label: 'Artwork problem' }, { id: 'producer', label: 'Producer fault' }, { id: 'supplier', label: 'Supplier fault' }, { id: 'unknown', label: 'Not sure' }];
export const OUTCOMES: { id: string; label: string }[] = [{ id: 'redo', label: 'Redo the decoration' }, { id: 'replace', label: 'Needs replacement garments' }, { id: 'write_off', label: 'Write off' }];
export const humanise = (s: string): string => s.replace(/_/g, ' ');
