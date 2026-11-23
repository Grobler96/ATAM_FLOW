import { money } from './domain';

// Supplier cards: who we buy from, how we order from them, and what delivery costs. The database checks every change (and who may make it);
// this mirrors the plain words and the simple checks so a form can tell people what is wrong before it asks.
export type OrderMethod = 'email' | 'api' | 'edi' | 'portal' | 'phone' | 'other';
export interface SupplierCardRow {
  id: string; code: string; name: string; contact_name: string | null; email: string | null; phone: string | null; address: string | null; website: string | null; account_number: string | null;
  payment_terms: string | null; lead_time_days: number; min_order_value: number | null; currency: string; order_method: OrderMethod | string; order_method_notes: string | null; notes: string | null;
  can_deliver_to_producer: boolean; is_active: boolean; updated_at: string; catalogue_items: number
}
export interface ShippingOptionRow { id: string; supplier_id: string; name: string; cost: number; free_over: number | null; lead_time_days: number | null; cut_off_time: string | null; is_default: boolean; is_active: boolean; notes: string | null; updated_at: string }

export const ORDER_METHODS: { id: OrderMethod; label: string; hint: string }[] = [
  { id: 'email', label: 'Email', hint: 'Flow queues the purchase order as an email for approval.' },
  { id: 'api', label: 'API (automatic)', hint: 'Orders will be sent straight to their system. Keep the keys in n8n, not here.' },
  { id: 'edi', label: 'EDI (automatic)', hint: 'Orders will be sent as EDI files. Keep the connection details in n8n, not here.' },
  { id: 'portal', label: 'Their website', hint: 'Someone places the order on the supplier\'s website.' },
  { id: 'phone', label: 'Phone', hint: 'Someone rings the order through.' },
  { id: 'other', label: 'Something else', hint: 'Say how in the notes.' }
];
export const orderMethodLabel = (m: string): string => ORDER_METHODS.find((x) => x.id === m)?.label ?? m;
export const orderMethodHint = (m: string): string => ORDER_METHODS.find((x) => x.id === m)?.hint ?? '';
export const isAutomatic = (m: string): boolean => m === 'api' || m === 'edi';
export const canEditSuppliers = (role: string | null | undefined): boolean => role === 'admin' || role === 'manager';

const price = (n: number): string => money(n, 2);
export const optionsFor = (all: ShippingOptionRow[], supplierId: string): ShippingOptionRow[] => all.filter((o) => o.supplier_id === supplierId).sort((a, b) => Number(b.is_active) - Number(a.is_active) || Number(b.is_default) - Number(a.is_default) || a.cost - b.cost || a.name.localeCompare(b.name));
export const defaultOption = (opts: ShippingOptionRow[]): ShippingOptionRow | null => opts.find((o) => o.is_default && o.is_active) ?? null;
export function optionWords(o: Pick<ShippingOptionRow, 'name' | 'cost' | 'free_over' | 'lead_time_days' | 'cut_off_time'>): string {
  const parts = [`${o.name} ${o.cost > 0 ? price(o.cost) : 'free'}`]; if (o.free_over != null && o.cost > 0) parts.push(`free over ${price(o.free_over)}`);
  if (o.lead_time_days != null) parts.push(`${o.lead_time_days} day${o.lead_time_days === 1 ? '' : 's'}`); if (o.cut_off_time) parts.push(`order by ${o.cut_off_time}`); return parts.join(' · ');
}
export function shippingSummary(opts: ShippingOptionRow[]): string {
  const on = opts.filter((o) => o.is_active); if (on.length === 0) return 'No delivery options yet';
  const d = defaultOption(on); return `${on.length} option${on.length === 1 ? '' : 's'}${d ? ' · usually ' + optionWords(d).split(' · ').slice(0, 2).join(' · ') : ''}`;
}
// The gaps that stop a supplier being used, in plain words.
export function cardGaps(c: Pick<SupplierCardRow, 'order_method' | 'email' | 'catalogue_items' | 'is_active'>, opts: ShippingOptionRow[], priceDaysOld?: number | null): string[] {
  if (!c.is_active) return []; const g: string[] = [];
  if (c.order_method === 'email' && !c.email) g.push('No email address to send orders to');
  if (!opts.some((o) => o.is_active)) g.push('No delivery option');
  if (c.catalogue_items === 0) g.push('No prices in the catalogue');
  else if (priceDaysOld !== null && priceDaysOld !== undefined && priceDaysOld >= 90) g.push(`Prices were last loaded ${priceDaysOld} days ago: load the supplier's latest price file`);
  return g;
}
export const sortCards = (list: SupplierCardRow[]): SupplierCardRow[] => [...list].sort((a, b) => Number(b.is_active) - Number(a.is_active) || a.name.localeCompare(b.name));
export const matchesCard = (c: SupplierCardRow, q: string): boolean => { const t = q.trim().toLowerCase(); return !t || [c.name, c.code, c.contact_name, c.email, c.account_number].join(' ').toLowerCase().includes(t); };

export const EMAIL_OK = /^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$/;
const num = (s: string): number | null => { const t = s.trim(); if (t === '') return null; const n = Number(t); return Number.isFinite(n) ? n : NaN; };
export interface SupplierForm { name: string; contact_name: string; email: string; phone: string; address: string; website: string; account_number: string; payment_terms: string; lead_time_days: string; min_order_value: string; order_method: string; order_method_notes: string; notes: string; can_deliver_to_producer: boolean; is_active: boolean }
export const emptySupplierForm = (): SupplierForm => ({ name: '', contact_name: '', email: '', phone: '', address: '', website: '', account_number: '', payment_terms: '', lead_time_days: '3', min_order_value: '', order_method: 'email', order_method_notes: '', notes: '', can_deliver_to_producer: false, is_active: true });
export const formFromCard = (c: SupplierCardRow): SupplierForm => ({ name: c.name, contact_name: c.contact_name ?? '', email: c.email ?? '', phone: c.phone ?? '', address: c.address ?? '', website: c.website ?? '', account_number: c.account_number ?? '', payment_terms: c.payment_terms ?? '', lead_time_days: String(c.lead_time_days ?? ''), min_order_value: c.min_order_value == null ? '' : String(c.min_order_value), order_method: c.order_method, order_method_notes: c.order_method_notes ?? '', notes: c.notes ?? '', can_deliver_to_producer: c.can_deliver_to_producer, is_active: c.is_active });
export function supplierProblem(f: SupplierForm): string | null {
  if (!f.name.trim()) return 'Give the supplier a name.'; if (f.email.trim() && !EMAIL_OK.test(f.email.trim())) return `"${f.email.trim()}" is not an email address.`;
  const lead = num(f.lead_time_days); if (lead === null || Number.isNaN(lead) || lead < 0 || lead > 99) return 'The lead time has to be between 0 and 99 days.';
  const min = num(f.min_order_value); if (Number.isNaN(min) || (min !== null && min < 0)) return 'The minimum order has to be an amount, or empty.'; return null;
}
export const supplierPayload = (f: SupplierForm): Record<string, unknown> => ({ ...f, name: f.name.trim(), email: f.email.trim() });

export interface ShippingForm { name: string; cost: string; free_over: string; lead_time_days: string; cut_off_time: string; notes: string; is_default: boolean; is_active: boolean }
export const emptyShippingForm = (first: boolean): ShippingForm => ({ name: '', cost: '0', free_over: '', lead_time_days: '', cut_off_time: '', notes: '', is_default: first, is_active: true });
export const formFromOption = (o: ShippingOptionRow): ShippingForm => ({ name: o.name, cost: String(o.cost), free_over: o.free_over == null ? '' : String(o.free_over), lead_time_days: o.lead_time_days == null ? '' : String(o.lead_time_days), cut_off_time: o.cut_off_time ?? '', notes: o.notes ?? '', is_default: o.is_default, is_active: o.is_active });
export function shippingProblem(f: ShippingForm): string | null {
  if (!f.name.trim()) return 'Give the option a name, for example Standard or Next day.';
  const cost = num(f.cost || '0'); if (cost === null || Number.isNaN(cost) || cost < 0) return 'The cost has to be an amount, or 0 for free.';
  const free = num(f.free_over); if (Number.isNaN(free) || (free !== null && free < 0)) return 'The free-over amount has to be an amount, or empty.';
  const lead = num(f.lead_time_days); if (Number.isNaN(lead) || (lead !== null && lead < 0)) return 'The lead time has to be a number of days, or empty.';
  if (f.cut_off_time.trim() && !/^([01]?\d|2[0-3]):[0-5]\d$/.test(f.cut_off_time.trim())) return 'The cut-off has to be a time like 14:30, or empty.'; return null;
}
export const shippingPayload = (f: ShippingForm): Record<string, unknown> => ({ ...f, name: f.name.trim(), cost: f.cost.trim() || '0' });
