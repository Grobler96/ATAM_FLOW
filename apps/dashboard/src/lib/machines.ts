import { exceptionActionTo, supabase } from './api';
import type { ActionResult } from '../types';

// Every machine change goes through the audited "Machine actions" n8n workflow.
export const mcAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('machines', action, params);

export interface MachineStatusRow { machine_id: string; code: string; name: string; method_code: string; location: string | null; machine_type: string | null; units_per_hour: number | null; is_active: boolean; notes: string | null; status: string; capacity_factor: number; downtime_id: string | null; status_reason: string | null; since: string | null; expected_back_at: string | null; back_overdue: boolean; next_planned_start: string | null; next_planned_reason: string | null; backup_codes: string[] | null }
export interface DowntimeRow { id: string; machine_id: string; machine_code: string; machine_name: string; kind: string; planned: boolean; started_at: string; expected_back_at: string | null; ended_at: string | null; capacity_factor: number; reason: string; reported_by: string | null; resolved_by: string | null; resolution_note: string | null; is_current: boolean; is_scheduled: boolean; hours: number; back_overdue: boolean }
export interface ImpactStep { step_id: string; order_id: string; order_ref: string; customer: string | null; due_date: string | null; method: string; status: string; units: number | null; minutes: number; planned_start: string | null; planned_end: string | null; already_late: boolean; at_risk: boolean }
export interface Impact { ok: boolean; error?: string; machine_code: string; method: string; steps: ImpactStep[]; orders: string[]; units: number; minutes: number; at_risk: number; alternatives: { code: string; queued_minutes: number; is_backup: boolean }[]; producers: { name: string; turnaround_days: number; has_rate: boolean }[]; options: { kind: string; text: string }[]; not_calculated: string[] }

export async function loadImpact(machineId: string, from: string | null, until: string | null, factor: number): Promise<Impact | null> {
  const { data, error } = await supabase.rpc('ui_mc_impact', { p_machine: machineId, p_from: from, p_until: until, p_factor: factor });
  if (error || !data || (data as Impact).ok === false) return null;
  return data as Impact;
}

export const STATUS_LABEL: Record<string, string> = { operational: 'Operational', limited: 'Reduced capacity', maintenance: 'Maintenance', breakdown: 'Breakdown', offline: 'Offline', retired: 'Retired' };
export const STATUS_TONE: Record<string, 'good' | 'medium' | 'high' | 'critical' | 'low'> = { operational: 'good', limited: 'medium', maintenance: 'high', breakdown: 'critical', offline: 'critical', retired: 'low' };
export const KIND_LABEL: Record<string, string> = { breakdown: 'Breakdown', maintenance: 'Maintenance', limited: 'Reduced capacity', offline: 'Offline' };
