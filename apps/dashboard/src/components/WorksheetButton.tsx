import { useMemo } from 'react';
import { Button } from '../ui/primitives';
import { useToast } from '../ui/overlay';
import { useView } from '../data/store';
import type { OrderLineRow, OrderRow } from '../data/types';
import type { QueueRow } from '../lib/dispatch';
import type { ArtworkFileRow } from '../lib/proofs';
import { buildWorksheet, printWorksheet } from '../lib/worksheet';

// Prints the production worksheet for an order, laid out like the DecoNetwork production order. Read-only: it builds the sheet in the browser from what
// Flow already holds, so anyone who can see the order can print it. Nothing is sent or changed.
export function WorksheetButton({ order }: { order: OrderRow }) {
  const toast = useToast();
  const lines = useView<OrderLineRow>('ui_order_lines'), files = useView<ArtworkFileRow>('ui_artwork_files'), dispatch = useView<QueueRow>('ui_dispatch_queue');
  const sheet = useMemo(() => buildWorksheet(order, dispatch.rows.find((d) => d.order_id === order.id) ?? null, lines.rows.filter((l) => l.order_id === order.id), files.rows.filter((f) => f.order_id === order.id)), [order, lines.rows, files.rows, dispatch.rows]);
  const loading = lines.loading || files.loading || dispatch.loading;
  return <Button icon="labels" disabled={loading || sheet.garments.length === 0} title={sheet.garments.length === 0 && !loading ? 'This order has no lines in Flow yet' : 'Prints the production worksheet: delivery address, dispatch details, each garment with its sizes and each design on it. Nothing is sent.'}
    onClick={() => { if (!printWorksheet(sheet)) toast.push({ tone: 'bad', title: 'The print window was blocked', body: 'Allow pop-ups for this site and try again.' }); }}>Print worksheet</Button>;
}
