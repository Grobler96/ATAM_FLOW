import { Button } from '../ui/primitives';
import type { Focus } from '../data/focus';

// The always-visible control for the third-party focus. It says what is hidden and puts everything back with one click.
export function FocusBar({ focus, hidden }: { focus: Focus; hidden: { n: number; noun: string }[] }) {
  if (!focus.ready) return null;
  const parts = hidden.filter((h) => h.n > 0).map((h) => `${h.n.toLocaleString('en-GB')} ${h.n === 1 ? h.noun : h.noun + 's'}`);
  return (
    <div className="callout row wrap" role="status" data-testid="focus-bar" style={{ justifyContent: 'space-between', gap: 10 }}>
      {focus.on
        ? <span><b>Third-party work only.</b> {parts.length ? <>{parts.join(' and ')} hidden: they belong to in-house, unclassified or out-of-scope orders. Nothing is deleted.</> : 'Nothing is hidden right now.'}</span>
        : <span><b>Showing everything,</b> including in-house, unclassified and out-of-scope orders.</span>}
      <Button size="sm" onClick={() => focus.set(!focus.on)}>{focus.on ? `Show everything${parts.length ? ` (${parts.join(', ')} hidden)` : ''}` : 'Third-party only'}</Button>
    </div>
  );
}
