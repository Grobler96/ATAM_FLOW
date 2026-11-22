import { extOf, safeName } from './artworkFiles';
import type { EmbAreaRow, EmbDesignRow } from './embroidery';

// The swatch email: the physical swatch is photographed and emailed to the customer to sign off. Staff edit the wording as a template; the dashboard fills
// in the placeholders, staff can still change the text, and the email goes into the normal approval queue (nothing is sent until a person approves it).
export interface EmailTemplateRow { code: string; kind: string; name: string; subject: string; body: string; is_default: boolean; is_active: boolean; updated_by: string | null; updated_at: string }
export interface EmbSwatchRow { id: string; design_id: string; round: number; order_ref: string | null; area: string | null; to_addresses: string[]; subject: string; template_code: string | null; photo_path: string; status: 'queued' | 'sent' | 'cancelled' | string; created_by: string | null; created_at: string; sent_at: string | null; comm_ref: string | null; comm_status: string | null }

export const PLACEHOLDERS: { token: string; means: string }[] = [
  { token: '{customer}', means: 'The customer\'s name' }, { token: '{logo}', means: 'The logo\'s name' }, { token: '{order_ref}', means: 'The order number' },
  { token: '{placement}', means: 'Where it goes, for example Left Chest' }, { token: '{round}', means: 'Which sample this is (1, 2, 3…)' }
];
const KNOWN = new Set(PLACEHOLDERS.map((p) => p.token.slice(1, -1)));
export interface SwatchVars { customer: string; logo: string; order_ref: string; placement: string; round: string }
export const swatchVars = (row: Pick<EmbAreaRow, 'customer_name' | 'design_name' | 'order_ref' | 'area' | 'design_round'>): SwatchVars => ({ customer: row.customer_name ?? 'there', logo: row.design_name ?? 'logo', order_ref: row.order_ref, placement: row.area, round: String(row.design_round ?? 1) });
export const fillTemplate = (text: string, v: SwatchVars): string => text.replace(/\{(\w+)\}/g, (m, k: string) => (KNOWN.has(k) ? (v as unknown as Record<string, string>)[k] : m));
// Anything in curly brackets that is not a placeholder we know, so the editor can warn before it goes out looking broken.
export const unknownPlaceholders = (text: string): string[] => [...new Set([...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).filter((k) => !KNOWN.has(k)).map((k) => `{${k}}`))];
export const activeTemplates = (list: EmailTemplateRow[]): EmailTemplateRow[] => list.filter((t) => t.is_active && t.kind === 'embroidery_swatch').sort((a, b) => Number(b.is_default) - Number(a.is_default) || a.name.localeCompare(b.name));
export const defaultTemplate = (list: EmailTemplateRow[]): EmailTemplateRow | null => activeTemplates(list)[0] ?? null;

export const EMAIL_RE = /^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$/;
export const parseAddresses = (s: string): string[] => [...new Set(s.split(/[\s,;]+/).map((x) => x.trim().toLowerCase()).filter(Boolean))];
export const addressProblem = (list: string[]): string | null => (list.length === 0 ? 'Add the customer\'s email address.' : list.length > 5 ? 'Five addresses at most.' : list.find((a) => !EMAIL_RE.test(a)) ? `"${list.find((a) => !EMAIL_RE.test(a))}" is not an email address.` : null);
// The addresses last used for this customer, newest first, so the next swatch email starts filled in.
export function lastAddresses(customerId: string | null | undefined, swatches: EmbSwatchRow[], designs: EmbDesignRow[]): string[] {
  if (!customerId) return []; const mine = new Set(designs.filter((d) => d.customer_id === customerId).map((d) => d.id));
  const s = swatches.filter((x) => mine.has(x.design_id) && x.status !== 'cancelled').sort((a, b) => b.created_at.localeCompare(a.created_at))[0]; return s ? s.to_addresses : [];
}

export const PHOTO_EXT = ['jpg', 'jpeg', 'png', 'webp'];
export const MAX_PHOTO_BYTES = 10 * 1024 * 1024;
export function photoProblem(file: File | null): string | null {
  if (!file) return 'Add a photo of the swatch.'; if (file.size === 0) return 'That photo is empty.';
  if (file.size > MAX_PHOTO_BYTES) return `That photo is ${(file.size / 1048576).toFixed(0)} MB. The limit is ${MAX_PHOTO_BYTES / 1048576} MB.`;
  const e = extOf(file.name); return PHOTO_EXT.includes(e) ? null : `.${e || '?'} photos are not accepted. Use ${PHOTO_EXT.join(', ')}.`;
}
export const swatchPhotoPath = (designId: string, round: number, fileName: string, stamp = Date.now()): string => `swatches/${designId}/r${round}-${stamp}-${safeName(fileName)}`;

export const swatchEmailWords = (s: Pick<EmbSwatchRow, 'status' | 'comm_status'>): string => {
  if (s.status === 'sent') return 'Sent to the customer'; if (s.status === 'cancelled') return 'Cancelled';
  return s.comm_status === 'approved' || s.comm_status === 'sending' ? 'Approved, about to send' : s.comm_status === 'failed' ? 'Sending failed' : 'Waiting for approval';
};
export const swatchesFor = (list: EmbSwatchRow[], designId: string | null | undefined): EmbSwatchRow[] => (designId ? list.filter((s) => s.design_id === designId).sort((a, b) => b.created_at.localeCompare(a.created_at)) : []);
export const swatchWaiting = (list: EmbSwatchRow[], designId: string, round: number): EmbSwatchRow | null => list.find((s) => s.design_id === designId && s.round === round && s.status === 'queued') ?? null;
// The email can be sent while the swatch is in progress.
export const canEmailSwatch = (status: string | null | undefined): boolean => status === 'swatch_in_progress';
