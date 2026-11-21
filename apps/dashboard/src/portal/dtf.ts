// The decorator's DTF screen: placements the decorator has to print, grouped for download and for the order sheet. Pure helpers, no network.
export type PortalDtfStatus = 'required' | 'in_progress' | 'done';
export interface PortalDtfItem {
  id: string; order_ref: string; customer: string | null; due_date: string | null; area: string; product: string | null; qty: number; status: PortalDtfStatus;
  file: string | null; file_name: string | null; file_format: string | null; thumbnail_url: string | null; design_key: string | null;
}
export const DTF_WORDS: Record<PortalDtfStatus, string> = { required: 'Prints required', in_progress: 'Prints in production', done: 'Produced' };
export const DTF_MARK: Record<PortalDtfStatus, string> = { required: '✕', in_progress: '!', done: '✓' };
export const dtfWords = (s: string) => DTF_WORDS[s as PortalDtfStatus] ?? s.replace(/_/g, ' ');
export const hasDownload = (i: Pick<PortalDtfItem, 'file'>): boolean => !!i.file;

// The order sheet: one line per design, with the total garments that need it, the orders it is for and how many are still to make.
export interface SheetLine { key: string; label: string; thumbnail_url: string | null; file_name: string | null; hasFile: boolean; qty: number; outstanding: number; orders: string[]; ids: string[] }
export function orderSheet(items: PortalDtfItem[]): SheetLine[] {
  const m = new Map<string, SheetLine>();
  for (const i of items) {
    const key = i.design_key && i.file ? 'd:' + i.design_key : 'n:' + i.order_ref + ':' + i.area;
    const l = m.get(key) ?? { key, label: key.startsWith('d:') ? (i.file_name ?? i.area) : `${i.order_ref} · ${i.area}`, thumbnail_url: i.thumbnail_url, file_name: i.file_name, hasFile: !!i.file, qty: 0, outstanding: 0, orders: [], ids: [] };
    l.qty += i.qty; if (i.status !== 'done') l.outstanding += i.qty; if (!l.orders.includes(i.order_ref)) l.orders.push(i.order_ref); l.ids.push(i.id);
    if (!l.thumbnail_url && i.thumbnail_url) l.thumbnail_url = i.thumbnail_url; m.set(key, l);
  }
  return [...m.values()].sort((a, b) => b.outstanding - a.outstanding || a.label.localeCompare(b.label));
}

export interface DtfOrderGroup { order_ref: string; customer: string | null; due_date: string | null; items: PortalDtfItem[]; status: PortalDtfStatus }
export function groupByOrder(items: PortalDtfItem[]): DtfOrderGroup[] {
  const m = new Map<string, DtfOrderGroup>();
  for (const i of items) { const g = m.get(i.order_ref) ?? { order_ref: i.order_ref, customer: i.customer, due_date: i.due_date, items: [], status: 'required' as PortalDtfStatus }; g.items.push(i); m.set(i.order_ref, g); }
  for (const g of m.values()) g.status = g.items.every((i) => i.status === 'done') ? 'done' : g.items.every((i) => i.status === 'required') ? 'required' : 'in_progress';
  return [...m.values()].sort((a, b) => (a.due_date ?? '9999').localeCompare(b.due_date ?? '9999') || a.order_ref.localeCompare(b.order_ref));
}
// What the buttons act on: only placements that can still move that way.
export const canStart = (items: PortalDtfItem[]) => items.filter((i) => i.status === 'required');
export const canFinish = (items: PortalDtfItem[]) => items.filter((i) => i.status !== 'done');
export const downloadable = (items: PortalDtfItem[]) => items.filter(hasDownload);
// Several placements can share one file; download each file once.
export function uniqueFiles(items: PortalDtfItem[]): { file: string; name: string }[] {
  const seen = new Set<string>(); const out: { file: string; name: string }[] = [];
  for (const i of items) if (i.file && !seen.has(i.file)) { seen.add(i.file); out.push({ file: i.file, name: i.file_name ?? i.file.split('/').pop() ?? 'file' }); }
  return out;
}
