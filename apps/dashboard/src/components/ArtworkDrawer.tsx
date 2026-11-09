import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react';
import { Button, EmptyState, Field, Status } from '../ui/primitives';
import { Drawer, Modal, useToast } from '../ui/overlay';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { dateTime } from '../lib/format';
import { ALLOWED_EXT, artworkPath, checkFile, downloadFile, extOf, fileNameOf, isImage, isPdf, PROOF_EXT, proofPath, removeFile, signedUrl, uploadFile } from '../lib/artworkFiles';
import { APPROVAL_LABEL, APPROVAL_TONE, artworkReplace, artworkSetApproval, PROOF_LABEL, PROOF_TONE, proofCreate, proofRespond, proofSend, proofWithdraw, VIA_LABEL, type ArtworkFileRow, type ProofRow } from '../lib/proofs';
import { href } from '../router';
import type { ActionResult } from '../types';

const PROCESSES: [string, string][] = [['embroidery', 'Embroidery'], ['dtf', 'DTF'], ['dtg', 'DTG'], ['uv', 'UV'], ['screen', 'Screen print'], ['transfer', 'Heat transfer'], ['other', 'Other']];
type Dlg = null | { kind: 'upload'; file?: ArtworkFileRow } | { kind: 'approval'; file: ArtworkFileRow } | { kind: 'view'; path: string; name: string; title: string } | { kind: 'proof' }
  | { kind: 'send'; proof: ProofRow } | { kind: 'answer'; proof: ProofRow } | { kind: 'withdraw'; proof: ProofRow };

function Dialog({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) { return <Modal open onClose={onClose} title={title}><div className="stack" style={{ gap: 12 }}>{children}</div></Modal>; }
const Err = ({ m }: { m: string | null }) => (m ? <div className="callout" role="alert">{m}</div> : null);

export function ArtworkDrawer({ orderRef, onClose }: { orderRef: string; onClose: () => void }) {
  const ref = '#' + orderRef; const { role, senior } = useCtx(); const toast = useToast();
  const files = useView<ArtworkFileRow>('ui_artwork_files'), proofs = useView<ProofRow>('ui_artwork_proofs'); const orders = useView<{ id: string; order_ref: string; customer_name: string | null; due_date: string | null }>('ui_orders');
  const [dlg, setDlg] = useState<Dlg>(null); const [open, setOpen] = useState<Record<string, boolean>>({}); const [dlErr, setDlErr] = useState<string | null>(null);
  const canWrite = role === 'admin' || role === 'manager' || role === 'production';
  const all = useMemo(() => files.rows.filter((f) => f.order_ref === ref), [files.rows, ref]);
  const current = useMemo(() => all.filter((f) => f.is_current).sort((a, b) => a.area.localeCompare(b.area)), [all]);
  const order = orders.rows.find((o) => o.order_ref === ref); const orderId = order?.id ?? all[0]?.order_id ?? '';
  const myProofs = useMemo(() => proofs.rows.filter((p) => p.order_ref === ref).sort((a, b) => b.created_at.localeCompare(a.created_at)), [proofs.rows, ref]);
  const refresh = async () => { await Promise.all([files.refresh(), proofs.refresh()]); };
  const done = async (msg: string) => { toast.push({ tone: 'good', title: msg }); setDlg(null); await refresh(); };
  const hist = (f: ArtworkFileRow) => all.filter((x) => x.area === f.area && (x.deco_line_id ?? '') === (f.deco_line_id ?? '') && !x.is_current).sort((a, b) => b.version - a.version);
  async function dl(path: string, name: string) { setDlErr(null); if (!(await downloadFile(path, name))) setDlErr(`Could not get ${name}. Try again, or ask for the file to be re-uploaded.`); }

  return (
    <Drawer open onClose={onClose} wide title={<span className="row wrap" style={{ gap: 10 }}><b className="mono">{ref}</b><span>Artwork and proofs</span></span>} subtitle={order?.customer_name ?? all[0]?.customer_name ?? undefined}>
      <div className="stack" style={{ gap: 18 }}>
        <p className="muted"><a href={href('orders/' + orderRef)}>Open the order</a>{order?.due_date ? ` · due ${dateTime(order.due_date).split(',')[0]}` : ''}</p>
        {!canWrite && <p className="muted">You can look at artwork and download it. Uploading and proofs are for managers, admins and production planners.</p>}
        <Err m={dlErr} />

        <section className="stack" style={{ gap: 10 }} aria-label="Artwork areas">
          <div className="row" style={{ justifyContent: 'space-between' }}><h3>Artwork by area</h3>{canWrite && orderId && <Button icon="plus" onClick={() => setDlg({ kind: 'upload' })}>Add an area</Button>}</div>
          {files.loading && all.length === 0 ? <p className="dim">Loading…</p> : current.length === 0
            ? <EmptyState icon="artwork" title="No artwork on this order yet">{canWrite ? 'Add the first area: choose the file, say what it is, and it is stored securely.' : 'Nothing has been uploaded yet.'}</EmptyState>
            : current.map((f) => (
              <div key={f.id} className="panel stack" style={{ padding: 14, gap: 8 }}>
                <div className="row wrap" style={{ gap: 10 }}><b>{f.area}</b><span className="dim">{[f.process, f.file_format?.toUpperCase(), `version ${f.version}`].filter(Boolean).join(' · ')}</span><span className="grow" />
                  <Status tone={APPROVAL_TONE[f.approval_status]}>{APPROVAL_LABEL[f.approval_status]}</Status><Status tone={f.storage_path ? 'good' : 'high'} plain>{f.storage_path ? 'File stored' : f.storage_status === 'pending_download' ? 'File not downloaded yet' : 'No file'}</Status></div>
                <div className="dim">{[f.stitch_count ? `${f.stitch_count.toLocaleString('en-GB')} stitches` : null, f.width_mm && f.height_mm ? `${f.width_mm} × ${f.height_mm} mm` : null, f.placement, `${f.created_by ?? 'sync'} · ${dateTime(f.created_at)}`].filter(Boolean).join(' · ')}</div>
                {f.note && <div className="muted" style={{ whiteSpace: 'pre-line', fontSize: 12 }}>{f.note.split('\n').slice(-2).join('\n')}</div>}
                {f.has_deconetwork_proof && f.proof_url && <div className="dim">DecoNetwork has its own proof for this area: <a href={f.proof_url} target="_blank" rel="noreferrer">open it</a></div>}
                <div className="row wrap" style={{ gap: 8 }}>
                  {f.storage_path && <><Button size="sm" onClick={() => setDlg({ kind: 'view', path: f.storage_path!, name: fileNameOf(f.storage_path), title: `${f.area} · version ${f.version}` })}>Preview</Button><Button size="sm" onClick={() => void dl(f.storage_path!, fileNameOf(f.storage_path))}>Download</Button></>}
                  {canWrite && <Button size="sm" variant="primary" onClick={() => setDlg({ kind: 'upload', file: f })}>Upload a new version</Button>}
                  {canWrite && <Button size="sm" onClick={() => setDlg({ kind: 'approval', file: f })}>Change approval…</Button>}
                  {hist(f).length > 0 && <Button size="sm" variant="ghost" onClick={() => setOpen((o) => ({ ...o, [f.id]: !o[f.id] }))}>{open[f.id] ? 'Hide' : 'Show'} {hist(f).length} earlier version{hist(f).length === 1 ? '' : 's'}</Button>}
                </div>
                {open[f.id] && <ul className="plain" style={{ display: 'grid', gap: 6 }}>{hist(f).map((h) => <li key={h.id} className="row wrap" style={{ gap: 8 }}><b>v{h.version}</b><span className="dim">{h.created_by ?? 'sync'} · {dateTime(h.created_at)}{h.note ? ` · ${h.note.split('\n')[0]}` : ''}</span>{h.storage_path && <Button size="sm" variant="ghost" onClick={() => void dl(h.storage_path!, fileNameOf(h.storage_path))}>Download</Button>}</li>)}</ul>}
              </div>))}
        </section>

        <section className="stack" style={{ gap: 10 }} aria-label="Proofs">
          <div className="row" style={{ justifyContent: 'space-between' }}><h3>Customer proofs</h3>{canWrite && current.length > 0 && <Button icon="plus" onClick={() => setDlg({ kind: 'proof' })}>New proof</Button>}</div>
          <p className="dim">A proof is a picture or PDF the customer approves. Record it here, record that it was sent, then record their answer. Nothing is sent from this screen.</p>
          {myProofs.length === 0 ? <p className="dim">No proofs for this order yet.</p> : myProofs.map((p) => (
            <div key={p.id} className="panel stack" style={{ padding: 14, gap: 6 }}>
              <div className="row wrap" style={{ gap: 10 }}><b className="mono">{p.proof_ref}</b><Status tone={PROOF_TONE[p.status]}>{PROOF_LABEL[p.status]}</Status>{p.status === 'approved' && p.is_out_of_date && <Status tone="high">Artwork changed since approval</Status>}<span className="grow" /><span className="dim">{p.areas.join(', ')}</span></div>
              <div className="dim">Made by {p.created_by} · {dateTime(p.created_at)}{p.note ? ` · ${p.note}` : ''}</div>
              {p.sent_at && <div className="dim">Sent to {p.sent_to} by {VIA_LABEL[p.sent_via ?? 'other']} · {dateTime(p.sent_at)}{p.status === 'sent' && p.days_waiting != null ? ` · waiting ${p.days_waiting} day${p.days_waiting === 1 ? '' : 's'}` : ''}</div>}
              {p.answered_at && <div><b>{p.answered_by}</b> {p.status === 'approved' ? 'approved it' : p.status === 'rejected' ? 'rejected it' : 'asked for changes'} · <span className="dim">{dateTime(p.answered_at)} · recorded by {p.recorded_by}</span>{p.answer_note && <div className="muted">“{p.answer_note}”</div>}</div>}
              {p.closed_reason && <div className="dim">{p.status === 'withdrawn' ? 'Withdrawn' : 'Closed'}: {p.closed_reason}</div>}
              <div className="row wrap" style={{ gap: 8 }}>
                <Button size="sm" onClick={() => setDlg({ kind: 'view', path: p.storage_path, name: p.file_name, title: p.proof_ref })}>View proof</Button>
                {p.answer_evidence_path && <Button size="sm" onClick={() => setDlg({ kind: 'view', path: p.answer_evidence_path!, name: fileNameOf(p.answer_evidence_path), title: `Evidence for ${p.proof_ref}` })}>View evidence</Button>}
                {canWrite && p.status === 'draft' && <Button size="sm" variant="primary" onClick={() => setDlg({ kind: 'send', proof: p })}>Mark as sent</Button>}
                {canWrite && p.status === 'sent' && <Button size="sm" variant="primary" onClick={() => setDlg({ kind: 'answer', proof: p })}>Record the answer</Button>}
                {canWrite && (p.status === 'draft' || p.status === 'sent') && <Button size="sm" variant="ghost" onClick={() => setDlg({ kind: 'withdraw', proof: p })}>Withdraw</Button>}
              </div>
            </div>))}
        </section>
      </div>

      {dlg?.kind === 'upload' && <UploadDialog orderRef={ref} orderId={orderId} existing={dlg.file} nextVersion={(dlg.file ? Math.max(...all.filter((x) => x.area === dlg.file!.area).map((x) => x.version)) : 0) + 1} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'approval' && <ApprovalDialog file={dlg.file} senior={senior} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'view' && <ViewDialog title={dlg.title} path={dlg.path} name={dlg.name} onClose={() => setDlg(null)} />}
      {dlg?.kind === 'proof' && <ProofDialog orderRef={ref} orderId={orderId} areas={current} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'send' && <SendDialog proof={dlg.proof} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'answer' && <AnswerDialog orderRef={ref} proof={dlg.proof} onClose={() => setDlg(null)} onDone={done} />}
      {dlg?.kind === 'withdraw' && <WithdrawDialog proof={dlg.proof} onClose={() => setDlg(null)} onDone={done} />}
    </Drawer>
  );
}

// ---------------------------------------------------------------------------
function useAction(onDone: (m: string) => Promise<void>) {
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function run(fn: () => Promise<ActionResult | string | null>, ok: string): Promise<boolean> {
    setBusy(true); setErr(null); const r = await fn(); setBusy(false);
    if (typeof r === 'string') { setErr(r); return false; }
    if (r && r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return false; }
    await onDone(ok); return true;
  }
  return { busy, err, setErr, run };
}

function UploadDialog({ orderRef, orderId, existing, nextVersion, onClose, onDone }: { orderRef: string; orderId: string; existing?: ArtworkFileRow; nextVersion: number; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [area, setArea] = useState(existing?.area ?? ''); const [process, setProcess] = useState(existing?.process ?? ''); const [file, setFile] = useState<File | null>(null); const [stitches, setStitches] = useState(''); const [w, setW] = useState(''); const [h, setH] = useState('');
  const [placement, setPlacement] = useState(existing?.placement ?? ''); const [note, setNote] = useState(''); const [approved, setApproved] = useState(false); const { busy, err, setErr, run } = useAction(onDone);
  const ok = area.trim().length > 0 && !!file && note.trim().length >= 5;
  async function submit(e: FormEvent) {
    e.preventDefault(); if (!file || !ok) return; const bad = checkFile(file, ALLOWED_EXT); if (bad) { setErr(bad); return; }
    await run(async () => {
      const path = artworkPath(orderRef, area.trim(), nextVersion, file.name); const up = await uploadFile(path, file); if (up) return `The file did not upload: ${up}`;
      const r = await artworkReplace({ order_id: orderId, deco_line_id: existing?.deco_line_id ?? null, area: area.trim(), storage_path: path, note: note.trim(),
        meta: { process: process || undefined, file_format: extOf(file.name) || undefined, stitch_count: stitches ? Number(stitches) : undefined, width_mm: w ? Number(w) : undefined, height_mm: h ? Number(h) : undefined, placement: placement.trim() || undefined, approval_status: approved ? 'approved' : 'pending' } });
      if (r.ok === false) await removeFile(path);
      return r;
    }, existing ? `Version ${nextVersion} of ${area.trim()} saved.` : `${area.trim()} added.`);
  }
  return (
    <Dialog title={existing ? `New version of ${existing.area}` : 'Add an artwork area'} onClose={onClose}>
      <form className="stack" style={{ gap: 10 }} onSubmit={submit}>
        {existing && <p className="muted">This becomes version {nextVersion}. The old version is kept in the history. Any proof for the old version stops matching.</p>}
        <Field label="Area (for example Left chest, Back, Sleeve)"><input className="input" value={area} disabled={!!existing} onChange={(e) => setArea(e.target.value)} aria-label="Area" /></Field>
        <div className="row wrap" style={{ gap: 12 }}>
          <Field label="Process"><select className="select" value={process} onChange={(e) => setProcess(e.target.value)} aria-label="Process"><option value="">Choose…</option>{PROCESSES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
          <Field label="Placement (optional)"><input className="input" value={placement} onChange={(e) => setPlacement(e.target.value)} aria-label="Placement" /></Field>
        </div>
        <Field label={`The file (${ALLOWED_EXT.join(', ')})`}><input type="file" accept={ALLOWED_EXT.map((x) => '.' + x).join(',')} onChange={(e) => { setFile(e.target.files?.[0] ?? null); setErr(null); }} aria-label="Artwork file" /></Field>
        <div className="row wrap" style={{ gap: 12 }}>
          {(process === 'embroidery' || extOf(file?.name ?? '') === 'dst') && <Field label="Stitch count"><input className="input" style={{ width: 120 }} inputMode="numeric" value={stitches} onChange={(e) => setStitches(e.target.value)} aria-label="Stitch count" /></Field>}
          <Field label="Width (mm)"><input className="input" style={{ width: 90 }} inputMode="decimal" value={w} onChange={(e) => setW(e.target.value)} aria-label="Width" /></Field>
          <Field label="Height (mm)"><input className="input" style={{ width: 90 }} inputMode="decimal" value={h} onChange={(e) => setH(e.target.value)} aria-label="Height" /></Field>
        </div>
        <Field label={existing ? 'Why a new version? (required)' : 'Where did this file come from? (required)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Note" /></Field>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={approved} onChange={(e) => setApproved(e.target.checked)} aria-label="Customer already approved" /><span>The customer has already approved this exact version</span></label>
        {!approved && <p className="dim">Otherwise it waits for the customer: send them a proof and record their answer.</p>}
        <Err m={err} />
        <div className="row"><Button variant="primary" disabled={busy || !ok}>{busy ? 'Uploading…' : 'Upload and save'}</Button><Button type="button" variant="ghost" onClick={onClose}>Cancel</Button></div>
      </form>
    </Dialog>
  );
}

function ApprovalDialog({ file, senior, onClose, onDone }: { file: ArtworkFileRow; senior: boolean; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [status, setStatus] = useState(file.approval_status === 'approved' ? 'pending' : 'approved'); const [note, setNote] = useState(''); const { busy, err, run } = useAction(onDone);
  return (
    <Dialog title={`Approval for ${file.area}`} onClose={onClose}>
      <p className="muted">Normally the customer's answer to a proof sets this. Use this only to put right a mistake or to record an approval that happened some other way. It is audited with your reason.</p>
      <Field label="Set it to"><select className="select" value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Approval status"><option value="approved">Approved</option><option value="pending">Waiting for the customer</option><option value="rejected">Rejected</option></select></Field>
      <Field label="Why? (required)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Reason" /></Field>
      {!senior && status === 'approved' && <p className="warn">Approving without a proof is usually for a manager to do.</p>}
      <Err m={err} />
      <div className="row"><Button variant="primary" disabled={busy || note.trim().length < 5} onClick={() => void run(() => artworkSetApproval(file.id, status, note.trim()), 'Approval updated.')}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
    </Dialog>
  );
}

function ViewDialog({ title, path, name, onClose }: { title: string; path: string; name: string; onClose: () => void }) {
  const [url, setUrl] = useState<string | null>(null); const [failed, setFailed] = useState(false);
  useEffect(() => { let alive = true; void signedUrl(path).then((u) => { if (!alive) return; if (u) setUrl(u); else setFailed(true); }); return () => { alive = false; }; }, [path]);
  return (
    <Dialog title={title} onClose={onClose}>
      <p className="dim mono">{name}</p>
      {failed && <Err m="Could not open the file. It may not be stored yet." />}
      {!url && !failed && <p className="dim">Opening…</p>}
      {url && isImage(name) && <img src={url} alt={`Preview of ${name}`} style={{ maxWidth: '100%', maxHeight: 420, objectFit: 'contain', background: '#fff', borderRadius: 8 }} />}
      {url && !isImage(name) && <p className="muted">{isPdf(name) ? 'PDFs open in a new tab.' : `A .${extOf(name)} file cannot be previewed here (it is a production or design file). Download it to open it in your usual software.`}</p>}
      <div className="row">{url && isPdf(name) && <a className="btn primary" href={url} target="_blank" rel="noreferrer">Open in a new tab</a>}{url && <Button onClick={() => void downloadFile(path, name)}>Download</Button>}<Button variant="ghost" onClick={onClose}>Close</Button></div>
    </Dialog>
  );
}

function ProofDialog({ orderRef, orderId, areas, onClose, onDone }: { orderRef: string; orderId: string; areas: ArtworkFileRow[]; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [picked, setPicked] = useState<string[]>(areas.map((a) => a.id)); const [file, setFile] = useState<File | null>(null); const [note, setNote] = useState(''); const { busy, err, setErr, run } = useAction(onDone);
  async function submit(e: FormEvent) {
    e.preventDefault(); if (!file || picked.length === 0) return; const bad = checkFile(file, PROOF_EXT); if (bad) { setErr(bad); return; }
    await run(async () => {
      const path = proofPath(orderRef, file.name); const up = await uploadFile(path, file); if (up) return `The file did not upload: ${up}`;
      const r = await proofCreate({ order_id: orderId, artwork_ids: picked, storage_path: path, file_name: file.name, note: note.trim() || undefined });
      if (r.ok === false) await removeFile(path);
      return r;
    }, 'Proof saved as a draft. Mark it as sent once it has gone to the customer.');
  }
  return (
    <Dialog title="New customer proof" onClose={onClose}>
      <form className="stack" style={{ gap: 10 }} onSubmit={submit}>
        <p className="muted">Upload the picture or PDF the customer will see, and choose which areas it shows. A new proof replaces any unanswered proof for the same areas.</p>
        <fieldset className="stack" style={{ gap: 6, border: 0, padding: 0 }}><legend className="dim">Areas on this proof</legend>
          {areas.map((a) => <label key={a.id} className="row" style={{ gap: 8 }}><input type="checkbox" checked={picked.includes(a.id)} aria-label={`Include ${a.area}`} onChange={(e) => setPicked((p) => (e.target.checked ? [...p, a.id] : p.filter((x) => x !== a.id)))} /><span>{a.area} <span className="dim">version {a.version}</span></span></label>)}</fieldset>
        <Field label={`The proof (${PROOF_EXT.join(', ')})`}><input type="file" accept={PROOF_EXT.map((x) => '.' + x).join(',')} onChange={(e) => { setFile(e.target.files?.[0] ?? null); setErr(null); }} aria-label="Proof file" /></Field>
        <Field label="Note (optional)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Proof note" /></Field>
        <Err m={err} />
        <div className="row"><Button variant="primary" disabled={busy || !file || picked.length === 0}>{busy ? 'Uploading…' : 'Save proof'}</Button><Button type="button" variant="ghost" onClick={onClose}>Cancel</Button></div>
      </form>
    </Dialog>
  );
}

function SendDialog({ proof, onClose, onDone }: { proof: ProofRow; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [to, setTo] = useState(''); const [via, setVia] = useState('email'); const [note, setNote] = useState(''); const { busy, err, run } = useAction(onDone);
  return (
    <Dialog title={`Mark ${proof.proof_ref} as sent`} onClose={onClose}>
      <p className="muted">Send the proof yourself (email, phone or in person), then record it here so it is chased if the customer goes quiet. Nothing is sent from this screen.</p>
      <Field label="Who was it sent to? (name or email)"><input className="input" value={to} onChange={(e) => setTo(e.target.value)} aria-label="Sent to" /></Field>
      <Field label="How?"><select className="select" value={via} onChange={(e) => setVia(e.target.value)} aria-label="Sent how">{Object.entries(VIA_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
      <Field label="Note (optional)"><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Send note" /></Field>
      <Err m={err} />
      <div className="row"><Button variant="primary" disabled={busy || to.trim().length < 3} onClick={() => void run(() => proofSend(proof.id, to.trim(), via, note.trim() || undefined), 'Recorded as sent.')}>{busy ? 'Saving…' : 'Record as sent'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
    </Dialog>
  );
}

function AnswerDialog({ orderRef, proof, onClose, onDone }: { orderRef: string; proof: ProofRow; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [outcome, setOutcome] = useState('approved'); const [by, setBy] = useState(proof.sent_to ?? ''); const [note, setNote] = useState(''); const [file, setFile] = useState<File | null>(null); const { busy, err, setErr, run } = useAction(onDone);
  const needNote = outcome !== 'approved'; const ok = by.trim().length >= 2 && (!needNote || note.trim().length >= 5);
  async function submit() {
    if (file) { const bad = checkFile(file, PROOF_EXT); if (bad) { setErr(bad); return; } }
    await run(async () => {
      let path: string | null = null; if (file) { path = proofPath(orderRef, file.name); const up = await uploadFile(path, file); if (up) return `The evidence file did not upload: ${up}`; }
      const r = await proofRespond({ proof_id: proof.id, outcome, by: by.trim(), note: note.trim() || undefined, evidence: path });
      if (r.ok === false && path) await removeFile(path);
      return r;
    }, outcome === 'approved' ? 'Approved. The areas on the proof are now approved.' : 'Answer recorded.');
  }
  return (
    <Dialog title={`The customer's answer to ${proof.proof_ref}`} onClose={onClose}>
      {proof.is_out_of_date && <div className="callout" role="alert">The artwork has changed since this proof was made, so an approval cannot be recorded on it. Make and send a new proof.</div>}
      <fieldset className="stack" style={{ gap: 6, border: 0, padding: 0 }}><legend className="dim">What did they say?</legend>
        {[['approved', 'Approved'], ['changes_requested', 'Wants changes'], ['rejected', 'Rejected']].map(([v, l]) => <label key={v} className="row" style={{ gap: 8 }}><input type="radio" name="outcome" checked={outcome === v} onChange={() => setOutcome(v)} aria-label={l} /><span>{l}</span></label>)}</fieldset>
      <Field label="Who at the customer said so?"><input className="input" value={by} onChange={(e) => setBy(e.target.value)} aria-label="Answered by" /></Field>
      <Field label={needNote ? 'What did they say? (required)' : 'Note (optional)'}><input className="input" value={note} onChange={(e) => setNote(e.target.value)} aria-label="Answer note" /></Field>
      <Field label="Evidence, such as a screenshot of their email (optional)"><input type="file" accept={PROOF_EXT.map((x) => '.' + x).join(',')} onChange={(e) => { setFile(e.target.files?.[0] ?? null); setErr(null); }} aria-label="Evidence file" /></Field>
      {outcome === 'approved' && <p className="dim">Approving marks the areas on this proof as approved.</p>}
      <Err m={err} />
      <div className="row"><Button variant="primary" disabled={busy || !ok || (outcome === 'approved' && proof.is_out_of_date)} onClick={() => void submit()}>{busy ? 'Saving…' : 'Record the answer'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
    </Dialog>
  );
}

function WithdrawDialog({ proof, onClose, onDone }: { proof: ProofRow; onClose: () => void; onDone: (m: string) => Promise<void> }) {
  const [reason, setReason] = useState(''); const { busy, err, run } = useAction(onDone);
  return (
    <Dialog title={`Withdraw ${proof.proof_ref}`} onClose={onClose}>
      <Field label="Why? (required)"><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} aria-label="Withdraw reason" /></Field>
      <Err m={err} />
      <div className="row"><Button variant="danger" disabled={busy || reason.trim().length < 5} onClick={() => void run(() => proofWithdraw(proof.id, reason.trim()), 'Proof withdrawn.')}>{busy ? 'Saving…' : 'Withdraw'}</Button><Button variant="ghost" onClick={onClose}>Keep it</Button></div>
    </Dialog>
  );
}
