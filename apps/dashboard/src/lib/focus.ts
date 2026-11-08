// Third-party focus: while ATAM_FLOW launches for decorator work only, the order, exception and home screens can hide everything that belongs
// to an order that is not third-party. Nothing is deleted or changed: it is a view setting, and the screen always says how much is hidden.
export interface ScopeLike { order_id: string; order_ref: string; scope: string }
export interface ScopeMaps { byId: Map<string, string>; byRef: Map<string, string> }

export function scopeMaps(rows: ScopeLike[]): ScopeMaps {
  return { byId: new Map(rows.map((r) => [r.order_id, r.scope])), byRef: new Map(rows.map((r) => [r.order_ref, r.scope])) };
}
// An order is hidden only when we positively know it is not third-party. An order we cannot classify is never hidden.
export const orderHidden = (id: string, m: ScopeMaps): boolean => { const s = m.byId.get(id); return s !== undefined && s !== 'third_party'; };
// An exception is hidden only when it is tied to orders and every one of them is known to be non-third-party.
// Exceptions about suppliers, stock, integrations and so on (no order) always stay visible.
export const exceptionHidden = (orderRefs: string[], m: ScopeMaps): boolean =>
  orderRefs.length > 0 && orderRefs.every((r) => { const s = m.byRef.get(r); return s !== undefined && s !== 'third_party'; });

const KEY = 'atamflow.focus';
export type FocusPref = 'on' | 'off' | null;
const listeners = new Set<() => void>();
export function readPref(): FocusPref { try { const v = localStorage.getItem(KEY); return v === 'on' || v === 'off' ? v : null; } catch { return null; } }
export function writePref(v: 'on' | 'off'): void { try { localStorage.setItem(KEY, v); } catch { /* storage unavailable: the choice lasts until reload */ memory = v; } listeners.forEach((l) => l()); }
let memory: FocusPref = null;
export const getPref = (): FocusPref => readPref() ?? memory;
export function subscribePref(l: () => void): () => void { listeners.add(l); return () => { listeners.delete(l); }; }

// Saved choice wins. With no choice, focus is on exactly when in-house production is switched off.
export const wantFocus = (pref: FocusPref, inhouseMasterOff: boolean): boolean => (pref === 'on' ? true : pref === 'off' ? false : inhouseMasterOff);
