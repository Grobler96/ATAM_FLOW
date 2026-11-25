import type { OrderLineRow, OrderRow } from '../data/types';
import { addressLines, type QueueRow } from './dispatch';
import type { ArtworkFileRow } from './proofs';
import { esc, safeUrl } from './proofSheet';

// The production worksheet: one printed sheet per order, laid out like the DecoNetwork production order (delivery address, dispatch date and method,
// then each garment with its sizes and quantities and each design on it). It is made in the browser from what Flow already holds and sends nothing.
// Only what Flow actually holds is printed: where a design has no size, position, stitch count or picture the cell says so, and the sheet lists what is
// missing at the end, so nothing is guessed. The "item" number is DecoNetwork's product line number, the same one the artwork files hang off.
const SIZE_ORDER = ['xxs', 'xs', 'extra small', 's', 'small', 'm', 'medium', 'l', 'large', 'xl', 'extra large', '2xl', 'xxl', '3xl', 'xxxl', '4xl', '5xl'];
const sizeRank = (s: string | null): number => { const i = SIZE_ORDER.indexOf((s ?? '').trim().toLowerCase()); return i === -1 ? 999 : i; };
const day = (iso: string | null | undefined): string => (iso ? new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '—');

export interface WsDesign { area: string; process: string; format: string; version: number; size: string | null; position: string | null; stitches: number | null; approval: string; picture: string; stored: boolean }
export interface WsGarment { key: string; product: string; colour: string; sizes: { size: string; qty: number }[]; total: number; designs: WsDesign[] }
export interface Worksheet { ref: string; customer: string; po: string | null; due: string | null; method: string | null; address: string[]; collection: boolean; garments: WsGarment[]; orderDesigns: WsDesign[]; units: number; gaps: string[] }

const cm = (mm: number): string => `${(mm / 10).toFixed(2).replace(/\.?0+$/, '')}`;
const designOf = (f: ArtworkFileRow): WsDesign => ({
  area: f.area, process: (f.process ?? '').trim() || '—', format: f.file_format ? f.file_format.toUpperCase() : '—', version: f.version,
  size: f.width_mm && f.height_mm ? `${cm(f.width_mm)} x ${cm(f.height_mm)} cm` : null, position: f.placement?.trim() || null, stitches: f.stitch_count && f.stitch_count > 0 ? f.stitch_count : null,
  approval: f.approval_status === 'approved' ? 'Approved' : f.approval_status === 'rejected' ? 'Rejected' : f.approval_status === 'pending' ? 'Waiting for the customer' : 'Not known', picture: safeUrl(f.thumbnail_url), stored: f.storage_status === 'stored' || f.storage_status === 'manual' });

export function buildWorksheet(order: Pick<OrderRow, 'order_ref' | 'customer_name' | 'due_date'>, dispatch: QueueRow | null, lines: OrderLineRow[], files: ArtworkFileRow[]): Worksheet {
  const keyOf = (l: OrderLineRow): string => l.deco_line_id ?? l.sku ?? l.id;
  const current = files.filter((f) => f.is_current);
  const by = new Map<string, WsGarment>();
  for (const l of lines) {
    const k = keyOf(l); let g = by.get(k);
    if (!g) { g = { key: k, product: l.product_name ?? 'Item', colour: l.colour ?? '', sizes: [], total: 0, designs: current.filter((f) => f.deco_line_id === k).sort((a, b) => a.area.localeCompare(b.area)).map(designOf) }; by.set(k, g); }
    const sz = (l.size ?? '').trim() || '—'; const hit = g.sizes.find((s) => s.size === sz);
    if (hit) hit.qty += l.qty_required; else g.sizes.push({ size: sz, qty: l.qty_required });
    g.total += l.qty_required;
  }
  const garments = [...by.values()].map((g) => ({ ...g, sizes: [...g.sizes].sort((a, b) => sizeRank(a.size) - sizeRank(b.size) || a.size.localeCompare(b.size)) })).sort((a, b) => a.key.localeCompare(b.key));
  const lineKeys = new Set(garments.map((g) => g.key));
  const orderDesigns = current.filter((f) => !f.deco_line_id || !lineKeys.has(f.deco_line_id)).sort((a, b) => a.area.localeCompare(b.area)).map(designOf);
  const all = [...garments.flatMap((g) => g.designs), ...orderDesigns];
  const gaps: string[] = [];
  const n = (pred: (d: WsDesign) => boolean): number => all.filter(pred).length;
  if (all.length === 0) gaps.push('No designs are held in Flow for this order yet.');
  if (n((d) => !d.size)) gaps.push(`${n((d) => !d.size)} of ${all.length} designs have no size recorded.`);
  if (n((d) => !d.position)) gaps.push(`${n((d) => !d.position)} of ${all.length} designs have no position recorded.`);
  if (n((d) => d.process.toLowerCase() === 'embroidery' && d.stitches === null)) gaps.push('An embroidery design has no stitch count recorded.');
  if (n((d) => !d.picture)) gaps.push(`${n((d) => !d.picture)} of ${all.length} designs have no picture held in Flow.`);
  if (garments.length) gaps.push('Garment pictures and thread or print colours are not held in Flow: use the DecoNetwork order for those.');
  return { ref: order.order_ref, customer: order.customer_name ?? '—', po: dispatch?.customer_po ?? null, due: order.due_date, method: dispatch?.shipping_method ?? null, address: dispatch ? addressLines(dispatch.ship_to) : [], collection: !!dispatch?.is_collection, garments, orderDesigns, units: garments.reduce((s, g) => s + g.total, 0), gaps };
}

const CSS = `*{box-sizing:border-box}body{font:12px/1.35 Arial,Helvetica,sans-serif;color:#111;margin:0}.pg{padding:12mm}.bar{background:#111;color:#fff;font-size:17px;text-align:right;padding:6px 10px;margin-bottom:10px}
.top{display:flex;justify-content:space-between;gap:12mm;margin-bottom:10px}h2{font-size:15px;margin:0 0 4px}.dim{color:#555}.hl{background:#ff0;padding:0 3px}.k{color:#555;font-size:10px;text-transform:uppercase;letter-spacing:.04em}
.item{background:#777;color:#fff;font-weight:bold;padding:4px 8px;margin-top:10px;display:flex;justify-content:space-between}table{width:100%;border-collapse:collapse;margin:4px 0}th,td{border:1px solid #bbb;padding:3px 6px;text-align:left;vertical-align:top}th{background:#eee;font-size:10px;text-transform:uppercase}
.pic{width:30mm}.pic img{max-width:28mm;max-height:22mm}.none{color:#a00}.sz td,.sz th{text-align:center}.box{border:1px solid #999;padding:6px;margin:8px 0;min-height:18mm}.gap{border:1px dashed #a00;padding:6px;margin-top:10px;color:#a00}.gap ul{margin:2px 0 0 16px;padding:0}
@media print{.pg{padding:8mm}}`;

const designRows = (ds: WsDesign[]): string => ds.length === 0 ? '<tr><td colspan="7" class="none">No design held in Flow for this item.</td></tr>' : ds.map((d) => `<tr><td class="pic">${d.picture ? `<img src="${esc(d.picture)}" alt="">` : '<span class="none">no picture</span>'}</td><td><b>${esc(d.area)}</b><br><span class="dim">${esc(d.process)}</span></td>
<td>${d.size ? esc(d.size) : '<span class="none">not recorded</span>'}</td><td>${d.position ? esc(d.position) : '<span class="none">not recorded</span>'}</td><td>${d.stitches !== null ? d.stitches.toLocaleString('en-GB') : d.process.toLowerCase() === 'embroidery' ? '<span class="none">not recorded</span>' : '—'}</td>
<td>${esc(d.format)} v${d.version}${d.stored ? '' : '<br><span class="none">file not stored</span>'}</td><td>${esc(d.approval)}</td></tr>`).join('');
const DHEAD = '<thead><tr><th>Picture</th><th>Placement</th><th>Size</th><th>Position</th><th>Stitches</th><th>File</th><th>Customer approval</th></tr></thead>';

export function worksheetHtml(w: Worksheet, printedAt: Date = new Date()): string {
  const addr = w.collection ? '<b>Customer collects</b>' : w.address.length ? w.address.map((a) => esc(a)).join('<br>') : '<span class="none">No delivery address held in Flow</span>';
  const garments = w.garments.map((g) => `<div class="item"><span>ITEM: ${esc(g.key)} &nbsp; ${esc(g.product)}</span><span>${esc(g.colour)}</span></div>
<table class="sz"><thead><tr><th>Size</th>${g.sizes.map((s) => `<th>${esc(s.size)}</th>`).join('')}<th>Total</th></tr></thead><tbody><tr><td>Qty</td>${g.sizes.map((s) => `<td>${s.qty}</td>`).join('')}<td><b class="hl">${g.total}</b></td></tr></tbody></table>
<table>${DHEAD}<tbody>${designRows(g.designs)}</tbody></table>`).join('');
  const extra = w.orderDesigns.length ? `<div class="item"><span>DESIGNS FOR THE WHOLE ORDER</span><span></span></div><table>${DHEAD}<tbody>${designRows(w.orderDesigns)}</tbody></table>` : '';
  return `<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><title>Production worksheet ${esc(w.ref)}</title><style>${CSS}</style></head><body><section class="pg">
<div class="bar">PRODUCTION ORDER #: ${esc(w.ref.replace('#', ''))}</div>
<div class="top"><div><h2>DELIVERY ADDRESS</h2><div><b>${esc(w.customer)}</b></div><div>${addr}</div></div>
<div><div><span class="k">Dispatch date</span><br><b class="hl">${esc(day(w.due))}</b></div><div style="margin-top:6px"><span class="k">Dispatch by</span><br><b class="hl">${esc(w.method ?? '—')}</b></div>${w.po ? `<div style="margin-top:6px"><span class="k">Customer PO</span><br>${esc(w.po)}</div>` : ''}<div style="margin-top:6px"><span class="k">Units</span><br><b>${w.units}</b></div></div></div>
<div class="box"><div class="k">Order notes</div></div>
${garments}${extra}
<div class="gap"><b>Not held in Flow (nothing here is guessed):</b><ul>${w.gaps.map((g) => `<li>${esc(g)}</li>`).join('')}</ul></div>
<p class="dim">Printed ${esc(day(printedAt.toISOString()))} from ATAM_FLOW.</p></section><script>window.onload=function(){setTimeout(function(){window.print()},300)}</script></body></html>`;
}

// Opens the sheet in a new window and prints. Returns false if the browser blocked the window.
export function printWorksheet(w: Worksheet): boolean {
  const win = window.open('', '_blank'); if (!win) return false;
  win.document.open(); win.document.write(worksheetHtml(w)); win.document.close(); return true;
}
