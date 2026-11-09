import { useCallback, useEffect, useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { ScanPanel, useWedgeScanner } from '../scan/ScanPanel';
import { KIND_LABEL, parseScan } from '../scan/parse';
import { navigate, useRoute } from '../router';
import { useView } from '../data/store';
import type { BinRow, StockRow } from '../data/types';

export const openScan = () => window.dispatchEvent(new CustomEvent('atamflow:scan'));

// Scanning anywhere in the staff app: the Scan button, a hardware scanner (just scan, no need to click anything), or a phone camera
// pointed at a printed QR code (which opens .../#/tp/CODE and is sent to the right screen). A scan only ever OPENS something; it changes nothing.
export function ScanHost() {
  const [open, setOpen] = useState(false); const toast = useToast(); const route = useRoute();
  const bins = useView<BinRow>('ui_bins'), stock = useView<StockRow>('ui_stock');
  const known = useMemo(() => ({ bins: new Set(bins.rows.map((b) => b.bin_code)), skus: new Set(stock.rows.map((s) => s.sku)) }), [bins.rows, stock.rows]);
  const go = useCallback((text: string) => {
    const r = parseScan(text, known);
    if (r.kind === 'unknown') { toast.push({ tone: 'bad', title: 'That code was not recognised', body: `Scanned: ${text.slice(0, 60)}` }); return false; }
    const where = r.kind === 'parcel' ? 'dispatch/' + r.ref.split('-')[1] : r.kind === 'consignment' ? 'producers/movement/' + r.ref : r.kind === 'order' ? 'orders/' + r.ref.replace('#', '') : r.kind === 'bin' ? 'warehouse/' + encodeURIComponent(r.ref) : 'stock/' + encodeURIComponent(r.ref);
    navigate(where); toast.push({ tone: 'good', title: `Opened ${KIND_LABEL[r.kind]} ${r.ref}` }); return true;
  }, [known, toast]);
  useEffect(() => { const h = () => setOpen(true); window.addEventListener('atamflow:scan', h); return () => window.removeEventListener('atamflow:scan', h); }, []);
  useWedgeScanner((t) => { go(t); }, !open);
  // a printed consignment QR opens #/tp/CODE
  useEffect(() => { if (route.path[0] === 'tp' && route.path[1]) { const r = parseScan('tp:' + route.path[1]); if (r.kind === 'consignment') navigate('producers/movement/' + r.ref); else navigate('producers'); } }, [route.path]);
  return (
    <Modal open={open} onClose={() => setOpen(false)} title="Scan a label">
      <ScanPanel hint="Scan a consignment, order, bin or stock label. It opens that record." onClose={() => setOpen(false)} onScan={(t) => { if (go(t)) setOpen(false); }} />
    </Modal>
  );
}
