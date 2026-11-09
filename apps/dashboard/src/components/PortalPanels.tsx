import { useEffect, useState } from 'react';
import { Modal, useToast } from '../ui/overlay';
import { Button, Field, Status } from '../ui/primitives';
import { useView, refreshAll } from '../data/store';
import { useCtx } from '../data/context';
import { supabase } from '../lib/api';
import { dateTime } from '../lib/format';
import { opsAction, type PortalEvidence, type PortalMessage, type PortalReceipt, type PortalSignIn, type PortalUser } from '../lib/orderChanges';
import { ReasonDialog } from './WarehouseDialogs';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
export const PORTAL_URL = () => location.href.replace(/index\.html.*$|#.*$/, '').replace(/\/?$/, '/') + 'portal.html';

// Who at a decorator can sign in to the portal. Switching someone off locks them out at once.
export function PortalAccessPanel({ producerId, producerName }: { producerId: string; producerName: string }) {
  const users = useView<PortalUser>('ui_portal_users'); const { senior } = useCtx(); const mine = users.rows.filter((u) => u.producer_id === producerId);
  const [dlg, setDlg] = useState<null | 'add' | { user: PortalUser }>(null); const close = () => { setDlg(null); void refreshAll(); };
  return (
    <section className="stack" aria-label="Decorator portal access">
      <div className="row wrap"><h3 className="grow">Portal sign-in</h3><Button size="sm" disabled={!senior} title={senior ? '' : 'Only a manager or admin can invite people'} onClick={() => setDlg('add')}>Invite someone</Button></div>
      {mine.length === 0 ? <p className="dim">Nobody at {producerName} can sign in yet. Invite the people who will check goods in and update jobs.</p> : <div className="stack" style={{ gap: 4 }}>{mine.map((u) => (
        <div key={u.id} className="row wrap" style={{ gap: 10 }}><b>{u.name ?? u.email}</b><span className="muted">{u.name ? u.email : ''}</span><Status tone={u.is_active ? 'good' : 'low'} plain>{!u.is_active ? 'Switched off' : u.has_signed_in ? 'Signed in' : 'Invited, not signed in yet'}</Status><span className="dim grow">{u.last_seen_at ? `Last seen ${dateTime(u.last_seen_at)}` : ''}</span>
          <Button size="sm" disabled={!senior} onClick={() => setDlg({ user: u })}>{u.is_active ? 'Switch off…' : 'Switch on…'}</Button></div>))}</div>}
      {mine.some((u) => u.personal_email) && <p className="warn" role="status">Some of these logins use a personal address. Company addresses are safer: a personal mailbox is harder for us to control.</p>}
      <SignInActivity emails={mine.map((u) => u.email.toLowerCase())} />
      <p className="dim">They sign in at <span className="mono">{PORTAL_URL()}</span> with the invited email: a secure link is emailed each time, there is no password. They see only work sent to {producerName}.</p>
      {dlg === 'add' && <AddUser producerId={producerId} producerName={producerName} onClose={close} />}
      {dlg && typeof dlg === 'object' && <ReasonDialog path="operations" title={`${dlg.user.is_active ? 'Switch off' : 'Switch on'} ${dlg.user.name ?? dlg.user.email}`} intro={dlg.user.is_active ? 'They are signed out of the portal at once and cannot get back in.' : 'They can sign in again with a new emailed link.'} confirm={dlg.user.is_active ? 'Switch off' : 'Switch on'} action="portal_set_user" params={{ user_id: dlg.user.id, active: !dlg.user.is_active }} presets={dlg.user.is_active ? ['Left the company', 'No longer works with us on this'] : ['Back at work']} onClose={close} />}
    </section>
  );
}

const EVENT_LABEL: Record<PortalSignIn['event'], string> = { first_sign_in: 'First sign-in', signed_in: 'Signed in', new_device: 'New device', refused: 'Refused (not invited)' };
// Recent portal sign-ins for this decorator's people, so a strange one is easy to spot.
function SignInActivity({ emails }: { emails: string[] }) {
  const log = useView<PortalSignIn>('ui_portal_sign_ins'); const rows = log.rows.filter((r) => r.email && emails.includes(r.email.toLowerCase())).sort((a, b) => b.at.localeCompare(a.at)).slice(0, 8);
  if (rows.length === 0) return null;
  return <details><summary className="dim">Recent sign-ins ({rows.length})</summary><div className="stack" style={{ gap: 2, marginTop: 6 }} data-testid="portal-signins">{rows.map((r) => <div key={r.id} className="row wrap" style={{ gap: 10, fontSize: 12.5 }}><span className="dim" style={{ minWidth: 120 }}>{dateTime(r.at)}</span><Status tone={r.event === 'new_device' ? 'medium' : r.event === 'refused' ? 'high' : 'low'} plain>{EVENT_LABEL[r.event]}</Status><span className="muted">{r.email}</span>{r.ip && <span className="dim mono">{r.ip}</span>}</div>)}</div></details>;
}

function AddUser({ producerId, producerName, onClose }: { producerId: string; producerName: string; onClose: () => void }) {
  const [email, setEmail] = useState(''); const [name, setName] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const toast = useToast(); const { role } = useCtx(); const [personal, setPersonal] = useState(false); const [why, setWhy] = useState('');
  async function go() { setBusy(true); setErr(null);
    if (personal && role === 'admin') { const a = await opsAction('portal_allow_email', { email, reason: why }); if (a.ok === false) { setBusy(false); setErr(String(a.error ?? 'That did not work.')); return; } }
    const r = await opsAction('portal_add_user', { producer_id: producerId, email, name }); setBusy(false); if (r.ok === false) { if ((r as { personal_email?: boolean }).personal_email) setPersonal(true); setErr(String(r.error ?? 'That did not work.')); return; } toast.push({ tone: 'good', title: 'Invited', body: `${email} can now sign in at the portal with that address.` }); onClose(); }
  return <Modal open onClose={onClose} title={`Invite someone at ${producerName}`}><div className="stack">
    <Field label="Their name"><input className="input" value={name} onChange={(e) => setName(e.target.value)} /></Field>
    <Field label="Their work email"><input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
    <p className="dim">This gives them access only; they sign in themselves from the portal page using this email. Use their own address, not a shared one.</p>
    {personal && (role === 'admin' ? <Field label="Why is this personal address acceptable? (recorded)"><input className="input" value={why} onChange={(e) => setWhy(e.target.value)} placeholder="e.g. Sole trader, no company mailbox" /></Field> : <p className="warn">Only an admin can allow a personal address. Ask for a company address, or ask an admin.</p>)}
    {err && <Err m={err} />}<div className="row"><Button variant="primary" disabled={busy || !email.includes('@') || (personal && (role !== 'admin' || why.trim().length < 10))} onClick={() => void go()}>{busy ? 'Saving…' : personal ? 'Allow this address and give access' : 'Give access'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div></div></Modal>;
}

// On a consignment: what the decorator counted at goods-in, their photos, and the message thread.
export function PortalThread({ code }: { code: string }) {
  const msgs = useView<PortalMessage>('ui_tp_messages'); const rcp = useView<PortalReceipt>('ui_tp_receipts'); const evi = useView<PortalEvidence>('ui_tp_evidence'); const { canAct } = useCtx(); const toast = useToast();
  const m = msgs.rows.filter((x) => x.movement_code === code).sort((a, b) => a.created_at.localeCompare(b.created_at)); const r = rcp.rows.filter((x) => x.movement_code === code); const e = evi.rows.filter((x) => x.movement_code === code);
  const [urls, setUrls] = useState<Record<string, string>>({}); const [text, setText] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [resolve, setResolve] = useState(false);
  useEffect(() => { void Promise.all(e.map(async (x) => { const { data } = await supabase.storage.from('producer-evidence').createSignedUrl(x.storage_path, 3600); return [x.id, data?.signedUrl ?? ''] as const; })).then((p) => setUrls(Object.fromEntries(p))); }, [e.length]); // eslint-disable-line react-hooks/exhaustive-deps
  const open = r.filter((x) => x.issue && !x.resolved_at);
  async function reply() { setBusy(true); setErr(null); const res = await opsAction('portal_reply', { code, body: text }); setBusy(false); if (res.ok === false) { setErr(String(res.error ?? 'That did not work.')); return; } setText(''); toast.push({ tone: 'good', title: 'Reply sent', body: 'The decorator sees it on the job.' }); void refreshAll(); }
  if (m.length === 0 && r.length === 0 && e.length === 0 && !canAct) return null;
  return (
    <section className="stack" aria-label="Decorator portal">
      <h3>From the decorator</h3>
      {r.length > 0 && <div className="stack" style={{ gap: 2 }}>{r.map((x) => <div key={x.id} className="row wrap" style={{ gap: 10 }}><span className="mono">{x.sku}</span><span>sent {x.qty_sent}, counted {x.qty_counted}{x.qty_damaged ? `, ${x.qty_damaged} damaged` : ''}</span>{x.issue ? <Status tone={x.resolved_at ? 'low' : 'critical'} plain>{x.resolved_at ? `${x.issue} (looked at)` : `Problem: ${x.issue}`}</Status> : <Status tone="good" plain>Clean</Status>}<span className="dim grow">{x.note}</span></div>)}
        {open.length > 0 && <div><Button size="sm" variant="primary" disabled={!canAct} onClick={() => setResolve(true)}>Mark the problem as dealt with…</Button></div>}</div>}
      {e.length > 0 && <div className="row wrap" style={{ gap: 8 }}>{e.map((x) => (urls[x.id] ? <a key={x.id} href={urls[x.id]} target="_blank" rel="noreferrer" title={`${x.kind}${x.caption ? ': ' + x.caption : ''}`}><img src={urls[x.id]} alt={x.caption ?? 'Decorator photo'} style={{ width: 80, height: 80, objectFit: 'cover', borderRadius: 8 }} /></a> : null))}</div>}
      <div className="stack" style={{ gap: 4 }}>{m.length === 0 ? <p className="dim">No messages with the decorator yet.</p> : m.map((x) => <div key={x.id} className="row" style={{ gap: 10 }}><span className="dim" style={{ minWidth: 110 }}>{dateTime(x.created_at)}</span><b>{x.side === 'producer' ? x.author ?? 'Decorator' : 'ATAM'}</b><span className="grow">{x.body}</span></div>)}</div>
      <div className="row" style={{ gap: 8 }}><input className="input grow" aria-label="Reply to the decorator" placeholder="Reply to the decorator" value={text} maxLength={2000} onChange={(ev) => setText(ev.target.value)} /><Button disabled={!canAct || busy || !text.trim()} onClick={() => void reply()}>Send</Button></div>
      {err && <Err m={err} />}
      {resolve && <ReasonDialog path="operations" title="Goods-in problem dealt with" intro="Say what was decided (resend, replace, accept as is). The decorator is told on the job." confirm="Mark as dealt with" action="portal_resolve" params={{ code }} presets={['Replacement sent', 'Accepted as is', 'Credit agreed', 'Count was wrong, all correct']} onClose={() => { setResolve(false); void refreshAll(); }} />}
    </section>
  );
}
