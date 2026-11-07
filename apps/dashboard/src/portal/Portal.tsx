import { useCallback, useEffect, useState, type FormEvent } from 'react';
import type { Session } from '@supabase/supabase-js';
import { BUCKET, fmtDate, fmtTime, ISSUES, rpc, sb, STATE_LABEL, type Me, type PortalItem, type PortalJob, type PortalJobRow } from './client';

const Err = ({ m }: { m: string }) => <div className="callout" style={{ borderColor: 'rgba(255,107,107,.5)', background: 'var(--critical-soft)' }} role="alert">{m}</div>;
const Pill = ({ s }: { s: string }) => <span className="chip on" style={{ cursor: 'default' }}>{STATE_LABEL[s] ?? s}</span>;
const useHash = () => { const [h, setH] = useState(location.hash); useEffect(() => { const f = () => setH(location.hash); addEventListener('hashchange', f); return () => removeEventListener('hashchange', f); }, []); return h; };

export function Portal() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  useEffect(() => { void sb.auth.getSession().then(({ data }) => setSession(data.session)); const { data } = sb.auth.onAuthStateChange((_e, s) => setSession(s)); return () => data.subscription.unsubscribe(); }, []);
  if (session === undefined) return <Shell><p className="dim">Loading…</p></Shell>;
  if (!session) return <Shell><SignIn /></Shell>;
  return <Signed />;
}

function Shell({ children, who, onOut }: { children: React.ReactNode; who?: string; onOut?: () => void }) {
  return (
    <div style={{ maxWidth: 860, margin: '0 auto', padding: '16px 16px 64px' }}>
      <header className="row wrap" style={{ gap: 12, marginBottom: 16 }}><b className="grow" style={{ fontSize: 20 }}>ATAM decorator portal</b>{who && <span className="muted">{who}</span>}{onOut && <button className="chip" onClick={onOut}>Sign out</button>}</header>
      {children}
    </div>
  );
}

function SignIn() {
  const [email, setEmail] = useState(''); const [sent, setSent] = useState(false); const [code, setCode] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function send(e: FormEvent) {
    e.preventDefault(); setBusy(true); setErr(null);
    // Invite-only: never create an account from here. An address that has not been invited gets no email, and sees exactly the same message, so nobody can use this page to find out who is invited.
    const { error } = await sb.auth.signInWithOtp({ email: email.trim(), options: { emailRedirectTo: location.origin + location.pathname, shouldCreateUser: false } });
    setBusy(false);
    if (error && !(error.status === 422 || /signups? not allowed|not found/i.test(error.message))) setErr(error.message); else setSent(true);
  }
  async function verify(e: FormEvent) { e.preventDefault(); setBusy(true); setErr(null); const { error } = await sb.auth.verifyOtp({ email: email.trim(), token: code.trim(), type: 'email' }); setBusy(false); if (error) setErr('That code did not work. Check it and try again.'); }
  return (
    <form className="panel stack" style={{ padding: 24, gap: 14, maxWidth: 420 }} onSubmit={sent ? verify : send}>
      <h1 style={{ margin: 0 }}>Sign in</h1>
      <p className="muted">This portal is by invitation only. Use the email address ATAM invited and we will email you a secure sign-in link. There is no password to remember.</p>
      <label className="stack" style={{ gap: 4 }}><span>Email</span><input className="input" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} disabled={sent} /></label>
      {sent && <><div className="callout" role="status">If that address has been invited, a sign-in link is on its way. Open it on this device. If you were sent a code instead, type it here.</div>
        <label className="stack" style={{ gap: 4 }}><span>Code from the email (if you have one)</span><input className="input" inputMode="numeric" autoComplete="one-time-code" value={code} onChange={(e) => setCode(e.target.value)} /></label></>}
      {err && <Err m={err} />}
      {!sent ? <button className="btn primary" disabled={busy || !email}>{busy ? 'Sending…' : 'Email me a sign-in link'}</button> : <div className="row"><button className="btn primary" disabled={busy || !code}>Sign in with code</button><button type="button" className="btn" onClick={() => { setSent(false); setCode(''); }}>Use a different email</button></div>}
    </form>
  );
}

function Signed() {
  const [me, setMe] = useState<Me | null>(null); const [err, setErr] = useState<string | null>(null); const hash = useHash();
  useEffect(() => { void rpc<Me>('portal_whoami').then((r) => { if (r.ok) setMe(r.data as Me); else setErr(r.error ?? 'Could not sign you in.'); }); }, []);
  const out = () => void sb.auth.signOut();
  if (err) return <Shell onOut={out}><div className="panel stack" style={{ padding: 24 }}><h1 style={{ margin: 0 }}>No access</h1><p>{err}</p></div></Shell>;
  if (!me) return <Shell onOut={out}><p className="dim">Loading…</p></Shell>;
  const job = hash.match(/^#\/job\/([\w-]+)/);
  return <Shell who={`${me.user} · ${me.producer}`} onOut={out}>{job ? <JobCard code={job[1]} me={me} /> : <Jobs />}</Shell>;
}

function Jobs() {
  const [rows, setRows] = useState<PortalJobRow[] | null>(null); const [err, setErr] = useState<string | null>(null);
  useEffect(() => { void rpc<PortalJobRow[]>('portal_jobs').then((r) => { if (r.ok) setRows(r.data ?? []); else setErr(r.error ?? 'Could not load your jobs.'); }); }, []);
  if (err) return <Err m={err} />;
  if (!rows) return <p className="dim">Loading your jobs…</p>;
  const groups: [string, (r: PortalJobRow) => boolean][] = [['Needs your attention', (r) => ['to_accept', 'accepted'].includes(r.state)], ['In progress', (r) => ['checked_in', 'in_production', 'ready_to_ship'].includes(r.state)], ['Sent back', (r) => r.state === 'sent_back'], ['Complete', (r) => ['done', 'declined'].includes(r.state)]];
  return (
    <div className="stack" style={{ gap: 18 }}>
      <h1 style={{ margin: 0 }}>Your work</h1>
      {rows.length === 0 && <div className="callout" role="status">Nothing has been sent to you yet. Jobs appear here as soon as ATAM sends the goods.</div>}
      {groups.map(([title, test]) => { const list = rows.filter(test); if (!list.length) return null; return (
        <section key={title} className="stack" style={{ gap: 8 }}><h2 style={{ margin: 0, fontSize: 16 }}>{title}</h2>
          {list.map((r) => (
            <a key={r.code} className="panel stack" href={'#/job/' + r.code} style={{ padding: 14, gap: 6, textDecoration: 'none', color: 'inherit' }}>
              <div className="row wrap" style={{ gap: 10 }}><b className="mono">{r.code}</b><Pill s={r.state} />{r.unread > 0 && <span className="chip">New message</span>}<span className="grow" /><span className="dim">Due {fmtDate(r.expected_return_date)}</span></div>
              <div>{(r.orders ?? []).map((o) => `${o.order_ref}${o.customer ? ' · ' + o.customer : ''}`).join('  |  ')}</div>
              <span className="dim">{r.units} unit(s){r.direct_to_customer ? ' · ship straight to the customer' : ''}</span>
            </a>))}
        </section>); })}
    </div>
  );
}

function JobCard({ code, me }: { code: string; me: Me }) {
  const [job, setJob] = useState<PortalJob | null>(null); const [err, setErr] = useState<string | null>(null); const [urls, setUrls] = useState<Record<string, string>>({});
  const load = useCallback(async () => { const r = await rpc<PortalJob>('portal_job', { p_code: code }); if (!r.ok) { setErr(r.error ?? 'Could not load this job.'); return; } setJob(r.data as PortalJob); setErr(null); }, [code]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (!job) return; void Promise.all(job.evidence.map(async (e) => { const { data } = await sb.storage.from(BUCKET).createSignedUrl(e.path, 3600); return [e.id, data?.signedUrl ?? ''] as const; })).then((p) => setUrls(Object.fromEntries(p))); }, [job]);
  if (err) return <div className="stack"><a href="#/">← All jobs</a><Err m={err} /></div>;
  if (!job) return <p className="dim">Loading…</p>;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <a href="#/">← All jobs</a>
      <div className="row wrap" style={{ gap: 10 }}><h1 style={{ margin: 0 }} className="mono">{job.code}</h1><Pill s={job.state} /></div>
      <div className="dim">Sent {fmtDate(job.dispatch_date)} · due back {fmtDate(job.expected_return_date)}{job.tracking_in ? ` · tracking in: ${job.carrier_in ?? ''} ${job.tracking_in}` : ''}</div>
      {job.instructions && <div className="callout" role="note"><b>Instructions for your work</b><div>{job.instructions}</div></div>}
      {job.declined_reason && <div className="callout" role="status">You declined this job: {job.declined_reason}. Message us if that has changed.</div>}
      <Items items={job.items} />
      <Actions job={job} me={me} onDone={load} />
      {job.evidence.length > 0 && <section className="stack" style={{ gap: 8 }}><h2 style={{ margin: 0, fontSize: 16 }}>Photos</h2><div className="row wrap" style={{ gap: 8 }}>{job.evidence.map((e) => (urls[e.id] ? <a key={e.id} href={urls[e.id]} target="_blank" rel="noreferrer" title={e.caption ?? ''}><img src={urls[e.id]} alt={e.caption ?? 'Photo'} style={{ width: 96, height: 96, objectFit: 'cover', borderRadius: 8 }} /></a> : null))}</div></section>}
      <Messages job={job} onDone={load} />
      {job.history.length > 0 && <section className="stack" style={{ gap: 4 }}><h2 style={{ margin: 0, fontSize: 16 }}>History</h2><ul className="plain">{job.history.map((h, i) => <li key={i}><span className="dim">{fmtTime(h.at)}</span> · {h.event.replace(/_/g, ' ')}{h.note ? ` · ${h.note}` : ''}</li>)}</ul></section>}
    </div>
  );
}

function Items({ items }: { items: PortalItem[] }) {
  return (
    <div style={{ overflowX: 'auto' }}><table className="table" style={{ minWidth: 520 }}>
      <thead><tr><th>Order</th><th>Item</th><th className="r">Sent</th><th className="r">You counted</th></tr></thead>
      <tbody>{items.map((i) => (<tr key={i.item_id}><td><b>{i.order_ref}</b><div className="dim">{i.customer}</div></td><td><span className="mono">{i.sku}</span><div className="dim">{[i.product, i.colour, i.size].filter(Boolean).join(' · ')}</div></td><td className="r">{i.qty_sent}</td>
        <td className="r">{i.counted == null ? '—' : <>{i.counted}{i.damaged ? ` (${i.damaged} damaged)` : ''}{i.issue && <div className="dim">{i.issue_resolved ? 'ATAM has looked at this' : 'Problem reported'}</div>}</>}</td></tr>))}</tbody></table></div>
  );
}

function Actions({ job, me, onDone }: { job: PortalJob; me: Me; onDone: () => Promise<void> }) {
  const [mode, setMode] = useState<null | 'decline' | 'checkin' | 'delay' | 'ship'>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [note, setNote] = useState(''); const [date, setDate] = useState('');
  async function run(fn: string, args: Record<string, unknown>, after?: () => void) { setBusy(true); setErr(null); const r = await rpc(fn, args); setBusy(false); if (!r.ok) { setErr(r.error ?? 'That did not work.'); return false; } setMode(null); setNote(''); after?.(); await onDone(); return true; }
  const s = job.state; const code = job.code;
  return (
    <section className="panel stack" style={{ padding: 16, gap: 12 }} aria-label="What to do next">
      <h2 style={{ margin: 0, fontSize: 16 }}>What to do next</h2>
      {err && <Err m={err} />}
      {s === 'to_accept' && mode === null && <div className="row wrap"><button className="btn primary" disabled={busy} onClick={() => void run('portal_accept', { p_code: code })}>Accept this job</button><button className="btn" onClick={() => setMode('decline')}>I cannot take this job</button></div>}
      {mode === 'decline' && <div className="stack"><label className="stack" style={{ gap: 4 }}><span>Why can you not take it?</span><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></label><div className="row"><button className="btn primary" disabled={busy || note.trim().length < 5} onClick={() => void run('portal_decline', { p_code: code, p_reason: note })}>Send</button><button className="btn" onClick={() => setMode(null)}>Cancel</button></div></div>}
      {(s === 'to_accept' || s === 'accepted') && mode !== 'decline' && (mode === 'checkin' ? <CheckIn job={job} me={me} onCancel={() => setMode(null)} onDone={async () => { setMode(null); await onDone(); }} /> : <div className="stack" style={{ gap: 6 }}>{s === 'accepted' && <p className="muted">You have accepted this job. When the goods arrive, check them in.</p>}<button className="btn primary" onClick={() => setMode('checkin')}>The goods have arrived: check them in</button></div>)}
      {s === 'checked_in' && mode === null && <div className="row wrap"><button className="btn primary" disabled={busy} onClick={() => void run('portal_stage', { p_code: code, p_stage: 'in_production', p_note: null, p_new_date: null })}>Start production</button><button className="btn" onClick={() => setMode('delay')}>Report a delay</button></div>}
      {s === 'in_production' && mode === null && <div className="row wrap"><button className="btn primary" disabled={busy} onClick={() => void run('portal_stage', { p_code: code, p_stage: 'production_complete', p_note: null, p_new_date: null })}>Production is complete</button><button className="btn" onClick={() => setMode('delay')}>Report a delay</button></div>}
      {s === 'ready_to_ship' && mode === null && <button className="btn primary" onClick={() => setMode('ship')}>{job.direct_to_customer ? 'Record shipping to the customer' : 'Send the goods back to ATAM'}</button>}
      {mode === 'delay' && <div className="stack"><label className="stack" style={{ gap: 4 }}><span>New date you can finish by</span><input className="input" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label><label className="stack" style={{ gap: 4 }}><span>Why is it delayed?</span><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></label><div className="row"><button className="btn primary" disabled={busy || !date || note.trim().length < 5} onClick={() => void run('portal_stage', { p_code: code, p_stage: 'delayed', p_note: note, p_new_date: date })}>Send</button><button className="btn" onClick={() => setMode(null)}>Cancel</button></div></div>}
      {mode === 'ship' && <Ship job={job} onCancel={() => setMode(null)} onDone={async () => { setMode(null); await onDone(); }} />}
      {['sent_back', 'done'].includes(s) && <p className="muted">{s === 'sent_back' ? `Sent back${job.return_tracking ? ` (tracking ${job.return_tracking})` : job.customer_tracking ? ` (tracking ${job.customer_tracking})` : ''}. ATAM will confirm when it arrives.` : 'This job is complete. Thank you.'}</p>}
    </section>
  );
}

function CheckIn({ job, me, onCancel, onDone }: { job: PortalJob; me: Me; onCancel: () => void; onDone: () => Promise<void> }) {
  const [rows, setRows] = useState(() => job.items.map((i) => ({ item_id: i.item_id, qty_counted: String(i.qty_sent), qty_damaged: '0', issue: '', note: '' }))); const [files, setFiles] = useState<File[]>([]); const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const set = (k: number, patch: Partial<(typeof rows)[number]>) => setRows((p) => p.map((r, i) => (i === k ? { ...r, ...patch } : r)));
  const bad = (k: number) => Number(rows[k].qty_counted) !== job.items[k].qty_sent || Number(rows[k].qty_damaged) > 0;
  async function submit() {
    setBusy(true); setErr(null);
    const items = rows.map((r) => ({ item_id: r.item_id, qty_counted: Number(r.qty_counted), qty_damaged: Number(r.qty_damaged || 0), issue: r.issue || null, note: r.note }));
    const r = await rpc('portal_check_in', { p_code: job.code, p_items: items, p_note: note });
    if (!r.ok) { setBusy(false); setErr(r.error ?? 'That did not work.'); return; }
    for (const f of files) {
      const path = `${me.producer_id}/${job.code}/${Date.now()}-${f.name.replace(/[^\w.-]+/g, '_')}`;
      const up = await sb.storage.from(BUCKET).upload(path, f, { contentType: f.type });
      if (up.error) { setErr(`Goods are checked in, but a photo (${f.name}) did not upload: ${up.error.message}. You can add it by message.`); continue; }
      await rpc('portal_evidence_add', { p_code: job.code, p_item: null, p_path: path, p_kind: 'goods_in', p_caption: null });
    }
    setBusy(false); await onDone();
  }
  return (
    <div className="stack" style={{ gap: 12 }}>
      <p className="muted">Count what actually arrived. If anything is short, damaged or wrong, say so: it goes straight to ATAM.</p>
      {job.items.map((i, k) => (
        <div key={i.item_id} className="panel stack" style={{ padding: 12, gap: 8 }}>
          <div><b>{i.order_ref}</b> · <span className="mono">{i.sku}</span> <span className="dim">{[i.colour, i.size].filter(Boolean).join(' · ')}</span> · sent <b>{i.qty_sent}</b></div>
          <div className="row wrap" style={{ gap: 12 }}>
            <label className="stack" style={{ gap: 2 }}><span>Counted</span><input className="input" style={{ width: 90 }} inputMode="numeric" value={rows[k].qty_counted} onChange={(e) => set(k, { qty_counted: e.target.value })} aria-label={`Counted ${i.sku}`} /></label>
            <label className="stack" style={{ gap: 2 }}><span>Damaged</span><input className="input" style={{ width: 90 }} inputMode="numeric" value={rows[k].qty_damaged} onChange={(e) => set(k, { qty_damaged: e.target.value })} aria-label={`Damaged ${i.sku}`} /></label>
            {bad(k) && <label className="stack grow" style={{ gap: 2 }}><span>What is the problem?</span><select className="select" value={rows[k].issue} onChange={(e) => set(k, { issue: e.target.value })} aria-label={`Problem ${i.sku}`}><option value="">Choose…</option>{ISSUES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>}
          </div>
          {bad(k) && <label className="stack" style={{ gap: 2 }}><span>Tell us what you can see (required)</span><input className="input" value={rows[k].note} onChange={(e) => set(k, { note: e.target.value })} aria-label={`Note ${i.sku}`} /></label>}
        </div>))}
      <label className="stack" style={{ gap: 4 }}><span>Photos (optional, helpful if anything is wrong)</span><input type="file" accept="image/*,application/pdf" multiple capture="environment" onChange={(e) => setFiles(Array.from(e.target.files ?? []))} /></label>
      {files.length > 0 && <span className="dim">{files.length} file(s) will be uploaded.</span>}
      <label className="stack" style={{ gap: 4 }}><span>Anything else? (optional)</span><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></label>
      {err && <Err m={err} />}
      <div className="row"><button className="btn primary" disabled={busy || rows.some((r, k) => bad(k) && r.note.trim().length < 5)} onClick={() => void submit()}>{busy ? 'Sending…' : rows.some((_, k) => bad(k)) ? 'Check in and report the problem' : 'Check in: all correct'}</button><button className="btn" disabled={busy} onClick={onCancel}>Cancel</button></div>
    </div>
  );
}

function Ship({ job, onCancel, onDone }: { job: PortalJob; onCancel: () => void; onDone: () => Promise<void> }) {
  const [carrier, setCarrier] = useState(''); const [tracking, setTracking] = useState(''); const [note, setNote] = useState(''); const [qty, setQty] = useState(() => job.items.map((i) => String(i.qty_outstanding || i.qty_sent)));
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const short = !job.direct_to_customer && job.items.some((i, k) => Number(qty[k]) < (i.qty_outstanding || i.qty_sent));
  async function go() { setBusy(true); setErr(null); const r = await rpc('portal_ship', { p_code: job.code, p_items: job.items.map((i, k) => ({ item_id: i.item_id, qty_shipped: Number(qty[k]) })), p_carrier: carrier, p_tracking: tracking, p_note: note }); setBusy(false); if (!r.ok) { setErr(r.error ?? 'That did not work.'); return; } await onDone(); }
  return (
    <div className="stack" style={{ gap: 10 }}>
      {!job.direct_to_customer && job.items.map((i, k) => <label key={i.item_id} className="row wrap" style={{ gap: 10 }}><span className="grow"><b>{i.order_ref}</b> · <span className="mono">{i.sku}</span></span><span>Units sent</span><input className="input" style={{ width: 90 }} inputMode="numeric" value={qty[k]} onChange={(e) => setQty((p) => p.map((v, j) => (j === k ? e.target.value : v)))} aria-label={`Units sent ${i.sku}`} /></label>)}
      <label className="stack" style={{ gap: 2 }}><span>Courier</span><input className="input" value={carrier} onChange={(e) => setCarrier(e.target.value)} /></label>
      <label className="stack" style={{ gap: 2 }}><span>Tracking reference</span><input className="input" value={tracking} onChange={(e) => setTracking(e.target.value)} /></label>
      {short && <Err m="You are sending fewer units than expected. Please say what is happening with the rest." />}
      <label className="stack" style={{ gap: 2 }}><span>Note{short ? ' (required)' : ' (optional)'}</span><input className="input" value={note} onChange={(e) => setNote(e.target.value)} /></label>
      {err && <Err m={err} />}
      <div className="row"><button className="btn primary" disabled={busy || carrier.trim().length < 2 || tracking.trim().length < 3 || (short && note.trim().length < 5)} onClick={() => void go()}>{busy ? 'Saving…' : 'Confirm shipped'}</button><button className="btn" onClick={onCancel}>Cancel</button></div>
    </div>
  );
}

function Messages({ job, onDone }: { job: PortalJob; onDone: () => Promise<void> }) {
  const [text, setText] = useState(''); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  async function send(e: FormEvent) { e.preventDefault(); setBusy(true); setErr(null); const r = await rpc('portal_message', { p_code: job.code, p_body: text }); setBusy(false); if (!r.ok) { setErr(r.error ?? 'That did not work.'); return; } setText(''); await onDone(); }
  return (
    <section className="stack" style={{ gap: 8 }}>
      <h2 style={{ margin: 0, fontSize: 16 }}>Messages with ATAM</h2>
      {job.messages.length === 0 ? <p className="dim">No messages yet. Ask a question here and we will reply on this job.</p> : <div className="stack" style={{ gap: 6 }}>{job.messages.map((m, i) => <div key={i} className="panel" style={{ padding: 10, marginLeft: m.side === 'producer' ? 32 : 0, marginRight: m.side === 'producer' ? 0 : 32 }}><div className="dim">{m.side === 'producer' ? 'You' : 'ATAM'} · {fmtTime(m.at)}</div><div>{m.body}</div></div>)}</div>}
      <form className="row" style={{ gap: 8 }} onSubmit={send}><input className="input grow" value={text} maxLength={2000} placeholder="Write a message" aria-label="Message" onChange={(e) => setText(e.target.value)} /><button className="btn primary" disabled={busy || !text.trim()}>Send</button></form>
      {err && <Err m={err} />}
    </section>
  );
}
