import { useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { refreshAll, useView } from '../data/store';
import { href } from '../router';
import { exceptionActionTo } from '../lib/api';
import { approvesFromArea, canChangeEmbroidery, decoWords, staleWarning, hasStitchFile, designsFor, embLight, embMoves, embWords, EMB_MARK, EMB_TONE, eventsFor, eventWords, sizeText, suggestionText, type EmbAreaRow, type EmbDesignRow, type EmbEventRow } from '../lib/embroidery';
import { dateTime as fmtDateTime } from '../lib/format';
import { downloadFile, fileNameOf } from '../lib/artworkFiles';
import { printProofSheets } from '../lib/proofSheet';

// One embroidery area on one order. A logo we have not seen is a NEW design (swatch required); one we have done before is linked to its design. Every
// change is one audited database call through the action workflow; nothing is sent to the customer from here yet.
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
export const EmbStatus = ({ s }: { s: string }) => { const l = embLight(s); return <Status tone={EMB_TONE[l]}>{EMB_MARK[l]} {embWords(s)}</Status>; };

export function EmbroideryDialog({ row, role, onClose }: { row: EmbAreaRow; role: string | null | undefined; onClose: () => void }) {
  const toast = useToast(); const can = canChangeEmbroidery(role);
  const designs = useView<EmbDesignRow>('ui_emb_designs'), events = useView<EmbEventRow>('ui_emb_events');
  const mine = designsFor(designs.rows, row.customer_id); const [pick, setPick] = useState(''); const [name, setName] = useState(''); const [note, setNote] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const base = { order_id: row.order_id, deco_line_id: row.deco_line_id, area: row.area };
  async function go(action: string, params: Record<string, unknown>, title: string) {
    setBusy(true); setErr(null); const r = await exceptionActionTo('dtf', action, params); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return false; }
    toast.push({ tone: 'good', title, body: r.deco_status === 'update_needed' ? `${row.order_ref} · ${row.area}. This file is not in DecoNetwork yet: it is on the Files to update in DecoNetwork list.` : `${row.order_ref} · ${row.area}` }); void refreshAll(); return true;
  }
  async function newLogo(known: boolean) {
    setBusy(true); setErr(null); const r = await exceptionActionTo('dtf', 'emb_new', { ...base, name: name.trim() });
    if (r.ok === false) { setBusy(false); setErr(String(r.error ?? 'That did not work.')); return; }
    if (known) { const k = await exceptionActionTo('dtf', 'emb_status', { design_id: r.design_id, to: 'known', note: '' }); if (k.ok === false) { setBusy(false); setErr(String(k.error ?? 'The design was made, but it could not be marked as done before.')); void refreshAll(); return; } }
    setBusy(false); toast.push({ tone: 'good', title: known ? 'Marked as done before' : 'New logo: swatch required', body: `${row.order_ref} · ${row.area}` }); void refreshAll(); onClose();
  }
  const linked = !!row.design_id; const hist = eventsFor(events.rows, row.design_id); const moves = embMoves(row.design_status ?? '');
  const needNote = (to: string) => moves.find((m) => m.to === to)?.note ?? false;
  return (
    <Modal open onClose={onClose} title={`Embroidery: ${row.order_ref} · ${row.area}`}>
      <div className="stack">
        <div className="row wrap" style={{ gap: 12 }}>
          {row.thumbnail_url ? <img src={row.thumbnail_url} alt="" style={{ maxWidth: 120, maxHeight: 120, background: '#eee', borderRadius: 4 }} /> : <span className="dim">No picture</span>}
          <div className="stack" style={{ gap: 2 }}><b>{row.customer_name ?? 'Customer'}</b><span className="dim">{sizeText(row)}{row.file_format ? ` · ${row.file_format.toUpperCase()}` : ''}</span><span className="dim">{row.scope === 'third_party' ? 'Third-party order' : row.scope === 'in_house' ? 'In-house order' : 'Not decided where it is made'}</span></div>
        </div>
        <div className="row wrap" data-testid="emb-files">
          <Button onClick={() => { if (!printProofSheets([row])) setErr('The proof sheet could not open. Allow pop-ups for this site and try again.'); }}>Print proof sheet</Button>
          {hasStitchFile(row) ? <Button onClick={async () => { setErr(null); if (!(await downloadFile(row.storage_path as string, fileNameOf(row.storage_path as string)))) setErr('Could not get the stitch file. Try again, or ask for it to be re-uploaded on the Artwork screen.'); }}>Download stitch file</Button>
            : <span className="dim">No stitch file is stored in Flow yet. <a href={href('artwork/' + row.order_ref.replace('#', ''))}>Add it on the Artwork screen</a>.</span>}
        </div>
        {row.deco_stale && <div className="callout stack" role="alert" data-testid="emb-stale" style={{ gap: 6, borderColor: 'rgba(255,170,0,.6)' }}><b>Old file in DecoNetwork</b><span>{staleWarning(row)}</span>
          {row.approved_file_path && <div className="row"><Button onClick={async () => { setErr(null); if (!(await downloadFile(row.approved_file_path as string, fileNameOf(row.approved_file_path as string)))) setErr('Could not get the approved file. Try again.'); }}>Download the approved file</Button></div>}</div>}
        {!row.customer_id && <Err m="This order has no customer number, so a design cannot be kept for the customer." />}
        {!linked ? <div className="stack">
          {row.suggested_design_id && <div className="callout soft stack" style={{ gap: 6 }} data-testid="emb-suggestion"><b>Looks like a logo we already hold</b><span>{suggestionText(row)}</span>
            <div className="row"><Button variant="primary" disabled={busy || !can} onClick={async () => { if (await go('emb_link', { ...base, design_id: row.suggested_design_id }, 'Linked to the same logo')) onClose(); }}>Yes, same logo</Button></div></div>}
          {mine.length > 0 && <Field label="Or pick another of this customer's logos"><div className="row"><select className="select" value={pick} onChange={(e) => setPick(e.target.value)} aria-label="Customer's logos"><option value="">Choose…</option>{mine.map((d) => <option key={d.id} value={d.id}>{d.name} · {embWords(d.status)}</option>)}</select>
            <Button disabled={busy || !can || !pick} onClick={async () => { if (await go('emb_link', { ...base, design_id: pick }, 'Linked to that logo')) onClose(); }}>Use this logo</Button></div></Field>}
          <Field label="A new logo (optional name)"><input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="For example: Club crest, left chest" aria-label="Logo name" /></Field>
          <div className="row wrap"><Button variant="primary" disabled={busy || !can || !row.customer_id} onClick={() => void newLogo(false)}>New logo: swatch required</Button><Button disabled={busy || !can || !row.customer_id} onClick={() => void newLogo(true)}>We have done this logo before</Button></div>
          {!can && <span className="dim">Your role can look but not change this.</span>}
        </div> : <div className="stack">
          <div className="row wrap" style={{ gap: 10 }}><b>{row.design_name}</b><EmbStatus s={row.design_status ?? ''} />{(row.design_round ?? 1) > 1 && <span className="chip">Round {row.design_round}</span>}{row.deco_status && row.deco_status !== 'in_sync' && <span className="chip">{decoWords(row.deco_status)}</span>}</div>
          {row.status_at && <span className="dim">Last change {fmtDateTime(row.status_at)}</span>}
          <span className="dim">Reworked the file? <a href={href('artwork/' + row.order_ref.replace('#', ''))}>Upload it on the Artwork screen</a>, then approve here. The approved file is kept, and if DecoNetwork does not hold it yet it goes on the list of files to update.</span>
          {moves.length > 0 && <div className="stack" style={{ gap: 6 }}>
            <Field label={moves.some((m) => m.note) ? 'A note (needed for changes and for reopening)' : 'A note (optional)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Note" /></Field>
            <div className="row wrap">{moves.map((m) => <Button key={m.to} variant={m.primary ? 'primary' : undefined} disabled={busy || !can || (needNote(m.to) && !note.trim())} title={needNote(m.to) && !note.trim() ? 'Say why first' : ''}
              onClick={async () => { const ok = approvesFromArea(m.to) ? await go('emb_approve', { ...base, design_id: row.design_id, note: note.trim() }, m.label) : await go('emb_status', { design_id: row.design_id, to: m.to, note: note.trim() }, m.label); if (ok) { setNote(''); onClose(); } }}>{m.label}</Button>)}</div></div>}
          {!can && <span className="dim">Your role can look but not change this.</span>}
          <div className="row"><Button variant="ghost" disabled={busy || !can} onClick={async () => { if (await go('emb_unlink', base, 'Taken off this logo')) onClose(); }}>This is the wrong logo: unlink</Button></div>
          {hist.length > 0 && <div className="stack" style={{ gap: 2 }}><span className="fact-l">History</span>{hist.map((e) => <span key={e.id} className="dim">{fmtDateTime(e.at)} · {eventWords(e)}</span>)}</div>}
        </div>}
        {err && <Err m={err} />}
        <div className="row"><Button variant="ghost" onClick={onClose}>Close</Button></div>
      </div>
    </Modal>
  );
}
