import type { Tone } from '../ui/primitives';

// Pre-production: before an order can go into production its DTF prints are made or ordered, its embroidery is checked and its stock is bought.
// These three run at the same time and do not depend on each other. The database works out a light for each (public.ui_preproduction) and lists the
// DTF placements (public.ui_dtf_items); these are the read models and the plain words for the screens. Everything here is read-only.
export type Light = 'red' | 'amber' | 'green' | 'none';
export type LightKind = 'prints' | 'embroidery' | 'stock';
export interface PreprodRow {
  order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; order_status: string; scope: string; total_units: number; decoration_methods: string[];
  prints: Light; prints_items: number; prints_units: number; prints_done: number; embroidery: Light; embroidery_areas: number; embroidery_approved: number; embroidery_stored: number; stock: Light
}
export type DtfStatus = 'required' | 'in_progress' | 'done';
export interface DtfItemRow {
  id: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; scope: string; deco_line_id: string; product_name: string | null; area: string; qty: number; status: DtfStatus;
  artwork_id: string | null; thumbnail_url: string | null; file_format: string | null; storage_status: string | null; approval_status: string | null; content_hash: string | null; updated_at: string
}

export const LIGHT_TONE: Record<Light, Tone> = { red: 'critical', amber: 'medium', green: 'good', none: '' };
// A mark as well as a colour, so the light still reads without colour.
export const LIGHT_MARK: Record<Light, string> = { red: '✕', amber: '!', green: '✓', none: '–' };
export const KIND_LABEL: Record<LightKind, string> = { prints: 'Prints', embroidery: 'Embroidery', stock: 'Stock' };

const WORDS: Record<LightKind, Record<Light, string>> = {
  prints: { red: 'Prints required', amber: 'Prints in progress', green: 'Prints done', none: 'No DTF on this order' },
  embroidery: { red: 'Embroidery not ready', amber: 'Embroidery partly ready', green: 'Embroidery ready', none: 'No embroidery on this order' },
  stock: { red: 'Stock not secured', amber: 'Stock partly allocated', green: 'Stock secured', none: '' }
};
export const lightWords = (kind: LightKind, light: Light): string => WORDS[kind][light] ?? '';

// A fuller sentence for the order drawer, using the counts the database gives.
export function lightDetail(kind: LightKind, r: PreprodRow): string {
  if (kind === 'prints') {
    if (r.prints === 'none') return 'This order has no DTF prints.';
    if (r.prints_items === 0) return 'DTF is needed but the placements have not been read from DecoNetwork yet.';
    return `${r.prints_done} of ${r.prints_items} DTF placement${r.prints_items === 1 ? '' : 's'} done · ${r.prints_units.toLocaleString('en-GB')} garment${r.prints_units === 1 ? ' carries' : 's carry'} a DTF print.`;
  }
  if (kind === 'embroidery') {
    if (r.embroidery === 'none') return 'This order has no embroidery.';
    if (r.embroidery_areas === 0) return 'No embroidery artwork is recorded for this order yet.';
    return `${r.embroidery_approved} of ${r.embroidery_areas} embroidery area${r.embroidery_areas === 1 ? '' : 's'} approved · ${r.embroidery_stored} stored and readable.`;
  }
  return r.stock === 'green' ? 'All the stock for this order is secured.' : r.stock === 'amber' ? 'Some of the stock is allocated; the rest still has to be bought or arrive.' : 'The stock for this order is not secured yet.';
}

export const lights = (r: PreprodRow): Light[] => [r.prints, r.embroidery, r.stock];
// Ready for production when nothing that applies is still red or amber.
export const isReady = (r: PreprodRow): boolean => lights(r).every((l) => l === 'green' || l === 'none');
export function preprodCounts(rows: PreprodRow[]) {
  return { total: rows.length, ready: rows.filter(isReady).length, prints: rows.filter((r) => r.prints === 'red' || r.prints === 'amber').length, embroidery: rows.filter((r) => r.embroidery === 'red' || r.embroidery === 'amber').length, stock: rows.filter((r) => r.stock === 'red' || r.stock === 'amber').length };
}
// Worst first, for sorting: not ready before ready, and red before amber before green.
const SEV: Record<Light, number> = { red: 3, amber: 2, green: 0, none: 0 };
export const lightScore = (r: PreprodRow): number => lights(r).reduce((s, l) => s + SEV[l], 0);
export const lightsText = (r: PreprodRow): string => (['prints', 'embroidery', 'stock'] as LightKind[]).map((k) => `${KIND_LABEL[k]}: ${r[k] === 'none' ? 'not needed' : lightWords(k, r[k])}`).join('; ');
export const preprodFor = (rows: PreprodRow[], orderId: string | null | undefined): PreprodRow | null => (orderId ? rows.find((r) => r.order_id === orderId) ?? null : null);

export const STATUS_WORDS: Record<DtfStatus, string> = { required: 'Prints required', in_progress: 'Prints in progress', done: 'Prints done' };
export const STATUS_LIGHT: Record<DtfStatus, Light> = { required: 'red', in_progress: 'amber', done: 'green' };
export const dtfStatusWords = (s: string) => STATUS_WORDS[s as DtfStatus] ?? s.replace(/_/g, ' ');

export const itemsFor = (items: DtfItemRow[], orderId: string | null | undefined): DtfItemRow[] => (orderId ? items.filter((i) => i.order_id === orderId).sort((a, b) => a.area.localeCompare(b.area) || a.deco_line_id.localeCompare(b.deco_line_id)) : []);
// A print can be made or ordered only when Flow holds the real file for it (a stored or hand-uploaded PNG), not just DecoNetwork's placeholder.
export const hasFile = (i: Pick<DtfItemRow, 'artwork_id' | 'storage_status'>): boolean => !!i.artwork_id && (i.storage_status === 'stored' || i.storage_status === 'manual');
export const fileWords = (i: Pick<DtfItemRow, 'artwork_id' | 'storage_status' | 'file_format'>): string => (hasFile(i) ? `File ready${i.file_format ? ' (' + i.file_format.toUpperCase() + ')' : ''}` : i.artwork_id ? 'File not stored yet' : 'No file yet');

// One line per order: how many placements and garments need DTF, how far along, and whether every file is there.
export interface DtfOrderRow { order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; scope: string; placements: number; units: number; done: number; started: number; missingFiles: number; status: DtfStatus }
export function ordersWithDtf(items: DtfItemRow[]): DtfOrderRow[] {
  const m = new Map<string, DtfOrderRow>();
  for (const i of items) {
    const r = m.get(i.order_id) ?? { order_id: i.order_id, order_ref: i.order_ref, customer_name: i.customer_name, due_date: i.due_date, scope: i.scope, placements: 0, units: 0, done: 0, started: 0, missingFiles: 0, status: 'required' as DtfStatus };
    r.placements++; r.units += i.qty; if (i.status === 'done') r.done++; if (i.status === 'in_progress') r.started++; if (!hasFile(i)) r.missingFiles++; m.set(i.order_id, r);
  }
  for (const r of m.values()) r.status = r.done === r.placements ? 'done' : r.done === 0 && r.started === 0 ? 'required' : 'in_progress';
  return [...m.values()].sort((a, b) => (a.due_date ?? '9999').localeCompare(b.due_date ?? '9999') || a.order_ref.localeCompare(b.order_ref));
}

// What has to be made, by design: the same artwork on several orders is one line with its total. Placements with no stored file cannot be matched
// by design, so each stays on its own line, marked as having no file yet.
export interface ArtworkTotal { key: string; thumbnail_url: string | null; file_format: string | null; hasFile: boolean; qty: number; orders: number; placements: number; label: string; outstanding: number }
export function artworkTotals(items: DtfItemRow[]): ArtworkTotal[] {
  const m = new Map<string, { t: ArtworkTotal; orders: Set<string> }>();
  for (const i of items) {
    const key = i.content_hash && hasFile(i) ? 'h:' + i.content_hash : 'n:' + i.order_id + ':' + i.area;
    const e = m.get(key) ?? { t: { key, thumbnail_url: i.thumbnail_url, file_format: i.file_format, hasFile: hasFile(i), qty: 0, orders: 0, placements: 0, label: key.startsWith('h:') ? i.area : `${i.order_ref} · ${i.area}`, outstanding: 0 }, orders: new Set<string>() };
    e.t.qty += i.qty; e.t.placements++; if (i.status !== 'done') e.t.outstanding += i.qty; e.orders.add(i.order_id); e.t.orders = e.orders.size; if (!e.t.thumbnail_url && i.thumbnail_url) e.t.thumbnail_url = i.thumbnail_url; m.set(key, e);
  }
  return [...m.values()].map((e) => e.t).sort((a, b) => b.outstanding - a.outstanding || b.qty - a.qty || a.label.localeCompare(b.label));
}
