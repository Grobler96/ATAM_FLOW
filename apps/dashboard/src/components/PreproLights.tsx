import { useState } from 'react';
import { Button, Status } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { refreshAll } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import { canCheckEmbroidery, isEmbroideryChecked, KIND_LABEL, LIGHT_MARK, LIGHT_TONE, lightWords, type Light, type LightKind, type PreprodRow } from '../lib/preproduction';

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

// "Embroidery checked": a person says the embroidery for this order is ready. Can be undone. Nothing is sent and the order does not change status.
export function EmbroideryCheck({ row, role }: { row: PreprodRow; role: string | null | undefined }) {
  const toast = useToast(); const [busy, setBusy] = useState(false); const checked = isEmbroideryChecked(row);
  if (row.embroidery === 'none') return null;
  const allowed = canCheckEmbroidery(row, role);
  async function go() {
    setBusy(true); const r = await exceptionActionTo('dtf', 'embroidery_check', { order_id: row.order_id, checked: !checked }); setBusy(false);
    if (r.ok === false) { toast.push({ tone: 'bad', title: 'Could not save', body: String(r.error ?? 'That did not work.') }); return; }
    toast.push({ tone: 'good', title: checked ? 'Embroidery check removed' : 'Embroidery marked as checked', body: row.order_ref }); void refreshAll();
  }
  return <Button disabled={busy || !allowed} title={allowed ? '' : 'Your role cannot do this'} onClick={() => void go()}>{busy ? 'Saving…' : checked ? 'Undo embroidery check' : 'Mark embroidery checked'}</Button>;
}
