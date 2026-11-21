import type { Tone } from '../ui/primitives';

// Embroidery before production. A NEW logo needs a physical swatch, sent to the customer to sign off; a logo we have done before does not. The same for
// in-house and third-party orders (a tab each). The database holds the register of designs and decides every move (flow.emb_set_status); this mirrors its
// rules so a screen only offers moves that will work, and gives the plain words. Read-only here: all changes go through the action workflow.
export type EmbStatus = 'to_review' | 'known' | 'swatch_required' | 'swatch_in_progress' | 'swatch_sent' | 'swatch_approved' | 'changes_needed';
export interface EmbAreaRow {
  artwork_id: string; order_id: string; order_ref: string; customer_id: string | null; customer_name: string | null; due_date: string | null; scope: string; order_status: string;
  deco_line_id: string; area: string; thumbnail_url: string | null; stitch_count: number | null; width_mm: number | null; height_mm: number | null; file_format: string | null;
  storage_status: string | null; approval_status: string | null; version: number; storage_path?: string | null;
  design_id: string | null; design_name: string | null; design_status: string | null; design_round: number | null; status_by: string | null; status_at: string | null; area_status: EmbStatus | string;
  suggested_design_id: string | null; suggested_design_name: string | null; suggested_status: string | null; suggested_why: string | null
}
export interface EmbDesignRow { id: string; customer_id: string; customer_name: string | null; name: string; status: EmbStatus | string; round: number; status_by: string | null; status_at: string | null; note: string | null; created_at: string; orders_using: number }
export interface EmbEventRow { id: number; design_id: string; event: string; from_status: string | null; to_status: string | null; round: number | null; actor: string | null; note: string | null; order_ref: string | null; at: string }

export const EMB_WORDS: Record<EmbStatus, string> = { to_review: 'To review', known: 'Done before', swatch_required: 'Swatch required', swatch_in_progress: 'Swatch in progress', swatch_sent: 'Swatch sent to customer', swatch_approved: 'Swatch approved', changes_needed: 'Changes needed' };
export const embWords = (s: string): string => EMB_WORDS[s as EmbStatus] ?? s.replace(/_/g, ' ');
// A colour and a mark, so it reads without colour: red = nothing done, amber = under way, green = done.
export type EmbLight = 'red' | 'amber' | 'green';
export const EMB_LIGHT: Record<EmbStatus, EmbLight> = { to_review: 'red', swatch_required: 'red', changes_needed: 'red', swatch_in_progress: 'amber', swatch_sent: 'amber', known: 'green', swatch_approved: 'green' };
export const embLight = (s: string): EmbLight => EMB_LIGHT[s as EmbStatus] ?? 'red';
export const EMB_MARK: Record<EmbLight, string> = { red: '✕', amber: '!', green: '✓' };
export const EMB_TONE: Record<EmbLight, Tone> = { red: 'critical', amber: 'medium', green: 'good' };
export const embDone = (s: string): boolean => embLight(s) === 'green';

// The moves the database allows (mirrors flow.emb_set_status). `note` = the person must say why.
export interface EmbMove { to: EmbStatus; label: string; note: boolean; primary?: boolean }
export function embMoves(status: string): EmbMove[] {
  switch (status) {
    case 'swatch_required': return [{ to: 'swatch_in_progress', label: 'Swatch in progress', note: false, primary: true }, { to: 'known', label: 'We have done this logo before', note: false }];
    case 'swatch_in_progress': return [{ to: 'swatch_sent', label: 'Swatch sent to customer', note: false, primary: true }, { to: 'swatch_approved', label: 'Swatch approved', note: false }, { to: 'changes_needed', label: 'Changes needed', note: true }];
    case 'swatch_sent': return [{ to: 'swatch_approved', label: 'Swatch approved', note: false, primary: true }, { to: 'changes_needed', label: 'Changes needed', note: true }];
    case 'changes_needed': return [{ to: 'swatch_in_progress', label: 'Start a new swatch', note: false, primary: true }];
    case 'known': case 'swatch_approved': return [{ to: 'changes_needed', label: 'Changes needed', note: true }, { to: 'swatch_required', label: 'Reopen: the logo has changed', note: true }];
    default: return [];
  }
}
// Only planners may change a design; anyone can look.
export const canChangeEmbroidery = (role: string | null | undefined): boolean => role === 'admin' || role === 'manager' || role === 'production';

// A stitch file can be downloaded only when Flow holds it.
export const hasStitchFile = (r: Pick<EmbAreaRow, 'storage_path' | 'storage_status'>): boolean => !!r.storage_path && (r.storage_status === 'stored' || r.storage_status === 'manual');
export const SCOPE_TABS: { id: 'in_house' | 'third_party' | 'unclassified'; label: string }[] = [{ id: 'in_house', label: 'In house' }, { id: 'third_party', label: 'Third party' }, { id: 'unclassified', label: 'Not decided' }];
export const areasFor = (rows: EmbAreaRow[], scope: string): EmbAreaRow[] => rows.filter((r) => r.scope === scope);
export function embCounts(rows: EmbAreaRow[]) {
  return { total: rows.length, todo: rows.filter((r) => embLight(r.area_status) === 'red').length, busy: rows.filter((r) => embLight(r.area_status) === 'amber').length, done: rows.filter((r) => embDone(r.area_status)).length, suggested: rows.filter((r) => !r.design_id && !!r.suggested_design_id).length };
}
// Worst first: to review and swatches to make before swatches under way before done.
const SEV: Record<EmbLight, number> = { red: 2, amber: 1, green: 0 };
export const embScore = (r: Pick<EmbAreaRow, 'area_status'>): number => SEV[embLight(r.area_status)];
export const sizeText = (r: Pick<EmbAreaRow, 'stitch_count' | 'width_mm' | 'height_mm'>): string => {
  const parts: string[] = []; if (r.stitch_count) parts.push(`${r.stitch_count.toLocaleString('en-GB')} stitches`);
  if (r.width_mm && r.height_mm) parts.push(`${Math.round(Number(r.width_mm))} × ${Math.round(Number(r.height_mm))} mm`); return parts.join(' · ') || '—';
};
export const suggestionText = (r: Pick<EmbAreaRow, 'suggested_design_id' | 'suggested_design_name' | 'suggested_why' | 'suggested_status'>): string =>
  r.suggested_design_id ? `${r.suggested_why ?? 'Looks like'}: ${r.suggested_design_name ?? 'a design we hold'} (${embWords(r.suggested_status ?? '').toLowerCase()})` : '';
export const designsFor = (designs: EmbDesignRow[], customerId: string | null | undefined): EmbDesignRow[] => (customerId ? designs.filter((d) => d.customer_id === customerId).sort((a, b) => a.name.localeCompare(b.name)) : []);
export const eventsFor = (events: EmbEventRow[], designId: string | null | undefined): EmbEventRow[] => (designId ? events.filter((e) => e.design_id === designId).sort((a, b) => a.at.localeCompare(b.at) || a.id - b.id) : []);
export function eventWords(e: EmbEventRow): string {
  switch (e.event) {
    case 'created': return `Design created${e.order_ref ? ' from ' + e.order_ref : ''}`;
    case 'linked': return `Used on ${e.order_ref ?? 'an order'}${e.note ? ' (' + e.note + ')' : ''}`;
    case 'unlinked': return `Taken off ${e.order_ref ?? 'an order'}${e.note ? ' (' + e.note + ')' : ''}`;
    case 'status': return `${embWords(e.from_status ?? '')} → ${embWords(e.to_status ?? '')}${e.round && e.round > 1 ? ` (round ${e.round})` : ''}${e.note ? ': ' + e.note : ''}`;
    default: return e.event.replace(/_/g, ' ');
  }
}
