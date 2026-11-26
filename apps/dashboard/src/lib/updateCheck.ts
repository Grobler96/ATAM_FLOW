// Keeps open sessions on the newest published build without anyone having to hard refresh.
// A page knows its own build id; the site publishes the newest one in version.json. When they differ the page refreshes itself, but only at a safe moment:
//   - when the person moves to another page in Flow, or comes back to the tab after being away, and
//   - never while they have a box open or are typing (a PO or a note half written must not be lost): then a bar tells them and waits.
// A page refreshes itself at most once for the same newer build, so a slow-to-update cache can never put it in a refresh loop.
export type Trigger = 'poll' | 'navigate' | 'return';
export type Action = 'none' | 'reload' | 'banner';

export function decideUpdate(o: { current: string; latest: string | null; busy: boolean; trigger: Trigger; reloadedFor: string | null }): Action {
  if (!o.current || !o.latest || o.latest === o.current) return 'none';
  if (o.busy || o.reloadedFor === o.latest) return 'banner';
  return o.trigger === 'poll' ? 'banner' : 'reload';
}

// Pure so it can be tested: is the person in the middle of something?
export function isBusy(s: { dialogOpen: boolean; activeTag: string | null; activeEditable: boolean; activeType: string | null }): boolean {
  if (s.dialogOpen) return true;
  const tag = (s.activeTag ?? '').toUpperCase();
  if (s.activeEditable || tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag === 'INPUT') return !['checkbox', 'radio', 'button', 'submit', 'range'].includes((s.activeType ?? 'text').toLowerCase());
  return false;
}
