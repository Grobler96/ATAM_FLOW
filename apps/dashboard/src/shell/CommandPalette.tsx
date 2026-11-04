import { useEffect, useMemo, useRef, useState } from 'react';
import { Icon } from '../ui/Icon';
import { navigate, NAV } from '../router';
import { WORKFLOWS, type WorkflowDef } from '../lib/workflows';
import { rpc } from '../data/store';
import { useCtx } from '../data/context';
import type { ReactNode } from 'react';

interface Hit { kind: string; id: string; label: string; sub: string; route: string }
type Item = { key: string; group: string; icon: string; label: ReactNode; hint?: string; run: () => void; disabled?: boolean };
const KIND_ICON: Record<string, string> = { order: 'orders', stock: 'stock', po: 'purchasing', producer: 'producers', bin: 'warehouse', movement: 'truck', exception: 'exceptions', label: 'labels' };
const KIND_LABEL: Record<string, string> = { order: 'Orders', stock: 'Stock', po: 'Purchase orders', producer: 'Producers', bin: 'Bins', movement: 'Producer movements', exception: 'Exceptions', label: 'Labels' };

export function CommandPalette({ onClose, onRun, canRun, onCreatePo }: { onClose: () => void; onRun: (d: WorkflowDef) => void; canRun: (d: WorkflowDef) => boolean; onCreatePo: () => void }) {
  const [q, setQ] = useState(''); const [hits, setHits] = useState<Hit[]>([]); const [busy, setBusy] = useState(false); const [idx, setIdx] = useState(0);
  const ref = useRef<HTMLInputElement>(null); const { canAct } = useCtx();
  useEffect(() => { ref.current?.focus(); }, []);
  useEffect(() => {
    const t = q.trim(); if (t.length < 2) { setHits([]); return; }
    setBusy(true); let alive = true;
    const h = setTimeout(() => { rpc<Hit[]>('ui_search', { p_q: t }).then((r) => { if (alive) setHits(r ?? []); }).catch(() => { if (alive) setHits([]); }).finally(() => alive && setBusy(false)); }, 160);
    return () => { alive = false; clearTimeout(h); };
  }, [q]);

  const items = useMemo<Item[]>(() => {
    const t = q.trim().toLowerCase(); const go = (path: string) => () => { onClose(); navigate(path); };
    const match = (s: string) => !t || s.toLowerCase().includes(t);
    const out: Item[] = [];
    for (const h of hits) out.push({ key: h.kind + h.id, group: KIND_LABEL[h.kind] ?? h.kind, icon: KIND_ICON[h.kind] ?? 'search', label: h.label, hint: h.sub, run: go(h.route.replace(/^\//, '')) });
    for (const n of NAV) if (match(n.label)) out.push({ key: 'nav' + n.id, group: 'Go to', icon: n.icon, label: n.label, hint: `g ${n.chord}`, run: go(n.id === 'home' ? '' : n.id) });
    for (const w of WORKFLOWS) if (match(w.label) || match('run ' + w.label)) out.push({ key: 'wf' + w.id, group: 'Actions', icon: w.icon, label: w.label, hint: canRun(w) ? w.description : 'Not allowed for your role', disabled: !canRun(w), run: () => { onClose(); onRun(w); } });
    if (match('create purchase order po')) out.push({ key: 'po', group: 'Actions', icon: 'plus', label: 'Create purchase order', hint: 'From orders waiting for stock', disabled: !canAct, run: () => { onClose(); onCreatePo(); } });
    return out.slice(0, 40);
  }, [q, hits, canRun, canAct, onClose, onRun, onCreatePo]);

  useEffect(() => setIdx(0), [q]);
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setIdx((i) => Math.min(items.length - 1, i + 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setIdx((i) => Math.max(0, i - 1)); }
    else if (e.key === 'Enter') { const it = items[idx]; if (it && !it.disabled) it.run(); }
    else if (e.key === 'Escape') onClose();
  };
  let lastGroup = '';
  return (<>
    <div className="scrim" onClick={onClose} />
    <div className="palette panel" role="dialog" aria-modal="true" aria-label="Command palette" onKeyDown={onKey}>
      <input ref={ref} value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search orders, SKUs, POs, producers, bins… or type a command" aria-label="Search or run a command" />
      <div className="results" role="listbox">
        {busy && <div className="grp">Searching…</div>}
        {items.length === 0 && !busy && <div className="state"><p>{q.trim().length < 2 ? 'Type at least two characters to search.' : 'No matches.'}</p></div>}
        {items.map((it, i) => { const head = it.group !== lastGroup ? ((lastGroup = it.group), <div className="grp" key={'g' + it.group}>{it.group}</div>) : null;
          return (<div key={it.key}>{head}<button className="res" role="option" aria-selected={i === idx} disabled={it.disabled} onMouseEnter={() => setIdx(i)} onClick={() => it.run()}><Icon name={it.icon} /><span>{it.label}</span>{it.hint && <small>{it.hint}</small>}</button></div>); })}
      </div>
      <div className="row dim" style={{ padding: '8px 14px', borderTop: '1px solid var(--border)', fontSize: 11 }}><kbd>↑↓</kbd> move <kbd>↵</kbd> open <kbd>esc</kbd> close<span className="grow" /><span>Searches the live database</span></div>
    </div>
  </>);
}
