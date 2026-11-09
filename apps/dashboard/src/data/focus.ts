import { useCallback, useMemo, useSyncExternalStore } from 'react';
import { useView } from './store';
import { useInhouseOn } from '../components/ScopeBanner';
import { exceptionHidden, getPref, orderHidden, scopeMaps, subscribePref, wantFocus, writePref } from '../lib/focus';
import type { OrderScopeRow } from '../lib/scope';

export interface Focus {
  ready: boolean;                       // the order scopes have loaded; until then nothing is hidden
  on: boolean;                          // focus is active right now
  set: (on: boolean) => void;
  hideOrder: (orderId: string) => boolean;
  hideException: (orderRefs: string[]) => boolean;
}

export function useFocus(): Focus {
  const scp = useView<OrderScopeRow>('ui_order_scope'); const inh = useInhouseOn();
  const pref = useSyncExternalStore(subscribePref, getPref, () => null);
  const maps = useMemo(() => scopeMaps(scp.rows), [scp.rows]);
  const ready = scp.rows.length > 0;
  const on = ready && wantFocus(pref, inh.loaded && !inh.master);
  const set = useCallback((v: boolean) => writePref(v ? 'on' : 'off'), []);
  return useMemo<Focus>(() => ({ ready, on, set, hideOrder: (id) => on && orderHidden(id, maps), hideException: (refs) => on && exceptionHidden(refs, maps) }), [ready, on, set, maps]);
}
