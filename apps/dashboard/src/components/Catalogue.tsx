import { useMemo, useRef, useState } from 'react';
import { Button, EmptyState, Panel, Skeleton, Status } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { refreshAll, useView } from '../data/store';
import { useCtx } from '../data/context';
import { supabase } from '../lib/api';
import { parseCatalogue, TEMPLATE_CSV, type CatalogueRow } from '../lib/catalogue';
import { money } from '../lib/domain';
import type { CatalogueRow as Item } from '../data/types';

// The product catalogue: which suppliers sell which item code, at what cost, and who is preferred. Raising a PO uses it to pick the supplier for each item.
export function CataloguePanel() {
  const cat = useView<Item>('ui_catalogue'); const { senior } = useCtx(); const toast = useToast(); const file = useRef<HTMLInputElement>(null);
  const [q, setQ] = useState(''); const [rows, setRows] = useState<CatalogueRow[] | null>(null); const [problems, setProblems] = useState<string[]>([]); const [busy, setBusy] = useState(false); const [fileName, setFileName] = useState('');
  const shown = useMemo(() => { const t = q.trim().toLowerCase(); return cat.rows.filter((r) => !t || `${r.item_code} ${r.supplier} ${r.product_name ?? ''}`.toLowerCase().includes(t)).sort((a, b) => a.item_code.localeCompare(b.item_code) || a.supplier.localeCompare(b.supplier)).slice(0, 500); }, [cat.rows, q]);
  const items = useMemo(() => new Set(cat.rows.map((r) => r.item_code)).size, [cat.rows]);

  async function pick(f: File | undefined) {
    if (!f) return; setFileName(f.name);
    const p = parseCatalogue(await f.text()); setRows(p.problems.length ? null : p.rows); setProblems(p.problems);
  }
  async function doImport() {
    if (!rows) return; setBusy(true); setProblems([]);
    const { data, error } = await supabase.rpc('catalogue_import', { p_rows: rows }); setBusy(false);
    const r = (data ?? {}) as { ok?: boolean; error?: string; problems?: string[]; rows?: number };
    if (error || r.ok === false) { setProblems([...(r.problems ?? [error?.message ?? r.error ?? 'The import did not work.'])]); return; }
    toast.push({ tone: 'good', title: `${r.rows ?? rows.length} catalogue lines saved` }); setRows(null); setFileName(''); if (file.current) file.current.value = ''; void refreshAll();
  }
  async function prefer(it: Item) {
    const { data, error } = await supabase.rpc('catalogue_set_preferred', { p_supplier: it.supplier_id, p_sku: it.item_code });
    const r = (data ?? {}) as { ok?: boolean; error?: string };
    toast.push(error || r.ok === false ? { tone: 'bad', title: 'Could not change it', body: error?.message ?? r.error } : { tone: 'good', title: `${it.supplier} is now preferred for ${it.item_code}` }); void cat.refresh();
  }
  const download = () => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([TEMPLATE_CSV], { type: 'text/csv' })); a.download = 'product-catalogue-template.csv'; a.click(); URL.revokeObjectURL(a.href); };
  return (
    <div className="stack" style={{ gap: 16 }}>
      {senior && <Panel title="Load products from a spreadsheet">
        <div className="stack">
          <p className="dim">One row per supplier and item: <b>Supplier, Item code, Cost</b>, and optionally <b>Preferred</b> (put yes on the supplier you normally buy that item from). Save from Excel as CSV. The item code should be the same code DecoNetwork uses on orders. Loading it again updates costs; nothing is deleted. Any item with no preferred supplier gets its cheapest one.</p>
          <div className="row wrap"><input ref={file} type="file" accept=".csv,text/csv" aria-label="Catalogue CSV file" onChange={(e) => void pick(e.target.files?.[0])} /><Button size="sm" onClick={download}>Download a blank template</Button></div>
          {rows && <div className="callout soft"><b>{fileName}</b>: {rows.length} lines ready. <Button variant="primary" size="sm" disabled={busy} onClick={() => void doImport()}>{busy ? 'Saving…' : `Save ${rows.length} lines`}</Button></div>}
          {problems.length > 0 && <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{problems.map((p) => <div key={p}>{p}</div>)}</div>}
        </div></Panel>}
      <Panel title={`Product catalogue · ${items} items, ${cat.rows.length} supplier prices`} flush actions={<input className="input" placeholder="Search item code, product or supplier…" aria-label="Search the catalogue" value={q} onChange={(e) => setQ(e.target.value)} />}>
        {cat.loading ? <Skeleton h={160} /> : cat.rows.length === 0 ? <EmptyState icon="stock" title="No products in the catalogue yet">{senior ? 'Load a spreadsheet above to add suppliers, item codes and costs.' : 'A manager or admin can load the catalogue from a spreadsheet.'}</EmptyState> :
          <div style={{ overflow: 'auto' }}><table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}><thead><tr className="dim" style={{ textAlign: 'left' }}>{['Item code', 'Product', 'Supplier', 'Cost', 'Preferred', ''].map((h) => <th key={h} style={{ padding: '10px 12px' }}>{h}</th>)}</tr></thead>
            <tbody>{shown.map((r) => <tr key={r.id} style={{ borderTop: '1px solid var(--border)' }}><td className="mono" style={{ padding: '8px 12px' }}>{r.item_code}</td><td style={{ padding: '8px 12px' }}>{r.product_name ?? <span className="dim">—</span>}</td><td style={{ padding: '8px 12px' }}>{r.supplier}</td><td className="num" style={{ padding: '8px 12px' }}>{r.cost === null ? '—' : money(r.cost, 2)}</td><td style={{ padding: '8px 12px' }}>{r.is_preferred ? <Status tone="good">Preferred</Status> : ''}</td><td style={{ padding: '8px 12px' }}>{senior && !r.is_preferred && <Button size="sm" onClick={() => void prefer(r)}>Make preferred</Button>}</td></tr>)}</tbody></table>
            {cat.rows.length > shown.length && !q && <p className="dim" style={{ padding: 12 }}>Showing the first 500. Search to find a specific item.</p>}</div>}
      </Panel>
    </div>
  );
}
