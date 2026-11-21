import { embWords, sizeText, type EmbAreaRow } from './embroidery';

// The embroidery proof sheet: one printed page per embroidery area, for the person running the physical swatch. It shows the order, customer and logo
// with its stitch count and size, and leaves boxes to write in the thread colours and machine, whether the swatch matches the visual, and the
// customer's sign-off. Thread colours are not in the data we pull from DecoNetwork, so they are filled in by hand. Made in the browser; nothing is sent.
export const esc = (s: unknown): string => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
// Only a normal web address is used for the picture.
export const safeUrl = (u: string | null | undefined): string => (u && /^https?:\/\//i.test(u) ? u : '');
const where = (scope: string): string => (scope === 'third_party' ? 'Third party' : scope === 'in_house' ? 'In house' : 'Not decided');
const day = (iso: string | null | undefined): string => (iso ? new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }) : '—');
export const proofTitle = (rows: EmbAreaRow[]): string => (rows.length === 1 ? `Proof sheet ${rows[0].order_ref} ${rows[0].area}` : `Proof sheets (${rows.length})`);

const CSS = `*{box-sizing:border-box}body{font:13px/1.4 Arial,Helvetica,sans-serif;color:#111;margin:0}.pg{padding:14mm;page-break-after:always;min-height:270mm}.pg:last-child{page-break-after:auto}
h1{font-size:20px;margin:0 0 2px}.sub{color:#555;margin:0 0 10px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:6px 18px;margin:8px 0}.k{color:#555;font-size:11px;text-transform:uppercase;letter-spacing:.04em}.v{font-weight:bold}
.logo{border:1px solid #999;height:70mm;display:flex;align-items:center;justify-content:center;margin:8px 0}.logo img{max-width:100%;max-height:100%}table{width:100%;border-collapse:collapse;margin:6px 0}th,td{border:1px solid #999;padding:5px 6px;text-align:left;height:8mm}th{background:#eee;font-size:11px}
.box{border:1px solid #999;padding:6px;margin:6px 0;min-height:16mm}.tick{display:inline-block;width:4mm;height:4mm;border:1px solid #111;margin:0 3px -1px 10px}.warn{color:#a00;font-weight:bold}@media print{.pg{padding:10mm}}`;

export function proofSheetHtml(rows: EmbAreaRow[], printedAt: Date = new Date()): string {
  const pages = rows.map((r) => {
    const img = safeUrl(r.thumbnail_url);
    return `<section class="pg"><h1>Embroidery proof sheet</h1><p class="sub">Printed ${esc(day(printedAt.toISOString()))} · ${esc(where(r.scope))} order</p>
<div class="grid"><div><div class="k">Order</div><div class="v">${esc(r.order_ref)}</div></div><div><div class="k">Due</div><div class="v">${esc(day(r.due_date))}</div></div>
<div><div class="k">Customer</div><div class="v">${esc(r.customer_name ?? '—')}</div></div><div><div class="k">Placement</div><div class="v">${esc(r.area)}</div></div>
<div><div class="k">Logo</div><div class="v">${esc(r.design_name ?? 'Not linked to a design yet')}</div></div><div><div class="k">Status${r.design_round && r.design_round > 1 ? ' · round ' + esc(r.design_round) : ''}</div><div class="v">${esc(embWords(r.area_status))}</div></div>
<div><div class="k">Stitches · size</div><div class="v">${esc(sizeText(r))}</div></div><div><div class="k">File</div><div class="v">${esc(r.file_format ? r.file_format.toUpperCase() : '—')} · version ${esc(r.version)}</div></div></div>
<div class="logo">${img ? `<img src="${esc(img)}" alt="Logo visual">` : '<span class="warn">No picture of the visual is held in Flow: use the one on the DecoNetwork order.</span>'}</div>
<table><thead><tr><th style="width:12mm">Needle</th><th>Thread colour / code</th><th style="width:36mm">Matches the logo</th></tr></thead><tbody>${Array.from({ length: 8 }, (_, i) => `<tr><td>${i + 1}</td><td></td><td><span class="tick"></span> Yes <span class="tick"></span> No</td></tr>`).join('')}</tbody></table>
<div class="grid"><div class="box"><div class="k">Machine</div></div><div class="box"><div class="k">Run by · date</div></div></div>
<div class="box"><div class="k">Swatch matches the visual?</div><span class="tick"></span> Yes <span class="tick"></span> No: what to change</div>
<div class="box"><div class="k">Customer sign-off</div><span class="tick"></span> Approved <span class="tick"></span> Changes needed &nbsp; Date: ____________</div>
<div class="box" style="min-height:24mm"><div class="k">Notes</div></div></section>`;
  }).join('');
  return `<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><title>${esc(proofTitle(rows))}</title><style>${CSS}</style></head><body>${pages}<script>window.onload=function(){setTimeout(function(){window.print()},300)}</script></body></html>`;
}

// Opens the sheets in a new window and prints. Returns false if the browser blocked the window.
export function printProofSheets(rows: EmbAreaRow[]): boolean {
  if (rows.length === 0) return false;
  const w = window.open('', '_blank'); if (!w) return false;
  w.document.open(); w.document.write(proofSheetHtml(rows)); w.document.close(); return true;
}
