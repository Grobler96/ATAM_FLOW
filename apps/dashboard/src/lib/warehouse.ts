import { exceptionActionTo } from './api';
import type { ActionResult } from '../types';

// Every warehouse change goes through the audited "Warehouse actions" n8n workflow.
export const whAction = (action: string, params: Record<string, unknown>): Promise<ActionResult> => exceptionActionTo('warehouse', action, params);

export const LABEL_TYPES: { id: string; label: string; target: string }[] = [
  { id: 'order', label: 'Order', target: 'orders' }, { id: 'pick', label: 'Pick list', target: 'orders' }, { id: 'bin', label: 'Bin', target: 'bins' },
  { id: 'stock', label: 'Stock', target: 'SKUs' }, { id: 'producer', label: 'Producer movement', target: 'producer movements' }, { id: 'dispatch', label: 'Dispatch', target: 'orders' }
];
export const labelTypeName = (t: string): string => LABEL_TYPES.find((x) => x.id === t)?.label ?? t;
export type PrintFormat = 'A4' | 'thermal';
export const FORMAT_LABEL: Record<PrintFormat, string> = { A4: 'A4 sheet (2 labels across)', thermal: 'Thermal 100 × 150 mm' };

// Short, human-checkable text lines for a label, in the order they are printed.
export function labelLines(type: string, p: Record<string, any> | null): [string, string][] {
  if (!p) return [];
  const bins = (p.bins ?? []).map((b: any) => `${b.bin_code} (${b.units})`).join(', ');
  switch (type) {
    case 'order': case 'dispatch': return [['Customer', p.customer], ['Due', p.due_date], ['Units', p.total_units], ['Priority', p.priority], ['Decoration', (p.methods ?? []).join(' + ')], ['Shipping', p.shipping_method], ['Bin', bins], ['Notes', p.notes]];
    case 'pick': return [['Customer', p.customer], ['Due', p.due_date], ['Units', p.total_units], ['Bin', bins], ...((p.lines ?? []) as any[]).slice(0, 14).map((l): [string, string] => [l.sku ?? l.product, `${l.qty} × ${[l.colour, l.size].filter(Boolean).join(' ')}`])];
    case 'bin': return [['Zone', p.zone], ['Type', String(p.location_type ?? '').replace(/_/g, ' ')], ['Capacity', p.capacity_units ?? 'No limit']];
    case 'stock': return [['Product', p.product], ['Colour', p.colour], ['Size', p.size], ['Brand', p.brand], ['Supplier', p.supplier], ['Location', p.location]];
    case 'producer': return [['Producer', p.producer], ['Orders', (p.orders ?? []).join(', ')], ['Units', p.total_units], ['Contents', p.contents], ['Decoration', p.decoration], ['Due back', p.due_back], ['Priority', p.priority], ['Notes', p.special_instructions]];
    default: return Object.entries(p).slice(0, 8).map(([k, v]) => [k, String(v)]);
  }
}
export const labelHeadline = (p: Record<string, any> | null, fallback: string): string => {
  if (!p) return fallback;
  return String(p.order_ref ?? p.bin_code ?? p.sku ?? p.movement ?? fallback);
};
