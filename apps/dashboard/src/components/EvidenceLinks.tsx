import { useToast } from '../ui/overlay';
import { evidenceLabel, isWebLink, signedQcUrl, type QcEvidence } from '../lib/qcPhotos';

// The photos on a quality check: a pasted link opens as it is; an uploaded file opens through a short-lived signed link (the bucket is private).
export function EvidenceLinks({ items, max = 3 }: { items: QcEvidence[] | null | undefined; max?: number }) {
  const toast = useToast(); const list = items ?? [];
  if (list.length === 0) return <span className="dim">—</span>;
  const open = async (e: QcEvidence) => {
    const url = await signedQcUrl(e);
    if (!url) { toast.push({ tone: 'bad', title: 'Could not open that photo', body: 'It may have been removed, or your login cannot see it.' }); return; }
    window.open(url, '_blank', 'noopener,noreferrer');
  };
  return (
    <span className="row" style={{ gap: 6, flexWrap: 'nowrap' }} onClick={(e) => e.stopPropagation()}>
      {list.slice(0, max).map((e, i) => e.path
        ? <button key={i} type="button" className="btn ghost sm" onClick={() => void open(e)} title={e.name}>{evidenceLabel(e, i)}</button>
        : isWebLink(e) ? <a key={i} href={e.url} target="_blank" rel="noopener noreferrer">{evidenceLabel(e, i)}</a> : null)}
      {list.length > max && <span className="dim">+{list.length - max}</span>}
    </span>
  );
}
