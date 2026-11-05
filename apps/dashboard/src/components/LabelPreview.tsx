import { useEffect, useState } from 'react';
import { LABEL_CSS, labelHtml } from '../lib/labelPrint';
import type { PrintFormat } from '../lib/warehouse';
import type { LabelRow } from '../data/types';

// Shows exactly what will print (same HTML as the print sheet), including the QR code and barcode.
export function LabelPreview({ label, format }: { label: LabelRow; format: PrintFormat }) {
  const [html, setHtml] = useState<string | null>(null); const [err, setErr] = useState(false);
  useEffect(() => { let live = true; setHtml(null); setErr(false); labelHtml(label, format).then((h) => { if (live) setHtml(h); }).catch(() => { if (live) setErr(true); }); return () => { live = false; }; }, [label, format]);
  if (err) return <p className="dim" role="alert">The preview could not be drawn. The label data may be incomplete.</p>;
  if (!html) return <p className="dim">Drawing preview…</p>;
  return <div className="label-preview" style={{ background: '#fff', padding: 12, borderRadius: 8, overflow: 'auto', maxHeight: 640 }}><style>{LABEL_CSS}</style><div dangerouslySetInnerHTML={{ __html: html }} /></div>;
}
