import { useView } from '../data/store';
import { href } from '../router';
import type { SwitchRow } from '../lib/scope';

// Shown on in-house screens when in-house production is switched off, so an empty screen is explained, not mysterious.
export function useInhouseOn(): { loaded: boolean; master: boolean; off: string[] } {
  const sw = useView<SwitchRow>('ui_scope_switches'); const master = sw.rows.find((s) => s.key === 'inhouse.master');
  return { loaded: sw.rows.length > 0, master: master ? master.enabled : true, off: sw.rows.filter((s) => s.key !== 'inhouse.master' && !s.enabled).map((s) => s.label) };
}
export function ScopeBanner() {
  const s = useInhouseOn();
  if (!s.loaded || (s.master && s.off.length === 0)) return null;
  return (
    <div className="callout" role="status">
      {!s.master ? <><b>In-house production is switched off.</b> The planner is not scheduling any in-house work and machine problems are not raised. Third-party work is unaffected.</> : <><b>Switched off in-house:</b> {s.off.join(', ')}. The planner leaves that work to producers.</>} <a href={href('control')}>Open Control</a>
    </div>
  );
}
