import type { UpdateEntry, UpdateStatus } from '../data/updatelog';

// The logic of the Update log page: filters, the "something broke around…" finder, ranking and the CSV of suggestions.
export const STATUS_LABEL: Record<UpdateStatus, string> = { in_progress: 'In progress', live: 'Live', partly: 'Partly live', built: 'Built, waiting to go live', rolled_back: 'Rolled back' };
export const STATUS_TONE: Record<UpdateStatus, 'good' | 'medium' | 'info' | 'high' | 'critical'> = { in_progress: 'info', live: 'good', partly: 'medium', built: 'info', rolled_back: 'critical' };
export const SUSPECT_DAYS = 3;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export const dayWords = (s: string): string => { const p = s.slice(0, 10).split('-'); return p.length === 3 && p[1] ? `${Number(p[2])} ${MONTHS[Number(p[1]) - 1]} ${p[0]}` : s; };
const ms = (s: string): number => { const p = s.slice(0, 10).split('-'); return Date.UTC(Number(p[0]), Number(p[1]) - 1, Number(p[2])); };
export const versionNumber = (u: Pick<UpdateEntry, 'v'>): number => Number(u.v.replace(/\D/g, '')) || 0;
export const newestFirst = (list: UpdateEntry[]): UpdateEntry[] => [...list].sort((a, b) => ms(b.date) - ms(a.date) || versionNumber(b) - versionNumber(a));

// An update is a suspect when it went live in the few days up to the day something started failing. Work still in progress, built or planned cannot be a cause.
export function isSuspect(u: UpdateEntry, around: string): boolean {
  if (!around || u.status === 'built' || u.status === 'in_progress') return false;
  const d = ms(u.date), a = ms(around); return d <= a && a - d <= SUSPECT_DAYS * 86400000;
}
export interface UpdateFilter { q: string; status: string; area: string; around: string }
export function filterUpdates(list: UpdateEntry[], f: UpdateFilter): UpdateEntry[] {
  const q = f.q.trim().toLowerCase();
  return list.filter((u) => {
    if (f.status && u.status !== f.status) return false;
    if (f.area && !u.areas.includes(f.area)) return false;
    if (f.around && !isSuspect(u, f.around)) return false;
    if (q && ![u.v, u.title, u.summary, u.areas.join(' '), u.changes.join(' '), u.date].join(' ').toLowerCase().includes(q)) return false;
    return true;
  });
}
export const areasOf = (list: UpdateEntry[], extra: string[] = []): string[] => [...new Set([...list.flatMap((u) => u.areas), ...extra])].sort();

export interface SuggestionRow { id: string; title: string; detail: string | null; area: string | null; suggested_by_name: string | null; status: 'open' | 'planned' | 'built' | 'declined'; status_at: string | null; created_at: string; mine: boolean; votes: number; points: number; avg_importance: number | null; my_rating: number | null }
export const SUGGESTION_STATUS: Record<SuggestionRow['status'], string> = { open: 'Open', planned: 'Planned', built: 'Built', declined: 'Declined' };
export const IMPORTANCE_WORDS = ['', 'Nice to have', 'Would help', 'Useful', 'Important', 'Needed now'];
// Ranked by points (everyone's ratings added up), then by the newest.
export const rankSuggestions = (rows: SuggestionRow[]): SuggestionRow[] => [...rows].sort((a, b) => b.points - a.points || b.created_at.localeCompare(a.created_at));
export const isLiveSuggestion = (s: SuggestionRow): boolean => s.status === 'open' || s.status === 'planned';

const cell = (v: unknown): string => { const t = v == null ? '' : String(v); return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
export function suggestionsCsv(rows: SuggestionRow[]): string {
  const head = ['Rank', 'Title', 'Details', 'Area', 'Status', 'Points', 'Ratings', 'Average', 'Suggested by', 'Date'];
  const body = rankSuggestions(rows).map((s, i) => [i + 1, s.title, s.detail, s.area, SUGGESTION_STATUS[s.status], s.points, s.votes, s.avg_importance, s.suggested_by_name, s.created_at.slice(0, 10)].map(cell).join(','));
  return [head.join(','), ...body].join('\n');
}
