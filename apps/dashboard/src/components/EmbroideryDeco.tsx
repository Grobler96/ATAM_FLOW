import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field } from '../ui/primitives';
import { refreshAll } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import { downloadFile, fileNameOf } from '../lib/artworkFiles';
import { dateTime } from '../lib/format';
import { bulkKnownPayload, bulkKnownSummary, canChangeEmbroidery, decoAffected, type EmbAreaRow, type EmbDesignRow } from '../lib/embroidery';

// The two embroidery actions that touch DecoNetwork bookkeeping. Nothing here writes to DecoNetwork: staff replace the file there by hand, then tick it off here.
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

export function DecoUpdateDialog({ design, areas, role, onClose }: { design: EmbDesignRow; areas: EmbAreaRow[]; role: string | null | undefined; onClose: () => void }) {
  const toast = useToast(); const can = canChangeEmbroidery(role); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const affected = decoAffected(areas, design.id); const waiting = design.deco_status === 'update_needed';
  async function done() {
    setBusy(true); setErr(null); const r = await exceptionActionTo('dtf', 'emb_deco_updated', { design_id: design.id, note: note.trim() }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: 'Marked as updated in DecoNetwork', body: design.name }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={`DecoNetwork file: ${design.name}`}>
      <div className="stack">
        <p>{design.customer_name ?? 'Customer'} · round {design.round}{design.approved_at ? ` · approved ${dateTime(design.approved_at)}` : ''}</p>
        {waiting ? <ol className="stack" style={{ gap: 4, paddingLeft: 18, margin: 0 }}>
          <li>Download the approved file.</li><li>In DecoNetwork, replace the old file for this logo{affected.length ? ' on the orders below' : ''}.</li><li>Tick it off here, so nobody uses the old one by mistake.</li></ol>
          : <p className="dim">{design.deco_updated_at ? `Updated in DecoNetwork ${dateTime(design.deco_updated_at)}${design.deco_note ? ': ' + design.deco_note : ''}.` : 'Nothing to update.'}</p>}
        {design.approved_file_path && <div className="row wrap" style={{ gap: 10 }}>{design.approved_thumbnail_url && <img src={design.approved_thumbnail_url} alt="" style={{ maxWidth: 80, maxHeight: 80, background: '#eee', borderRadius: 4 }} />}
          <Button onClick={async () => { setErr(null); if (!(await downloadFile(design.approved_file_path as string, fileNameOf(design.approved_file_path as string)))) setErr('Could not get the approved file. Try again.'); }}>Download the approved file{design.approved_file_format ? ` (${design.approved_file_format.toUpperCase()})` : ''}</Button></div>}
        {waiting && <div className="stack" style={{ gap: 4 }}><span className="fact-l">Orders still carrying the old file</span>
          {affected.length === 0 ? <span className="dim">None right now. New orders for this logo will be warned until you tick it off.</span> : affected.map((a) => <span key={a.artwork_id}><b className="mono">{a.order_ref}</b> · {a.customer_name ?? ''} · {a.area}</span>)}</div>}
        {waiting && <Field label="A note (optional)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Note" /></Field>}
        {err && <Err m={err} />}
        <div className="row">{waiting && <Button variant="primary" disabled={busy || !can} title={can ? '' : 'Your role cannot do this'} onClick={() => void done()}>{busy ? 'Saving…' : 'Mark as updated in DecoNetwork'}</Button>}<Button variant="ghost" onClick={onClose}>Close</Button></div>
      </div>
    </Modal>
  );
}

export function BulkKnownDialog({ rows, onClose }: { rows: EmbAreaRow[]; onClose: () => void }) {
  const toast = useToast(); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const customers = new Set(rows.map((r) => r.customer_id)).size;
  async function go() {
    setBusy(true); setErr(null); const r = await exceptionActionTo('dtf', 'emb_bulk_known', { areas: bulkKnownPayload(rows) }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: 'Marked as done before', body: bulkKnownSummary(r) }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title="We have done these logos before">
      <div className="stack">
        <p>{rows.length} area{rows.length === 1 ? '' : 's'} across {customers} customer{customers === 1 ? '' : 's'} will be marked as <b>done before</b>, so no swatch is needed. The same logo for the same customer becomes one design. A logo whose swatch is already under way is left alone.</p>
        <p className="dim">Only do this for logos you are sure were embroidered and approved before. It can be undone one design at a time (reopen it from its dialog).</p>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy || rows.length === 0} onClick={() => void go()}>{busy ? 'Saving…' : `Mark ${rows.length} as done before`}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
