import { exceptionActionTo } from './api';
import type { ActionResult } from '../types';

// Every quality change goes through the audited "Quality actions" n8n workflow.
export const qcAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('quality', action, params);

export interface QcQueueRow { order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_status: string; total_units: number; pending_checks: number; last_result: string | null; open_rework: number; replacements_open: number }
export interface QcCheckRow { id: string; check_ref: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_line_id: string | null; sku: string | null; gate: string; checkpoint_pct: number | null; status: string; units_checked: number | null; units_failed: number | null; defect_type: string | null; cause: string | null; producer_name: string | null; movement_code: string | null; notes: string | null; evidence: { url: string; name?: string }[]; due_by: string | null; checked_by: string | null; checked_at: string | null; created_at: string; results: { criterion: string; passed: boolean; note: string | null }[]; is_overdue: boolean }
export interface ReworkRow { id: string; rework_ref: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_line_id: string | null; sku: string | null; units: number; defect_type: string; cause: string; outcome: string; status: string; units_fixed: number; units_scrapped: number; assigned_to: string | null; replacement_status: string; replacement_note: string | null; notes: string | null; cancel_reason: string | null; producer_name: string | null; movement_code: string | null; check_ref: string | null; created_by: string | null; created_at: string; completed_at: string | null; age_hours: number }
export interface CriterionRow { id: string; method_code: string | null; name: string; description: string | null; sort_order: number; is_active: boolean; gates: string[] | null; is_required: boolean; is_critical: boolean; needs_photo: boolean; is_placeholder: boolean; version: number; updated_by: string | null; updated_at: string | null }
export interface QcStandardsRow { active_items: number; placeholder_items: number; confirmed_at: string | null; confirmed_by: string | null; is_confirmed: boolean }
// Which checklist items apply to a check: the order's methods (or the chosen line's) and the stage.
export function applicableItems(items: CriterionRow[], gate: string, methods: string[]): CriterionRow[] {
  return items.filter((c) => c.is_active && (c.gates === null || c.gates.length === 0 || c.gates.includes(gate)) && (c.method_code === null || methods.includes(c.method_code))).sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
}
// Plain-English reason a check cannot be saved yet (mirrors the database rules; the database still decides).
export function checklistProblem(list: CriterionRow[], ticks: Record<string, boolean>, notes: Record<string, string>, checkNotes: string, hasEvidence: boolean): string | null {
  const todo = list.filter((c) => c.is_required && !(c.id in ticks));
  if (todo.length) return `Still to answer: ${todo.map((c) => c.name).join(', ')}.`;
  for (const c of list) {
    if (ticks[c.id] !== false) continue;
    if (!(notes[c.id] ?? '').trim() && !checkNotes.trim()) return `"${c.name}" failed: say what is wrong.`;
    if (c.needs_photo && !hasEvidence) return `"${c.name}" failed: add a photo link as evidence.`;
  }
  return null;
}
export interface ProducerQualityRow { producer_id: string; checks: number; units_checked: number; units_failed: number; pass_rate: number | null; open_rework: number; rework_units: number }

export const GATES: { id: string; label: string }[] = [{ id: 'pre_production', label: 'Before production' }, { id: 'in_line', label: 'During production' }, { id: 'final', label: 'Final check' }, { id: 'producer_return', label: 'Returned from producer' }, { id: 'recheck', label: 'Re-check after rework' }];
export const gateLabel = (g: string): string => GATES.find((x) => x.id === g)?.label ?? g;
export const DEFECTS = ['stitching', 'placement', 'colour', 'print_quality', 'garment_damage', 'wrong_garment', 'wrong_size', 'contamination', 'artwork', 'other'];
export const CAUSES: { id: string; label: string }[] = [{ id: 'operator', label: 'Operator error' }, { id: 'machine', label: 'Machine fault' }, { id: 'garment', label: 'Faulty garment' }, { id: 'artwork', label: 'Artwork problem' }, { id: 'producer', label: 'Producer fault' }, { id: 'supplier', label: 'Supplier fault' }, { id: 'unknown', label: 'Not sure' }];
export const OUTCOMES: { id: string; label: string }[] = [{ id: 'redo', label: 'Redo the decoration' }, { id: 'replace', label: 'Needs replacement garments' }, { id: 'write_off', label: 'Write off' }];
export const humanise = (s: string): string => s.replace(/_/g, ' ');
