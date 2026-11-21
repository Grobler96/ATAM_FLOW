import { Status } from '../ui/primitives';
import { KIND_LABEL, LIGHT_MARK, LIGHT_TONE, lightWords, type Light, type LightKind, type PreprodRow } from '../lib/preproduction';

// The traffic lights. A mark as well as a colour (tick, exclamation, cross, dash) with the plain words in the tooltip and for screen readers.
const words = (kind: LightKind, light: Light) => (light === 'none' ? `${KIND_LABEL[kind]}: not needed` : `${KIND_LABEL[kind]}: ${lightWords(kind, light)}`);

export function LightDot({ kind, light }: { kind: LightKind; light: Light }) {
  return <span title={words(kind, light)} role="img" aria-label={words(kind, light)}><Status tone={LIGHT_TONE[light]} plain>{LIGHT_MARK[light]}</Status></span>;
}
// Prints, embroidery and stock side by side, for a table cell.
export function LightsCell({ row }: { row: PreprodRow }) {
  return <span className="row" style={{ gap: 2, flexWrap: 'nowrap' }}><LightDot kind="prints" light={row.prints} /><LightDot kind="embroidery" light={row.embroidery} /><LightDot kind="stock" light={row.stock} /></span>;
}
// One light with its words, for a drawer or a page.
export function LightPill({ kind, light }: { kind: LightKind; light: Light }) {
  return <Status tone={LIGHT_TONE[light]}>{LIGHT_MARK[light]} {light === 'none' ? `${KIND_LABEL[kind]}: not needed` : lightWords(kind, light)}</Status>;
}
