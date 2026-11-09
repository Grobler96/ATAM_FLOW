// Reads whatever a scanner gives us (a QR code, a Code 128 barcode, or a hardware scanner typing into the page) and says what it is.
// The label formats come from the warehouse and consignment labels: QR payloads `tp:CODE`, `order:#REF`, `bin:CODE`, `sku:SKU` or the same
// thing as a link ending in `#/tp/CODE`, `#/orders/REF`; the printed barcode is the label code, e.g. `ORD-636220-261109`, `PRO-TP-2026-00007-261109`.
// Pure and has no internal imports, so the decorator portal can use it too.
export type ScanKind = 'consignment' | 'order' | 'bin' | 'sku' | 'unknown';
export interface ScanResult { kind: ScanKind; ref: string; raw: string }
export interface Known { bins?: Set<string>; skus?: Set<string> }

const TP = /TP-\d{4}-\d{5,}/i;
const clean = (s: string) => s.replace(/[\u0000-\u001f\u007f]/g, '').trim();

export function parseScan(input: string, known: Known = {}): ScanResult {
  const raw = clean(input ?? '');
  const out = (kind: ScanKind, ref: string): ScanResult => ({ kind, ref, raw });
  if (!raw || raw.length > 300) return out('unknown', '');
  // links: .../#/tp/CODE, .../#/producers/movement/CODE, .../#/orders/REF, .../#/warehouse/BIN, .../#/stock/SKU
  const link = raw.match(/#\/([a-z-]+)(?:\/(?:movement\/)?([^?#\s]+))?/i);
  if (link && link[2]) {
    const seg = decodeURIComponent(link[2]); const page = link[1].toLowerCase();
    if (page === 'tp' || page === 'producers') { const m = seg.match(TP); if (m) return out('consignment', m[0].toUpperCase()); }
    if (page === 'orders') return out('order', '#' + seg.replace(/^#/, ''));
    if (page === 'warehouse') return out('bin', seg);
    if (page === 'stock') return out('sku', seg);
  }
  const pre = raw.match(/^(tp|order|bin|sku)\s*:\s*(.+)$/i);
  if (pre) {
    const v = pre[2].trim();
    switch (pre[1].toLowerCase()) {
      case 'tp': return out('consignment', (v.match(TP)?.[0] ?? v).toUpperCase());
      case 'order': return out('order', '#' + v.replace(/^#/, ''));
      case 'bin': return out('bin', v);
      default: return out('sku', v);
    }
  }
  const tp = raw.match(TP);                                   // plain consignment number, or a label code that contains one (PRO-TP-2026-00007-261109)
  if (tp) return out('consignment', tp[0].toUpperCase());
  const ord = raw.match(/^ORD-(\d{4,9})-\d{6}(?:-[0-9a-f]{4})?$/i);   // order label code
  if (ord) return out('order', '#' + ord[1]);
  if (/^#?\d{5,8}$/.test(raw)) return out('order', '#' + raw.replace(/^#/, ''));   // a bare DecoNetwork order number
  if (known.bins?.has(raw)) return out('bin', raw);
  if (known.skus?.has(raw)) return out('sku', raw);
  return out('unknown', '');
}

export const KIND_LABEL: Record<ScanKind, string> = { consignment: 'consignment', order: 'order', bin: 'bin', sku: 'stock item', unknown: 'code' };
