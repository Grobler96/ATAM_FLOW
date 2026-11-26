// Reads a supplier's own price file (as sent to us, an Excel sheet) into catalogue lines: supplier, item code, cost and title.
// Two layouts so far, both seen in real files:
//  - Ralawise: one row per item code and size. Columns "Product" (the item code) and "Description" (the title); the price we use is the
//    carton price under "Future Prices" (the second "CTN" column) because that is the price in force from the date on the file.
//  - ORN: one row per STYLE ("Code", "Product", then one price column). Our ORN item codes look like 1150.NV.L, so the style is the part
//    before the first dot. The style price is applied to every item code Flow already knows for that style.
//  - PenCarrie: one row per item, size and colour. Each row has two codes, "prodcode" (PenCarrie's own, like 520M BLK XL) and "supprodcode" (the brand's, like
//    PR694BLAC4XL); Flow holds items under either, so a known item code matches on either. One price per row ("price_sngl", the same as the carton and pack prices).
//    Items that carry a DecoNetwork number instead of the supplier's code are matched to the file by style code, colour and size (see matchInternal), and the supplier's own code is stored with them.
// A supplier file can hold 100,000 lines and Flow holds about 2,000 items, so only item codes Flow already knows are kept.
export type Cell = string | number | boolean | Date | null | undefined;
export type Grid = Cell[][];
export interface CatalogueLine { supplier: string; item_code: string; cost: string; title?: string; supplier_sku?: string }
// An item DecoNetwork has given its own number (like 264928361_194082258), with the style code, colour and size DecoNetwork recorded for it.
export interface InternalLine { sku: string; product_code: string; colour: string | null; size: string | null; supplier: string | null }
export type PriceLayout = 'ralawise' | 'orn' | 'pencarrie';
export interface PriceFileResult { rows: CatalogueLine[]; problems: string[]; notes: string[]; fileRows: number; unpriced: string[] }

export const LAYOUTS: { id: PriceLayout; label: string; hint: string }[] = [
  { id: 'ralawise', label: 'Ralawise price file', hint: 'Excel. Uses the Product, Description and Future carton price columns.' },
  { id: 'orn', label: 'ORN price file', hint: 'Excel. Prices are per style; each style price is applied to every ORN item code we know in that style.' },
  { id: 'pencarrie', label: 'PenCarrie price file', hint: 'Excel. Matches our item codes on either the PenCarrie code or the brand code, and uses the single price.' },
];

const text = (c: Cell): string => (c === null || c === undefined ? '' : c instanceof Date ? '' : String(c)).replace(/\s+/g, ' ').trim();
const key = (c: Cell): string => text(c).toLowerCase();
const price = (c: Cell): string | null => {
  const n = typeof c === 'number' ? c : Number(text(c).replace(/[£,\s]/g, ''));
  return Number.isFinite(n) && n > 0 ? String(Math.round(n * 10000) / 10000) : null;
};
const finish = (rows: CatalogueLine[], problems: string[], notes: string[], fileRows: number, unpriced: string[]): PriceFileResult => ({ rows, problems, notes, fileRows, unpriced });


// ---- Matching a DecoNetwork-numbered item to the supplier's own code (Ralawise) ----
// Ralawise item codes are style + colour code + size code (WM118NATUXS) and the description reads "SIZE COLOUR STYLE NAME" (XS NATURAL WM118 DRAWCORD BAG).
// DecoNetwork gives us the style code, its own colour name and its own size wording. A match needs the style to start the code, the size and the colour to be equal
// after tidying, and exactly ONE row in the file to fit. Anything else is left unmatched for a person to deal with: a wrong code would order the wrong item.
const SIZE_WORDS: Record<string, string> = { SMALL: 'SML', MEDIUM: 'MED', LARGE: 'LGE', 'X LARGE': 'XL', 'XX LARGE': '2XL', '2X LARGE': '2XL', '3X LARGE': '3XL', '4X LARGE': '4XL', '5X LARGE': '5XL', XS: 'XS', XXS: 'XXS', LXL: 'LGE/XL', 'ONE SIZE': '' };
const SIZE_TOKEN = /^(XXS|XS|SML|MED|LGE|XL|\dXL|\d+(\.\d)?|\d+\/\d+|[A-Z]{3}\/[A-Z]{2,3}|\d+-\d+)$/;
const tidySize = (s: string): string => { const u = s.trim().toUpperCase(); if (u in SIZE_WORDS) return SIZE_WORDS[u]; if (/^\d+\.\d+$/.test(u)) return u.replace(/0+$/, '').replace(/\.$/, ''); return u.replace('-', '/'); };
const tidyColour = (c: string): string => {
  const parts = c.toUpperCase().replace(/FLUORESCENT ?/g, 'FLU.').replace(/LIGHT ?/g, 'L.').replace(/ /g, '/').split('/').filter(Boolean).map((p) => p.replace(/[^A-Z0-9]/g, ''));
  return (parts.length === 2 && parts[0] === parts[1] ? parts.slice(0, 1) : parts).join('/');
};
const splitDescription = (desc: string): { size: string; colour: string } => {
  const t = desc.toUpperCase().split(/\s+/).filter(Boolean); let i = 0; let size = '';
  if (t.length && SIZE_TOKEN.test(t[0])) { size = t[0]; i = 1; }
  let j = i; while (j < t.length && !/\d/.test(t[j])) j++;
  return { size, colour: t.slice(i, j).join(' ') };
};
export interface FileRow { code: string; desc: string; cost: string }
export function matchInternal(line: InternalLine, rows: readonly FileRow[]): FileRow | null {
  const style = line.product_code.trim().toUpperCase(); if (!style) return null;
  const size = tidySize(line.size ?? ''), colour = tidyColour(line.colour ?? '');
  const hits = rows.filter((r) => {
    const code = r.code.toUpperCase(); if (!code.startsWith(style) || !/[A-Z]/.test(code.charAt(style.length))) return false;
    const d = splitDescription(r.desc); return d.size === size && tidyColour(d.colour) === colour;
  });
  return hits.length === 1 ? hits[0] : null;
}

export function parseRalawise(grid: Grid, supplier: string, known: ReadonlySet<string>, lines: readonly InternalLine[] = []): PriceFileResult {
  const hi = grid.findIndex((r) => r.some((c) => key(c) === 'product') && r.some((c) => key(c) === 'description'));
  if (hi < 0) return finish([], ['This does not look like a Ralawise price file: there is no row with "Product" and "Description" columns.'], [], 0, []);
  const head = grid[hi]; const iCode = head.findIndex((c) => key(c) === 'product'), iTitle = head.findIndex((c) => key(c) === 'description');
  const ctn = head.map((c, i) => (key(c) === 'ctn' ? i : -1)).filter((i) => i >= 0);
  if (ctn.length === 0) return finish([], ['There is no carton price ("CTN") column in this file.'], [], 0, []);
  const iPrice = ctn[ctn.length - 1]; const usedFuture = ctn.length > 1;
  const byCode = new Map<string, CatalogueLine>(); let fileRows = 0; let noPrice = 0;
  const pending = lines.filter((l) => known.has(l.sku) && /ralawise/i.test(l.supplier ?? '') && l.product_code.trim()); const styles = [...new Set(pending.map((l) => l.product_code.trim().toUpperCase()))]; const candidates: FileRow[] = [];
  for (const r of grid.slice(hi + 1)) {
    const code = text(r[iCode]); if (!code) continue; fileRows++;
    if (styles.length && styles.some((st) => code.toUpperCase().startsWith(st))) { const c = price(r[iPrice]); if (c !== null) candidates.push({ code, desc: text(r[iTitle]), cost: c }); }
    if (!known.has(code)) continue;
    const cost = price(r[iPrice]); if (cost === null) { noPrice++; continue; }
    const title = text(r[iTitle]);
    byCode.set(code, { supplier, item_code: code, cost, ...(title ? { title } : {}) });
  }
  let matched = 0;
  for (const l of pending) { if (byCode.has(l.sku)) continue; const m = matchInternal(l, candidates); if (m) { byCode.set(l.sku, { supplier, item_code: l.sku, cost: m.cost, supplier_sku: m.code, ...(m.desc ? { title: m.desc } : {}) }); matched++; } }
  const rows = [...byCode.values()];
  const unpriced = [...known].filter((k) => !byCode.has(k)).sort();
  const notes = [`${fileRows.toLocaleString('en-GB')} lines in the file; ${rows.length.toLocaleString('en-GB')} are items Flow already knows.`,
    usedFuture ? 'Prices are the "Future Prices" carton price.' : 'The file has one price block; prices are its carton price.'];
  if (pending.length) notes.push(`${matched} of ${new Set(pending.map((l) => l.sku)).size} items carrying a DecoNetwork number were matched to Ralawise's own code by style, colour and size. The rest could not be matched with certainty and are left alone.`);
  if (noPrice) notes.push(`${noPrice} known items had no usable price in the file and were left out.`);
  return finish(rows, rows.length ? [] : ['None of the items in this file are items Flow knows yet, so there is nothing to load.'], notes, fileRows, unpriced);
}

export function parseOrn(grid: Grid, supplier: string, known: ReadonlySet<string>): PriceFileResult {
  const hi = grid.findIndex((r) => key(r[0]) === 'code' && key(r[1]) === 'product');
  if (hi < 0) return finish([], ['This does not look like an ORN price file: the first columns should be "Code" and "Product".'], [], 0, []);
  const head = grid[hi]; const iPrice = head.length - 1; if (iPrice < 2) return finish([], ['There is no price column after "Product".'], [], 0, []);
  const styles = new Map<string, { title: string; cost: string }>(); let fileRows = 0;
  for (const r of grid.slice(hi + 1)) { const code = text(r[0]); if (!code) continue; fileRows++; const cost = price(r[iPrice]); if (cost !== null) styles.set(code.toUpperCase(), { title: text(r[1]), cost }); }
  const rows: CatalogueLine[] = []; const unpriced: string[] = []; const styleHit = new Set<string>();
  for (const sku of [...known].sort()) {
    const dot = sku.indexOf('.'); if (dot < 1) continue; // ORN codes are style.colour.size
    const style = sku.slice(0, dot).toUpperCase(); const s = styles.get(style);
    if (!s) { unpriced.push(sku); continue; }
    styleHit.add(style); rows.push({ supplier, item_code: sku, cost: s.cost, ...(s.title ? { title: s.title } : {}) });
  }
  const notes = [`${fileRows} styles in the file; ${styleHit.size} of them match item codes Flow already knows (${rows.length} item codes).`];
  if (unpriced.length) notes.push(`${unpriced.length} dotted item codes in Flow have a style that is not in this file.`);
  return finish(rows, rows.length ? [] : ['None of the ORN item codes Flow knows (style.colour.size) match a style in this file.'], notes, fileRows, unpriced);
}

export function parsePenCarrie(grid: Grid, supplier: string, known: ReadonlySet<string>): PriceFileResult {
  const hi = grid.findIndex((r) => r.some((c) => key(c) === 'prodcode') && r.some((c) => key(c) === 'supprodcode') && r.some((c) => key(c) === 'price_sngl'));
  if (hi < 0) return finish([], ['This does not look like a PenCarrie price file: there is no row with "prodcode", "supprodcode" and "price_sngl" columns.'], [], 0, []);
  const head = grid[hi]; const col = (n: string) => head.findIndex((c) => key(c) === n);
  const iOwn = col('prodcode'), iBrand = col('supprodcode'), iPrice = col('price_sngl'), iDesc = col('styledescprint'), iColour = col('longcolour'), iSize = col('size');
  const byCode = new Map<string, CatalogueLine>(); let fileRows = 0; let noPrice = 0;
  for (const r of grid.slice(hi + 1)) {
    const own = text(r[iOwn]), brand = text(r[iBrand]); if (!own && !brand) continue; fileRows++;
    const hit = [own, brand].filter((c) => c && known.has(c)); if (hit.length === 0) continue;
    const cost = price(r[iPrice]); if (cost === null) { noPrice++; continue; }
    const title = [iDesc >= 0 ? text(r[iDesc]) : '', iColour >= 0 ? text(r[iColour]) : '', iSize >= 0 ? text(r[iSize]) : ''].filter(Boolean).join(' ');
    for (const code of hit) byCode.set(code, { supplier, item_code: code, cost, ...(title ? { title } : {}) });
  }
  const rows = [...byCode.values()];
  const unpriced = [...known].filter((k) => !byCode.has(k)).sort();
  const notes = [`${fileRows.toLocaleString('en-GB')} lines in the file; ${rows.length.toLocaleString('en-GB')} are items Flow already knows (matched on the PenCarrie code or the brand code).`, 'Prices are the single price (the same as the carton and pack price in this file).'];
  if (noPrice) notes.push(`${noPrice} known items had no usable price in the file and were left out.`);
  return finish(rows, rows.length ? [] : ['None of the items in this file are items Flow knows yet, so there is nothing to load.'], notes, fileRows, unpriced);
}

export function parsePriceFile(layout: PriceLayout, grid: Grid, supplier: string, known: ReadonlySet<string>, lines: readonly InternalLine[] = []): PriceFileResult {
  const r = layout === 'ralawise' ? parseRalawise(grid, supplier, known, lines) : layout === 'pencarrie' ? parsePenCarrie(grid, supplier, known) : parseOrn(grid, supplier, known);
  if (r.rows.length > 20000) return finish([], ['This would load more than 20,000 lines, which is more than one import allows.'], r.notes, r.fileRows, r.unpriced);
  return r;
}

// Reads the first sheet of an .xlsx file. The reader is loaded only when a spreadsheet is picked.
export async function readSpreadsheet(file: File): Promise<Grid> {
  const { readSheet } = await import('read-excel-file/browser');
  return (await readSheet(file)) as Grid;
}
