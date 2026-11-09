import { opsAction } from './orderChanges';
import { barcodeSvg, LABEL_CSS, qrDataUrl } from './labelPrint';
import type { PrintFormat } from './warehouse';
import type { ActionResult } from '../types';

export interface QueueRow {
  order_id: string; order_ref: string; customer_name: string | null; customer_po: string | null; due_date: string | null; days_to_due: number | null; priority: number; is_vip: boolean; scope: string;
  order_status: string; units: number; ready_units: number; routed_units: number; shipping_method: string | null; ship_to: string | null; ship_country: string | null; is_collection: boolean;
  can_pack: boolean; partial: boolean; blockers: string[]; bins: string | null; parcels: number; parcels_handed: number; parcels_printed: number; tracking: string | null; carrier: string | null;
  last_handed_at: string | null; shipped_at: string | null; stage: 'blocked' | 'ready' | 'packed' | 'with_courier' | 'shipped';
}
export interface ParcelRow {
  id: string; order_id: string; order_ref: string; customer_name: string | null; due_date: string | null; parcel_no: number; parcels_total: number; label_code: string; kind: 'courier' | 'collection';
  weight_kg: number | null; carrier: string | null; service: string | null; tracking_ref: string | null; status: 'packed' | 'handed_over' | 'cancelled'; note: string | null; override_reason: string | null;
  packed_by: string; packed_at: string; print_count: number; last_printed_at: string | null; last_printed_by: string | null; handed_by: string | null; handed_at: string | null; cancelled_at: string | null; cancel_reason: string | null;
  ship_to: string | null; shipping_method: string | null; customer_po: string | null; ship_country: string | null;
}

export const STAGE_LABEL: Record<QueueRow['stage'], string> = { ready: 'Ready to pack', blocked: 'Blocked', packed: 'Packed', with_courier: 'With courier', shipped: 'Shipped' };
export const STAGE_TONE: Record<QueueRow['stage'], 'good' | 'high' | 'info' | ''> = { ready: 'good', blocked: 'high', packed: 'info', with_courier: 'info', shipped: '' };

// Writes go through the Operations actions workflow, which checks the caller's role and the database checks the rest.
export const dispatchPack = (p: { order_id: string; parcels: number; weights?: number[]; carrier?: string; service?: string; note?: string; override?: string }): Promise<ActionResult> => opsAction('dispatch_pack', p);
export const dispatchPrinted = (order_id: string, reason?: string): Promise<ActionResult> => opsAction('dispatch_printed', { order_id, reason });
export const dispatchTracking = (order_id: string, tracking: string, carrier?: string, parcel_no?: number | null): Promise<ActionResult> => opsAction('dispatch_tracking', { order_id, tracking, carrier, parcel_no: parcel_no ?? null });
export const dispatchHandover = (label: string, override?: string): Promise<ActionResult> => opsAction('dispatch_handover', { label, override });
export const dispatchCancel = (order_id: string, reason: string): Promise<ActionResult> => opsAction('dispatch_cancel', { order_id, reason });

const esc = (v: unknown): string => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

// DecoNetwork gives one block of text. Keep its own line breaks; if it is all on one line, break at the commas so it reads like an address.
export function addressLines(text: string | null | undefined): string[] {
  const t = String(text ?? '').replace(/\r/g, '').trim(); if (!t) return [];
  const parts = t.includes('\n') ? t.split('\n') : t.split(/,\s*/);
  return parts.map((x) => x.replace(/^,+|,+$/g, '').trim()).filter(Boolean);
}

// One courier label. Delivery labels carry the address; collections say COLLECTION and who it is for. The barcode and QR are the label code, which the scanner reads.
export async function parcelLabelHtml(p: ParcelRow, format: PrintFormat): Promise<string> {
  const qr = await qrDataUrl(p.label_code); const bar = barcodeSvg(p.label_code); const coll = p.kind === 'collection';
  const addr = addressLines(p.ship_to);
  const meta: [string, string | null][] = [['Order', p.order_ref], ['PO', p.customer_po], ['Service', [p.shipping_method, p.service].filter(Boolean).join(' · ') || null], ['Weight', p.weight_kg ? `${p.weight_kg} kg` : null], ['Note', p.note]];
  return `<section class="lbl ${format} dsp"><header><span class="type">${coll ? 'Collection' : 'Delivery'}</span><span class="v">Parcel ${p.parcel_no} of ${p.parcels_total}${p.print_count > 0 ? ' · REPRINT' : ''}</span></header>
${coll ? `<div class="big">COLLECTION</div><div class="to"><b>${esc(p.customer_name)}</b></div>` : `<div class="to">${addr.length ? addr.map((l, i) => `<div class="${i === 0 ? 'first' : ''}">${esc(l)}</div>`).join('') : '<div class="first">NO ADDRESS: check the order</div>'}</div>`}
<div class="body"><dl>${meta.filter(([, v]) => v).map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl><img class="qr" alt="QR code" src="${qr}"></div>
<footer>${bar}<span class="code">${esc(p.label_code)}</span></footer></section>`;
}

const DSP_CSS = `.dsp .to{font-size:15pt;font-weight:700;line-height:1.2;flex:1;min-height:0;overflow:hidden}.dsp .to .first{font-size:17pt;font-weight:800}.dsp .big{font-size:26pt;font-weight:800}.dsp .body{flex:none}`;

// Opens the browser print dialog with the parcel labels. Returns false if the browser blocked the window.
export async function printParcelLabels(parcels: ParcelRow[], format: PrintFormat): Promise<boolean> {
  const parts: string[] = []; for (const p of parcels) parts.push(await parcelLabelHtml(p, format));
  const page = format === 'thermal' ? '@page{size:100mm 150mm;margin:0}' : '@page{size:A4;margin:8mm}';
  const body = format === 'A4' ? `<div style="display:grid;grid-template-columns:repeat(2,95mm);gap:4mm">${parts.join('')}</div>` : parts.join('');
  const w = window.open('', '_blank', 'width=900,height=700'); if (!w) return false;
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>ATAM_FLOW courier labels</title><style>${page}${LABEL_CSS}${DSP_CSS}</style></head><body>${body}<script>window.onload=function(){setTimeout(function(){window.focus();window.print();},250)}<\/script></body></html>`);
  w.document.close(); return true;
}
