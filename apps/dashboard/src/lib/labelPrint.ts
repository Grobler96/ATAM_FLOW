import QRCode from 'qrcode';
import JsBarcode from 'jsbarcode';
import type { LabelRow } from '../data/types';
import { labelHeadline, labelLines, labelTypeName, type PrintFormat } from './warehouse';

const esc = (v: unknown): string => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

export async function qrDataUrl(text: string): Promise<string> { return QRCode.toDataURL(text, { margin: 1, width: 360, errorCorrectionLevel: 'M' }); }

// Code 128 barcode as inline SVG markup. Falls back to nothing if the text cannot be encoded.
export function barcodeSvg(text: string): string {
  try {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    JsBarcode(svg, text, { format: 'CODE128', displayValue: false, height: 48, margin: 0, width: 2 });
    return svg.outerHTML;
  } catch { return ''; }
}

// One label's HTML (used by both the on-screen preview and the print sheet).
export async function labelHtml(l: LabelRow, format: PrintFormat): Promise<string> {
  const p = l.payload ?? {}; const qr = l.qr_payload ? await qrDataUrl(l.qr_payload) : '';
  const lines = labelLines(l.label_type, p).filter(([, v]) => v !== '' && v != null);
  const bar = barcodeSvg(l.label_code);
  const head = labelHeadline(p, l.label_code);
  return `<section class="lbl ${format}"><header><span class="type">${esc(labelTypeName(l.label_type))}</span><span class="v">v${l.version}${l.print_count > 0 ? ' · REPRINT' : ''}</span></header>
<div class="big">${esc(head)}</div>
<div class="body"><dl>${lines.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>${qr ? `<img class="qr" alt="QR code" src="${qr}">` : ''}</div>
<footer>${bar}<span class="code">${esc(l.label_code)}</span></footer></section>`;
}

export const LABEL_CSS = `
*{box-sizing:border-box}body{margin:0;font-family:Arial,Helvetica,sans-serif;color:#000;background:#fff}
.lbl{border:1.5px solid #000;padding:4mm;display:flex;flex-direction:column;gap:2mm;break-inside:avoid;page-break-inside:avoid;overflow:hidden;background:#fff}
.lbl.A4{width:95mm;height:128mm}.lbl.thermal{width:100mm;height:150mm;border:0;page-break-after:always}
.lbl header{display:flex;justify-content:space-between;font-size:9pt;font-weight:700;text-transform:uppercase;border-bottom:1.5px solid #000;padding-bottom:1.5mm}
.lbl .big{font-size:22pt;font-weight:800;line-height:1.05;word-break:break-word}
.lbl .body{display:flex;gap:3mm;align-items:flex-start;flex:1;min-height:0}.lbl dl{margin:0;flex:1;font-size:9.5pt}
.lbl dl div{display:flex;gap:2mm;border-bottom:.5px solid #bbb;padding:.6mm 0}.lbl dt{width:20mm;color:#444;flex:none}.lbl dd{margin:0;font-weight:600;word-break:break-word}
.lbl .qr{width:30mm;height:30mm;flex:none}.lbl footer{display:flex;flex-direction:column;align-items:center;gap:1mm}.lbl footer svg{width:100%;height:12mm}.lbl .code{font:700 9pt monospace}
`;

// Opens the browser print dialog with the chosen labels laid out for the chosen paper. Returns false if the browser blocked the window.
export async function printLabels(labels: LabelRow[], format: PrintFormat, copies = 1): Promise<boolean> {
  const parts: string[] = [];
  for (const l of labels) { const h = await labelHtml(l, format); for (let i = 0; i < Math.max(1, copies); i++) parts.push(h); }
  const page = format === 'thermal' ? '@page{size:100mm 150mm;margin:0}' : '@page{size:A4;margin:8mm}';
  const body = format === 'A4' ? `<div style="display:grid;grid-template-columns:repeat(2,95mm);gap:4mm">${parts.join('')}</div>` : parts.join('');
  const w = window.open('', '_blank', 'width=900,height=700'); if (!w) return false;
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>ATAM_FLOW labels</title><style>${page}${LABEL_CSS}</style></head><body>${body}<script>window.onload=function(){setTimeout(function(){window.focus();window.print();},250)}<\/script></body></html>`);
  w.document.close(); return true;
}
