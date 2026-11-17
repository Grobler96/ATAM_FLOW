// Reads the product catalogue spreadsheet (save from Excel as "CSV"). Columns: supplier, item code, cost, and optionally preferred (yes).
export interface CatalogueRow { supplier: string; item_code: string; cost: string; preferred?: string }
export interface ParsedCatalogue { rows: CatalogueRow[]; problems: string[] }

export function parseCsv(text: string): string[][] {
  const out: string[][] = []; let row: string[] = []; let cell = ''; let q = false;
  const t = text.replace(/^﻿/, '');
  const delim = (t.split('\n')[0] ?? '').split(';').length > (t.split('\n')[0] ?? '').split(',').length ? ';' : (t.split('\n')[0] ?? '').split('\t').length > (t.split('\n')[0] ?? '').split(',').length ? '\t' : ',';
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; }
    else if (c === '"') q = true;
    else if (c === delim) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && t[i + 1] === '\n') i++; row.push(cell); if (row.some((x) => x.trim() !== '')) out.push(row); row = []; cell = ''; }
    else cell += c;
  }
  row.push(cell); if (row.some((x) => x.trim() !== '')) out.push(row);
  return out;
}

const norm = (h: string) => h.toLowerCase().replace(/[^a-z]/g, '');
const SUP = ['supplier', 'suppliername', 'vendor'], CODE = ['itemcode', 'item', 'code', 'sku', 'productcode', 'stylecode'], COST = ['cost', 'costprice', 'price', 'unitcost', 'buyprice'], PREF = ['preferred', 'preferredsupplier', 'default'];

export function parseCatalogue(text: string): ParsedCatalogue {
  const grid = parseCsv(text); const problems: string[] = [];
  if (grid.length < 2) return { rows: [], problems: ['The file needs a header row and at least one product.'] };
  const head = grid[0].map(norm); const find = (names: string[]) => head.findIndex((h) => names.includes(h));
  const iS = find(SUP), iC = find(CODE), iP = find(COST), iF = find(PREF);
  if (iS < 0) problems.push('There is no "Supplier" column.'); if (iC < 0) problems.push('There is no "Item code" column.'); if (iP < 0) problems.push('There is no "Cost" column.');
  if (problems.length) return { rows: [], problems };
  const rows: CatalogueRow[] = [];
  grid.slice(1).forEach((r) => {
    const cost = (r[iP] ?? '').replace(/[£,\s]/g, '');
    rows.push({ supplier: (r[iS] ?? '').trim(), item_code: (r[iC] ?? '').trim(), cost, ...(iF >= 0 && (r[iF] ?? '').trim() ? { preferred: r[iF].trim() } : {}) });
  });
  return { rows, problems };
}

export const TEMPLATE_CSV = 'Supplier,Item code,Cost,Preferred\nRalawise,JH001-NAVY-M,4.25,yes\nPortwest,JH001-NAVY-M,4.60,\n';
