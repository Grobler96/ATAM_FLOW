import { supabase } from './api';
import { opsAction } from './orderChanges';

export interface RecOption { operator_id: string; name: string; eligible: boolean; score: number; reasons: string[]; warnings: string[]; free_minutes: number }
export interface RecPlanRow { step_id: string; order_ref: string; customer: string | null; method_code: string; planned_start: string | null; best: RecOption | null; alternatives: RecOption[] }
export interface CrewJob { step_id: string; order_ref: string; customer: string | null; method_code: string; machine: string | null; planned_start: string | null; planned_end: string | null; minutes: number; status: string }
export interface CrewDay { operator_id: string; name: string; capacity: number; away: boolean; away_reason: string | null; booked: number; jobs: CrewJob[] }
export interface Worker { id: string; name: string; is_active: boolean; notes: string | null; history_name: string | null }
export interface Skill { operator_id: string; kind: 'method' | 'machine'; ref: string; level: number; machine_name: string | null; set_by: string | null; set_at: string }
export interface Shift { id: string; operator_id: string; weekday: number; start_time: string; end_time: string }
export interface Away { id: string; operator_id: string; from_date: string; to_date: string; reason: string | null }
export interface HistoryRow { operator_id: string; method_code: string; records: number; units: number; days: number; last_done: string | null }
export interface QualityRow { operator_id: string; method_code: string; checks: number; units_checked: number; units_failed: number; fail_pct: number | null }
export interface TimeRow { step_id: string; order_ref: string; method_code: string; operator: string | null; started_at: string | null; finished_at: string | null; actual_minutes: number | null; units_done: number | null; est_minutes: number | null; status: string }

export const LEVEL_LABEL = ['Not allowed', 'Learning', 'Competent', 'Expert'];
export const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
export const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
export const localDay = (iso: string | null) => (iso ? ymd(new Date(iso)) : '');
export const clock = (iso: string | null) => (iso ? new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : '—');

export const crewAction = (action: string, params: Record<string, unknown>) => opsAction(action, params);
export async function loadOptions(stepId: string): Promise<RecOption[]> { const { data } = await supabase.rpc('ui_rec_options', { p_step: stepId }); return Array.isArray(data) ? (data as RecOption[]) : []; }
export interface MachineOpt { machine_id: string; code: string; name: string; heads: number; planned_pick: boolean; chosen: boolean; available: boolean; status: string; load_minutes: number }
export async function loadMachines(stepId: string): Promise<MachineOpt[]> { const { data } = await supabase.rpc('ui_rec_machines', { p_step: stepId }); return Array.isArray(data) ? (data as MachineOpt[]) : []; }

// Plain wording for a suggestion, written the way a colleague would say it (no technical terms, no mention of how it was worked out).
export function sayIt(o: RecOption, job: { order_ref: string; method_code: string }): string {
  const first = o.name.split(' ')[0]; const what = job.method_code.replace(/_/g, ' ');
  const bits = o.reasons.map((r) => r.replace(/\.$/, '')).slice(0, 3);
  const lead = o.eligible ? `I would put ${first} on ${job.order_ref}.` : `${first} is not a good fit for ${job.order_ref}.`;
  const body = bits.length ? ` ${bits.map((b, i) => (i === 0 ? b : b.charAt(0).toLowerCase() + b.slice(1))).join('. ')}.` : ` There is not much to go on yet for ${what}.`;
  const warn = o.warnings.length ? ` Worth knowing: ${o.warnings[0].replace(/\.$/, '').replace(/^./, (c) => c.toLowerCase())}.` : '';
  return lead + body + warn;
}
