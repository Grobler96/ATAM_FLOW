import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { Icon } from './Icon';
import { Button } from './primitives';

// Overlays can stack (a dialog over a drawer). Escape closes only the top-most one, so cancelling a small dialog does not also close the page behind it.
const layers: symbol[] = [];
function useEscape(open: boolean, onClose: () => void) {
  const cb = useRef(onClose); cb.current = onClose;
  useEffect(() => {
    if (!open) return;
    const id = Symbol('overlay'); layers.push(id);
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape' && layers[layers.length - 1] === id) cb.current(); };
    window.addEventListener('keydown', k);
    return () => { window.removeEventListener('keydown', k); const i = layers.indexOf(id); if (i >= 0) layers.splice(i, 1); };
  }, [open]);
}

export function Drawer({ open, onClose, title, subtitle, wide, children, header }: { open: boolean; onClose: () => void; title: ReactNode; subtitle?: ReactNode; wide?: boolean; children: ReactNode; header?: ReactNode }) {
  useEscape(open, onClose);
  if (!open) return null;
  return (<>
    <div className="scrim" onClick={onClose} />
    <aside className={`drawer ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true" aria-label={typeof title === 'string' ? title : 'Details'}>
      <div className="drawer-head">
        <div className="row" style={{ alignItems: 'flex-start' }}><div className="grow"><h1>{title}</h1>{subtitle && <div className="muted" style={{ marginTop: 2 }}>{subtitle}</div>}</div><Button variant="ghost" icon="x" onClick={onClose} aria-label="Close" /></div>
        {header}
      </div>
      <div className="drawer-body">{children}</div>
    </aside>
  </>);
}

export function Modal({ open, onClose, title, children }: { open: boolean; onClose: () => void; title: string; children: ReactNode }) {
  useEscape(open, onClose);
  if (!open) return null;
  return (<><div className="scrim" onClick={onClose} /><div className="modal" role="dialog" aria-modal="true" aria-label={title}><div className="row" style={{ marginBottom: 12 }}><h2 className="grow">{title}</h2><Button variant="ghost" icon="x" onClick={onClose} aria-label="Close" /></div>{children}</div></>);
}

export interface ToastItem { id: number; tone: 'good' | 'bad' | 'info'; title: string; body?: string; running?: boolean; href?: string; linkLabel?: string }
interface ToastApi { push: (t: Omit<ToastItem, 'id'>, ttl?: number) => number; update: (id: number, t: Partial<ToastItem>, ttl?: number) => void; dismiss: (id: number) => void }
const Ctx = createContext<ToastApi>({ push: () => 0, update: () => undefined, dismiss: () => undefined });
export const useToast = () => useContext(Ctx);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const seq = useRef(1); const timers = useRef(new Map<number, ReturnType<typeof setTimeout>>());
  const dismiss = useCallback((id: number) => { clearTimeout(timers.current.get(id)); timers.current.delete(id); setItems((x) => x.filter((t) => t.id !== id)); }, []);
  const arm = useCallback((id: number, ttl?: number) => { clearTimeout(timers.current.get(id)); if (ttl) timers.current.set(id, setTimeout(() => dismiss(id), ttl)); }, [dismiss]);
  const push = useCallback((t: Omit<ToastItem, 'id'>, ttl = 6000) => { const id = seq.current++; setItems((x) => [...x.slice(-3), { ...t, id }]); if (!t.running) arm(id, ttl); return id; }, [arm]);
  const update = useCallback((id: number, t: Partial<ToastItem>, ttl = 7000) => { setItems((x) => x.map((i) => (i.id === id ? { ...i, ...t } : i))); if (!t.running) arm(id, ttl); }, [arm]);
  return (
    <Ctx.Provider value={{ push, update, dismiss }}>
      {children}
      <div className="toasts" aria-live="polite">{items.map((t) => (
        <div key={t.id} className={`toast ${t.tone}`} role="status">
          <div className="title">
            {t.running ? <Icon name="refresh" className="spin" /> : t.tone === 'good' ? <svg className="icon good" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path className="check-draw" d="M5 12.5l4.5 4.5L19 7.5" /></svg> : <Icon name={t.tone === 'bad' ? 'exceptions' : 'info'} className={t.tone === 'bad' ? 'bad' : 'info'} />}
            <span className="grow">{t.title}</span><button className="btn ghost sm icon" onClick={() => dismiss(t.id)} aria-label="Dismiss"><Icon name="x" size={14} /></button>
          </div>
          {t.body && <div className="body">{t.body}</div>}
          {t.running && <div className="progress"><i style={{ width: '60%', animation: 'shimmer 1.2s linear infinite' }} /></div>}
          {t.href && <a className="body" href={t.href} onClick={() => dismiss(t.id)}>{t.linkLabel ?? 'View'} →</a>}
        </div>))}
      </div>
    </Ctx.Provider>
  );
}
