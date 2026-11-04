import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Icon } from './Icon';
import { Button, Chip, EmptyState, SkeletonRows } from './primitives';

export interface Column<T> { id: string; header: string; width: string; render: (r: T) => ReactNode; sort?: (r: T) => string | number | null; csv?: (r: T) => unknown; align?: 'r'; hide?: 'mobile' }
export interface FilterDef<T> { id: string; label: string; options: { value: string; label: string }[]; test: (r: T, value: string) => boolean }
export interface ViewDef<T> { id: string; label: string; test: (r: T) => boolean }
export interface BulkAction<T> { id: string; label: string; icon?: string; run?: (rows: T[]) => void; disabledReason?: string }
interface Saved { id: string; name: string; tab: string; filters: Record<string, string[]>; search: string; sort: { col: string; dir: 1 | -1 } | null }

interface Props<T> {
  rows: T[]; columns: Column<T>[]; rowKey: (r: T) => string; loading?: boolean; error?: string | null; onRetry?: () => void;
  views?: ViewDef<T>[]; filters?: FilterDef<T>[]; searchText: (r: T) => string; searchPlaceholder?: string; storageKey: string;
  onRowClick?: (r: T) => void; rowTone?: (r: T) => 'critical' | 'high' | 'medium' | '' ; bulk?: BulkAction<T>[]; exportName: string;
  defaultTab?: string; defaultSort?: { col: string; dir: 1 | -1 }; empty?: ReactNode; toolbarExtra?: ReactNode; activeKey?: string | null;
  initial?: { tab?: string; filters?: Record<string, string[]>; search?: string };
}

const ROW_H = 40;
const csvCell = (v: unknown) => { const s = v == null ? '' : Array.isArray(v) ? v.join('; ') : String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
const load = (k: string): Saved[] => { try { return JSON.parse(localStorage.getItem('atamflow.views.' + k) ?? '[]'); } catch { return []; } };

export function DataTable<T>(p: Props<T>) {
  const [tab, setTab] = useState(p.initial?.tab ?? p.defaultTab ?? p.views?.[0]?.id ?? 'all');
  const [filters, setFilters] = useState<Record<string, string[]>>(p.initial?.filters ?? {});
  const [search, setSearch] = useState(p.initial?.search ?? '');
  const [sort, setSort] = useState<{ col: string; dir: 1 | -1 } | null>(p.defaultSort ?? null);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [menu, setMenu] = useState<string | null>(null); const [more, setMore] = useState(false);
  const [saved, setSaved] = useState<Saved[]>(() => load(p.storageKey));
  const [naming, setNaming] = useState(false); const [name, setName] = useState('');
  const [scroll, setScroll] = useState(0); const [vh, setVh] = useState(600); const box = useRef<HTMLDivElement>(null);
  const selectable = !!p.bulk?.length;

  useEffect(() => { if (p.initial?.tab) setTab(p.initial.tab); if (p.initial?.filters) setFilters(p.initial.filters); if (p.initial?.search !== undefined) setSearch(p.initial.search); }, [p.initial?.tab, JSON.stringify(p.initial?.filters), p.initial?.search]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { const el = box.current; if (!el) return; const ro = new ResizeObserver(() => setVh(el.clientHeight)); ro.observe(el); setVh(el.clientHeight); return () => ro.disconnect(); }, []);
  useEffect(() => { const c = (e: MouseEvent) => { if (!(e.target as HTMLElement).closest('.dt-menu, .dt-menu-btn')) setMenu(null); }; document.addEventListener('click', c); return () => document.removeEventListener('click', c); }, []);

  const view = p.views?.find((v) => v.id === tab);
  const base = useMemo(() => (view ? p.rows.filter(view.test) : p.rows), [p.rows, view]);
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase().split(/\s+/).filter(Boolean);
    let out = base.filter((r) => (p.filters ?? []).every((f) => !filters[f.id]?.length || filters[f.id].some((v) => f.test(r, v))) && (!q.length || q.every((w) => p.searchText(r).toLowerCase().includes(w))));
    if (sort) { const col = p.columns.find((c) => c.id === sort.col); if (col?.sort) { const g = col.sort; out = [...out].sort((a, b) => { const x = g(a), y = g(b); if (x == null && y == null) return 0; if (x == null) return 1; if (y == null) return -1; return (x < y ? -1 : x > y ? 1 : 0) * sort.dir; }); } }
    return out;
  }, [base, filters, search, sort, p]);

  const cols = p.columns;
  const template = (selectable ? '36px ' : '') + cols.map((c) => c.width).join(' ');
  const start = Math.max(0, Math.floor(scroll / ROW_H) - 8), end = Math.min(filtered.length, Math.ceil((scroll + vh) / ROW_H) + 8);
  const selected = filtered.filter((r) => sel.has(p.rowKey(r)));
  const activeFilters = Object.values(filters).reduce((t, v) => t + v.length, 0);

  const toggleFilter = (id: string, v: string) => setFilters((f) => { const cur = f[id] ?? []; const next = cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v]; return { ...f, [id]: next }; });
  const persist = (list: Saved[]) => { setSaved(list); try { localStorage.setItem('atamflow.views.' + p.storageKey, JSON.stringify(list)); } catch { /* storage unavailable */ } };
  const exportCsv = () => {
    const out = selected.length ? selected : filtered;
    const csv = [cols.map((c) => csvCell(c.header)).join(','), ...out.map((r) => cols.map((c) => csvCell(c.csv ? c.csv(r) : '')).join(','))].join('\n');
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' })); a.download = `${p.exportName}-${new Date().toISOString().slice(0, 10)}.csv`; a.click(); URL.revokeObjectURL(a.href);
  };
  const applySaved = (s: Saved) => { setTab(s.tab); setFilters(s.filters); setSearch(s.search); setSort(s.sort); };

  return (
    <div className="dt">
      {p.views && (
        <div className="row wrap" style={{ padding: '10px 16px 0', gap: 6 }}>
          {p.views.map((v) => <Chip key={v.id} on={tab === v.id} count={p.rows.filter(v.test).length} onClick={() => setTab(v.id)}>{v.label}</Chip>)}
          {saved.length > 0 && <span className="dim" style={{ margin: '0 4px' }}>|</span>}
          {saved.map((s) => <span key={s.id} className="row" style={{ gap: 0 }}><Chip onClick={() => applySaved(s)}><Icon name="star" size={12} />{s.name}</Chip><button className="btn ghost sm icon" aria-label={`Delete saved view ${s.name}`} onClick={() => persist(saved.filter((x) => x.id !== s.id))}><Icon name="x" size={12} /></button></span>)}
        </div>
      )}
      <div className="dt-toolbar">
        <div className="row grow" style={{ minWidth: 220, maxWidth: 420, position: 'relative' }}><Icon name="search" size={15} className="dim" /><input className="input" style={{ paddingLeft: 32, marginLeft: -22 }} placeholder={p.searchPlaceholder ?? 'Search…'} aria-label="Search this list" value={search} onChange={(e) => setSearch(e.target.value)} /></div>
        {(p.filters ?? []).filter((f, i) => i < 4 || more || filters[f.id]?.length).map((f) => (
          <div key={f.id} style={{ position: 'relative' }}>
            <button className={`chip dt-menu-btn ${filters[f.id]?.length ? 'on' : ''}`} aria-haspopup="listbox" aria-expanded={menu === f.id} onClick={() => setMenu(menu === f.id ? null : f.id)}>{f.label}{filters[f.id]?.length ? <b>{filters[f.id].length}</b> : <Icon name="chevD" size={12} />}</button>
            {menu === f.id && <div className="dt-menu panel" role="listbox" aria-label={f.label} style={{ position: 'absolute', zIndex: 30, top: 32, left: 0, minWidth: 210, maxHeight: 300, overflow: 'auto', padding: 6 }}>
              {f.options.length === 0 && <div className="dim" style={{ padding: 8 }}>No options</div>}
              {f.options.map((o) => <label key={o.value} className="check" style={{ padding: '6px 8px', borderRadius: 6 }}><input type="checkbox" checked={!!filters[f.id]?.includes(o.value)} onChange={() => toggleFilter(f.id, o.value)} />{o.label}</label>)}
            </div>}
          </div>
        ))}
        {(p.filters ?? []).length > 4 && <button className="chip" onClick={() => setMore((m) => !m)} aria-expanded={more}>{more ? 'Fewer filters' : `More filters (${(p.filters ?? []).length - 4})`}</button>}
        {(activeFilters > 0 || search) && <Button variant="ghost" size="sm" onClick={() => { setFilters({}); setSearch(''); }}>Clear</Button>}
        <span className="grow" />
        {p.toolbarExtra}
        {naming ? <form className="row" onSubmit={(e) => { e.preventDefault(); if (name.trim()) { persist([...saved, { id: String(Date.now()), name: name.trim(), tab, filters, search, sort }]); setName(''); setNaming(false); } }}><input autoFocus className="input" style={{ width: 150 }} placeholder="Name this view" value={name} onChange={(e) => setName(e.target.value)} /><Button size="sm" variant="primary">Save</Button><Button size="sm" variant="ghost" type="button" onClick={() => setNaming(false)}>Cancel</Button></form>
          : <Button size="sm" icon="save" onClick={() => setNaming(true)}>Save view</Button>}
        <Button size="sm" icon="download" onClick={exportCsv} disabled={!filtered.length}>{selected.length ? `Export ${selected.length}` : 'Export CSV'}</Button>
      </div>
      {selectable && selected.length > 0 && (
        <div className="dt-bulk" role="toolbar" aria-label="Bulk actions"><b className="num">{selected.length} selected</b>
          {p.bulk!.map((a) => <Button key={a.id} size="sm" icon={a.icon} disabled={!a.run} title={a.disabledReason} onClick={() => a.run?.(selected)}>{a.label}</Button>)}
          <span className="grow" /><Button size="sm" variant="ghost" onClick={() => setSel(new Set())}>Clear selection</Button></div>
      )}
      <div className="dt-scroll" ref={box} onScroll={(e) => setScroll((e.target as HTMLElement).scrollTop)} style={{ maxHeight: 'calc(100vh - 330px)', minHeight: 260 }}>
        {p.loading ? <SkeletonRows rows={9} /> : p.error ? <div className="state err"><h3>Could not load this</h3><p>{p.error}</p>{p.onRetry && <Button icon="refresh" onClick={p.onRetry}>Try again</Button>}</div>
          : filtered.length === 0 ? (p.empty ?? <EmptyState title="Nothing matches" icon="search">Try a different view or clear the filters.</EmptyState>)
          : <>
            <div className="dt-head" style={{ gridTemplateColumns: template }} role="row">
              {selectable && <div><input type="checkbox" aria-label="Select all shown" checked={selected.length === filtered.length && filtered.length > 0} onChange={(e) => setSel(e.target.checked ? new Set(filtered.map(p.rowKey)) : new Set())} /></div>}
              {cols.map((c) => c.sort ? <button key={c.id} className={`sortable ${c.align ?? ''}`} aria-label={`Sort by ${c.header}`} onClick={() => setSort(sort?.col === c.id ? (sort.dir === 1 ? { col: c.id, dir: -1 } : null) : { col: c.id, dir: 1 })} style={{ justifyContent: c.align ? 'flex-end' : undefined }}>{c.header}{sort?.col === c.id && <Icon name={sort.dir === 1 ? 'chevD' : 'chevD'} size={12} className="info" />}</button> : <div key={c.id} className={c.align}>{c.header}</div>)}
            </div>
            <div style={{ height: start * ROW_H }} />
            {filtered.slice(start, end).map((r) => {
              const k = p.rowKey(r), tone = p.rowTone?.(r);
              return (
                <div key={k} className={`dt-row ${p.onRowClick ? 'click' : ''} ${sel.has(k) ? 'sel' : ''} ${p.activeKey === k ? 'sel' : ''} ${tone ? 'sev-' + tone : ''}`} style={{ gridTemplateColumns: template }} role="row"
                  onClick={() => p.onRowClick?.(r)} tabIndex={p.onRowClick ? 0 : undefined} onKeyDown={(e) => { if (e.key === 'Enter') p.onRowClick?.(r); }}>
                  {selectable && <div onClick={(e) => e.stopPropagation()}><input type="checkbox" aria-label="Select row" checked={sel.has(k)} onChange={() => setSel((s) => { const n = new Set(s); if (n.has(k)) n.delete(k); else n.add(k); return n; })} /></div>}
                  {cols.map((c) => <div key={c.id} className={c.align}>{c.render(r)}</div>)}
                </div>
              );
            })}
            <div style={{ height: Math.max(0, (filtered.length - end) * ROW_H) }} />
          </>}
      </div>
      <div className="dt-foot"><span className="num">Showing {filtered.length.toLocaleString('en-GB')} of {p.rows.length.toLocaleString('en-GB')}</span><span>{sort ? `Sorted by ${cols.find((c) => c.id === sort.col)?.header}` : ''}</span></div>
    </div>
  );
}
