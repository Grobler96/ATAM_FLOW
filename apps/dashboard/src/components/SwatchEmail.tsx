import { useMemo, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, EmptyState, Field, Panel, Status } from '../ui/primitives';
import { DataTable, type Column } from '../ui/DataTable';
import { refreshAll, useView } from '../data/store';
import { exceptionActionTo } from '../lib/api';
import { longSignedUrl, uploadFile } from '../lib/artworkFiles';
import { dateTime } from '../lib/format';
import { href } from '../router';
import { canChangeEmbroidery, type EmbAreaRow, type EmbDesignRow } from '../lib/embroidery';
import { activeTemplates, addressProblem, defaultTemplate, fillTemplate, lastAddresses, parseAddresses, PHOTO_EXT, photoProblem, PLACEHOLDERS, swatchEmailWords, swatchPhotoPath, swatchVars, unknownPlaceholders, type EmailTemplateRow, type EmbSwatchRow } from '../lib/swatchEmail';

// Emailing the swatch to the customer. Everything goes into the normal approval queue (Purchasing > Emails): nothing is sent from here. Sending it
// moves the design to "swatch sent"; the customer replies to the shared mailbox and staff then mark it approved or changes needed.
const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;

export function SwatchEmailDialog({ row, onClose }: { row: EmbAreaRow; onClose: () => void }) {
  const toast = useToast(); const templates = useView<EmailTemplateRow>('ui_email_templates'), swatches = useView<EmbSwatchRow>('ui_emb_swatches'), designs = useView<EmbDesignRow>('ui_emb_designs');
  const list = activeTemplates(templates.rows); const first = defaultTemplate(templates.rows); const vars = swatchVars(row);
  const [code, setCode] = useState<string>(''); const chosen = list.find((t) => t.code === (code || first?.code)) ?? null;
  const [edited, setEdited] = useState<{ subject?: string; body?: string; to?: string }>({}); const [photo, setPhoto] = useState<File | null>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const subject = edited.subject ?? (chosen ? fillTemplate(chosen.subject, vars) : ''); const body = edited.body ?? (chosen ? fillTemplate(chosen.body, vars) : '');
  const to = edited.to ?? lastAddresses(row.customer_id, swatches.rows, designs.rows).join(', ');
  const pick = (c: string) => { setCode(c); setEdited((e) => ({ to: e.to })); }; // a new template replaces the subject and message, not the address
  async function send() {
    const addrs = parseAddresses(to); const bad = addressProblem(addrs) ?? photoProblem(photo) ?? (!subject.trim() ? 'Add a subject.' : !body.trim() ? 'Write the message.' : null); if (bad) { setErr(bad); return; }
    setBusy(true); setErr(null);
    const path = swatchPhotoPath(row.design_id as string, row.design_round ?? 1, (photo as File).name); const up = await uploadFile(path, photo as File);
    if (up) { setBusy(false); setErr(`The photo could not be uploaded: ${up}`); return; }
    const url = await longSignedUrl(path); if (!url) { setBusy(false); setErr('The photo was uploaded but a link for the email could not be made. Try again.'); return; }
    const r = await exceptionActionTo('dtf', 'emb_swatch_email', { design_id: row.design_id, order_id: row.order_id, deco_line_id: row.deco_line_id, area: row.area, template_code: chosen?.code ?? '', to: addrs, subject: subject.trim(), body: body.trim(), photo_path: path, photo_url: url });
    setBusy(false); if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: `Email ${String(r.comm_ref ?? '')} is waiting for approval`, body: 'Nothing has been sent. Approve it in Purchasing > Emails. Once it is sent the swatch shows as sent.' }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={`Email the swatch: ${row.design_name ?? ''} (${row.order_ref})`}>
      <div className="stack">
        <p className="dim">The email goes to the approval queue first, so nothing is sent from here. The customer replies to the shared mailbox; when they do, mark the swatch approved or changes needed on the logo.</p>
        {list.length > 1 && <Field label="Template"><select className="select" value={chosen?.code ?? ''} onChange={(e) => pick(e.target.value)} aria-label="Template">{list.map((t) => <option key={t.code} value={t.code}>{t.name}{t.is_default ? ' (default)' : ''}</option>)}</select></Field>}
        <Field label="Send to (more than one address: separate with commas)"><input className="input" value={to} onChange={(e) => setEdited((x) => ({ ...x, to: e.target.value }))} placeholder="customer@example.com" aria-label="Send to" /></Field>
        <Field label="Subject"><input className="input" value={subject} onChange={(e) => setEdited((x) => ({ ...x, subject: e.target.value }))} aria-label="Subject" /></Field>
        <Field label="Message"><textarea className="input" rows={10} value={body} onChange={(e) => setEdited((x) => ({ ...x, body: e.target.value }))} aria-label="Message" /></Field>
        {unknownPlaceholders(subject + ' ' + body).length > 0 && <div className="callout" role="status">This still has {unknownPlaceholders(subject + ' ' + body).join(', ')} in it, which will go out as written.</div>}
        <Field label={`Photo of the swatch (${PHOTO_EXT.join(', ')})`}><input type="file" accept={PHOTO_EXT.map((e) => '.' + e).join(',')} onChange={(e) => setPhoto(e.target.files?.[0] ?? null)} aria-label="Photo of the swatch" /></Field>
        <span className="dim">The photo and the visual are shown inside the email. The link to the photo works for 14 days.</span>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy} onClick={() => void send()}>{busy ? 'Queuing…' : 'Queue the email for approval'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

function TemplateDialog({ t, onClose }: { t: EmailTemplateRow | null; onClose: () => void }) {
  const toast = useToast(); const [name, setName] = useState(t?.name ?? ''); const [subject, setSubject] = useState(t?.subject ?? ''); const [body, setBody] = useState(t?.body ?? '');
  const [isDefault, setDefault] = useState(t?.is_default ?? false); const [active, setActive] = useState(t?.is_active ?? true); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const sample = swatchVars({ customer_name: 'Seaview FC', design_name: 'Club crest', order_ref: '#636890', area: 'Left Chest', design_round: 1 });
  const odd = unknownPlaceholders(subject + ' ' + body);
  async function save() {
    setBusy(true); setErr(null); const r = await exceptionActionTo('dtf', 'email_template_save', { code: t?.code ?? '', name: name.trim(), subject: subject.trim(), body: body.trim(), is_default: isDefault, is_active: active }); setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: t ? 'Template saved' : 'Template added', body: name.trim() }); void refreshAll(); onClose();
  }
  return (
    <Modal open onClose={onClose} title={t ? `Edit template: ${t.name}` : 'Add a swatch email template'}>
      <div className="stack">
        <Field label="Name (only staff see this)"><input className="input" value={name} onChange={(e) => setName(e.target.value)} aria-label="Template name" /></Field>
        <Field label="Subject"><input className="input" value={subject} onChange={(e) => setSubject(e.target.value)} aria-label="Template subject" /></Field>
        <Field label="Message"><textarea className="input" rows={12} value={body} onChange={(e) => setBody(e.target.value)} aria-label="Template message" /></Field>
        <div className="stack" style={{ gap: 2 }}><span className="fact-l">You can use these, and they are filled in for each email</span>{PLACEHOLDERS.map((p) => <span key={p.token} className="dim"><code>{p.token}</code> {p.means}</span>)}</div>
        {odd.length > 0 && <div className="callout" role="status">{odd.join(', ')} is not one of those, so it would go out as written.</div>}
        <div className="callout soft stack" style={{ gap: 4 }}><span className="fact-l">How it will read (example)</span><b>{fillTemplate(subject, sample)}</b><span style={{ whiteSpace: 'pre-wrap' }}>{fillTemplate(body, sample)}</span></div>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={isDefault} disabled={t?.is_default} onChange={(e) => { setDefault(e.target.checked); if (e.target.checked) setActive(true); }} /> Use this one by default</label>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={active} disabled={isDefault} onChange={(e) => setActive(e.target.checked)} /> Offer it when sending a swatch</label>
        {err && <Err m={err} />}
        <div className="row"><Button variant="primary" disabled={busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Save'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

// The "Swatch email templates" tab: add to them, edit them, choose the default.
export function TemplatesPanel({ role }: { role: string | null | undefined }) {
  const templates = useView<EmailTemplateRow>('ui_email_templates'); const [open, setOpen] = useState<string | 'new' | null>(null); const can = canChangeEmbroidery(role);
  const rows = useMemo(() => templates.rows.filter((t) => t.kind === 'embroidery_swatch').sort((a, b) => Number(b.is_default) - Number(a.is_default) || a.name.localeCompare(b.name)), [templates.rows]);
  const current = open && open !== 'new' ? rows.find((t) => t.code === open) ?? null : null;
  const cols: Column<EmailTemplateRow>[] = [
    { id: 'name', header: 'Name', width: '260px', render: (t) => <b>{t.name}</b>, sort: (t) => t.name, csv: (t) => t.name },
    { id: 'subject', header: 'Subject', width: '340px', render: (t) => <span className="dim">{t.subject}</span>, csv: (t) => t.subject },
    { id: 'state', header: '', width: '170px', render: (t) => (t.is_default ? <Status tone="good">Default</Status> : t.is_active ? <span className="dim">Offered</span> : <Status tone="medium">Switched off</Status>) },
    { id: 'by', header: 'Last changed', width: '170px', render: (t) => <span className="dim">{dateTime(t.updated_at)}</span>, sort: (t) => t.updated_at, hide: 'mobile' }
  ];
  return (
    <>
      <div className="callout soft">This is the wording of the email that sends a swatch to the customer. Add your own versions or change these: they are filled in for each customer and order, and staff can still change the text before it is queued. Emails always go to the approval queue first. A logo's dialog has <b>Email the swatch to the customer</b> once its swatch is in progress.</div>
      <div className="row"><Button variant="primary" disabled={!can} title={can ? '' : 'Managers, admins and production planners only'} onClick={() => setOpen('new')}>Add a template</Button></div>
      <Panel flush>
        <DataTable<EmailTemplateRow> rows={rows} columns={cols} rowKey={(t) => t.code} loading={templates.loading} error={templates.error} onRetry={() => void templates.refresh()} storageKey="email-templates" exportName="swatch-email-templates" searchText={(t) => [t.name, t.subject].join(' ')} searchPlaceholder="Search templates…" onRowClick={(t) => setOpen(t.code)} empty={<EmptyState icon="check" title="No templates">Add a template to get started.</EmptyState>} />
      </Panel>
      {open && (open === 'new' || current) && <TemplateDialog t={current} onClose={() => setOpen(null)} />}
    </>
  );
}

// The emails already made for a design, for its dialog.
export function SwatchEmailList({ design }: { design: string }) {
  const swatches = useView<EmbSwatchRow>('ui_emb_swatches'); const mine = swatches.rows.filter((s) => s.design_id === design).sort((a, b) => b.created_at.localeCompare(a.created_at));
  if (mine.length === 0) return null;
  return <div className="stack" style={{ gap: 2 }}><span className="fact-l">Swatch emails</span>{mine.map((s) => <span key={s.id} className="dim">{dateTime(s.created_at)} · round {s.round} · {s.comm_ref ?? ''} · {swatchEmailWords(s)} · to {s.to_addresses.join(', ')} <a href={href('purchasing')}>Purchasing <a href={href('purchasing/emails')}>Emails</a>gt; Emails</a></span>)}</div>;
}
