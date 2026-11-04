import { useEffect, useState } from 'react';
import { exceptionAction, loadHistory } from '../lib/api';
import { ACTION_LABEL, BLOCK_LABEL, dateTime, deadlineText, gbp, STATUS_LABEL } from '../lib/format';
import type { ExceptionRow, HistoryRow, Role } from '../types';

const STATUSES = ['open', 'investigating', 'awaiting_supplier', 'awaiting_producer', 'awaiting_customer'];
const METHODS: [string, string][] = [['fixed', 'Fixed'], ['replacement_received', 'Replacement received'], ['credit_issued', 'Credit issued'], ['rework_complete', 'Rework complete'],
  ['rerouted', 'Re-routed'], ['customer_agreed', 'Customer agreed new date'], ['supplier_resolved', 'Supplier resolved'], ['producer_resolved', 'Producer resolved'], ['no_action_needed', 'No action needed'], ['other', 'Other']];

type Panel = null | 'assign' | 'note' | 'resolve' | 'cancel' | 'write_off' | 'reopen';

interface Props { e: ExceptionRow; role: Role | null; me: string | null; canAct: boolean; onClose: () => void; onChanged: (msg: string) => Promise<void> }

export function DetailDrawer({ e, role, me, canAct, onClose, onChanged }: Props) {
  const [history, setHistory] = useState<HistoryRow[] | null>(null);
  const [histError, setHistError] = useState<string | null>(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [owner, setOwner] = useState(e.owner ?? me ?? '');
  const [note, setNote] = useState('');
  const [method, setMethod] = useState('fixed');
  const [amount, setAmount] = useState(e.financial_impact != null ? String(e.financial_impact) : '');
  const [isAction, setIsAction] = useState(true);
  const senior = role === 'admin' || role === 'manager';

  useEffect(() => {
    let alive = true; setHistory(null); setHistError(null);
    loadHistory(e.id).then((h) => alive && setHistory(h)).catch((x) => alive && setHistError(x instanceof Error ? x.message : 'Could not load history'));
    return () => { alive = false; };
  }, [e.id, e.status, e.owner, e.escalation_level]);
  useEffect(() => { const k = (ev: KeyboardEvent) => { if (ev.key === 'Escape') onClose(); }; window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k); }, [onClose]);

  async function run(action: string, params: Record<string, unknown>, okMessage: string) {
    setBusy(true); setError(null);
    const r = await exceptionAction(action, { exception_id: e.id, ...params });
    setBusy(false);
    if (r.ok === false) { setError(r.error ?? 'That did not work.'); return; }
    setPanel(null); setNote('');
    await onChanged(okMessage + (r.note ? ' ' + r.note : ''));
  }

  return (
    <div className="scrim" onClick={onClose}>
      <aside className="drawer" role="dialog" aria-modal="true" aria-label={`Issue ${e.exc_ref}`} onClick={(ev) => ev.stopPropagation()}>
        <div className="drawer-head">
          <div className="head-badges"><span className={`badge sev-${e.severity}`}>{e.severity}</span><span className="ref">{e.exc_ref}</span>
            {e.is_overdue && <span className="badge overdue">Overdue</span>}</div>
          <button className="btn small" onClick={onClose} aria-label="Close">Close</button>
        </div>
        <h2>{e.type_label}</h2>
        <p className="desc big">{e.description}</p>

        {e.recommended_action && <div className="callout"><b>Recommended action</b><p>{e.recommended_action}</p></div>}
        {e.customer_impact && <div className="callout soft"><b>Customer impact</b><p>{e.customer_impact}</p></div>}

        {canAct ? (
          <section className="act" aria-label="Actions">
            <h3>What would you like to do?</h3>
            <div className="btn-row">
              <button className="btn primary" onClick={() => { setPanel('assign'); setOwner(me ?? ''); }}>{e.owner ? 'Reassign' : 'Take it / assign'}</button>
              <select aria-label="Change status" value="" disabled={busy} onChange={(ev) => ev.target.value && void run('status', { status: ev.target.value }, 'Status updated.')}>
                <option value="">Set status…</option>{STATUSES.filter((s) => s !== e.status).map((s) => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
              </select>
              <button className="btn" onClick={() => setPanel('note')}>Add note / action taken</button>
              <button className="btn good" onClick={() => setPanel('resolve')}>Resolve</button>
              {senior && <button className="btn" onClick={() => setPanel('cancel')}>Not a real issue</button>}
              {senior && <button className="btn bad" onClick={() => setPanel('write_off')}>Write off</button>}
            </div>

            {panel === 'assign' && <Form title="Assign an owner" busy={busy} error={error} submit="Assign" onCancel={() => setPanel(null)}
              onSubmit={() => void run('assign', { owner, note: note || undefined }, 'Assigned.')} disabled={!owner.trim()}>
              <label>Owner (name or email)<input value={owner} onChange={(ev) => setOwner(ev.target.value)} /></label>
              <label>Note (optional)<input value={note} onChange={(ev) => setNote(ev.target.value)} /></label></Form>}
            {panel === 'note' && <Form title="Add to the record" busy={busy} error={error} submit="Save" onCancel={() => setPanel(null)}
              onSubmit={() => void run('note', { note, is_action: isAction }, 'Saved.')} disabled={!note.trim()}>
              <label>What happened?<textarea rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} placeholder="e.g. Phoned the supplier, replacement promised Friday" /></label>
              <label className="check"><input type="checkbox" checked={isAction} onChange={(ev) => setIsAction(ev.target.checked)} /> This is an action I took (not just a note)</label></Form>}
            {panel === 'resolve' && <Form title="Resolve" busy={busy} error={error} submit="Mark resolved" onCancel={() => setPanel(null)}
              onSubmit={() => void run('resolve', { method, note }, 'Resolved.')} disabled={!note.trim()}>
              <label>How was it resolved?<select value={method} onChange={(ev) => setMethod(ev.target.value)}>{METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
              <label>Note (required)<textarea rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} /></label>
              <p className="muted small">If the underlying problem is still there, the next check reopens this.</p></Form>}
            {panel === 'cancel' && <Form title="Not a real issue" busy={busy} error={error} submit="Cancel this issue" onCancel={() => setPanel(null)}
              onSubmit={() => void run('cancel', { reason: note }, 'Cancelled.')} disabled={!note.trim()}>
              <label>Why? (required)<textarea rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} /></label>
              <p className="muted small">It will not be raised again for 30 days.</p></Form>}
            {panel === 'write_off' && <Form title="Write off" busy={busy} error={error} submit="Write off" danger onCancel={() => setPanel(null)}
              onSubmit={() => void run('write_off', { reason: note, financial_impact: Number(amount) }, 'Written off.')} disabled={!note.trim() || amount.trim() === '' || isNaN(Number(amount))}>
              <label>Amount written off (£)<input inputMode="decimal" value={amount} onChange={(ev) => setAmount(ev.target.value)} /></label>
              <label>Reason (required)<textarea rows={3} value={note} onChange={(ev) => setNote(ev.target.value)} /></label></Form>}
            {panel === null && error && <div className="alert error" role="alert">{error}</div>}
          </section>
        ) : <p className="muted">You have view-only access.</p>}

        <dl className="facts">
          <div><dt>Status</dt><dd>{STATUS_LABEL[e.status] ?? e.status}</dd></div>
          <div><dt>Owner</dt><dd className={e.needs_owner ? 'warn' : ''}>{e.owner ?? `Nobody yet (${e.owner_role ?? 'unassigned'} is responsible)`}</dd></div>
          <div><dt>Respond by</dt><dd className={e.is_overdue ? 'bad' : ''}>{dateTime(e.response_deadline)} · {deadlineText(e.response_deadline, e.is_overdue)}</dd></div>
          <div><dt>Escalation</dt><dd>{e.escalation_level === 0 ? 'Not escalated' : `Level ${e.escalation_level}`}</dd></div>
          <div><dt>Detected</dt><dd>{dateTime(e.detected_at)} by {e.detected_by.replace('_', ' ')}</dd></div>
          {e.root_cause && <div><dt>Root cause</dt><dd>{e.root_cause.replace('_', ' ')}</dd></div>}
          <div><dt>Financial impact</dt><dd>{gbp(e.financial_impact)}{e.financial_breakdown && Object.keys(e.financial_breakdown).length > 0 && <span className="muted"> ({Object.entries(e.financial_breakdown).map(([k, v]) => `${k.replace(/_/g, ' ')} ${gbp(v)}`).join(', ')})</span>}</dd></div>
          {e.blocks.length > 0 && <div><dt>Blocks</dt><dd>{e.blocks.map((b) => BLOCK_LABEL[b] ?? b).join(', ')}</dd></div>}
        </dl>

        <Links label="Orders" items={e.order_refs} /><Links label="SKUs" items={e.skus} /><Links label="Purchase orders" items={e.po_refs} />
        <Links label="Producer movements" items={e.movement_refs} /><Links label="Producers" items={e.producers} />
        {e.communications > 0 && <p className="muted">{e.communications} linked email(s)</p>}

        <section aria-label="History"><h3>History</h3>
          {histError ? <p className="bad">Could not load history: {histError}</p> : !history ? <p className="muted">Loading…</p> :
            <ol className="timeline">{history.map((h, i) => (
              <li key={i}><div className="tl-top"><b>{ACTION_LABEL[h.action] ?? h.action}</b><span className="muted"> · {h.actor ?? 'system'} · {dateTime(h.at)}</span></div>
                {(h.from_status || h.to_status) && h.from_status !== h.to_status && <div className="muted small">{h.from_status ? STATUS_LABEL[h.from_status] ?? h.from_status : ''}{h.from_status && h.to_status ? ' → ' : ''}{h.to_status ? STATUS_LABEL[h.to_status] ?? h.to_status : ''}</div>}
                {h.note && <div>{h.note}</div>}</li>))}</ol>}
        </section>
      </aside>
    </div>
  );
}

function Links({ label, items }: { label: string; items: string[] }) {
  if (!items.length) return null;
  return <div className="links"><span className="muted">{label}</span><div className="chips-row">{items.map((i) => <span className="tag" key={i}>{i}</span>)}</div></div>;
}

function Form({ title, children, busy, error, submit, danger, disabled, onSubmit, onCancel }: {
  title: string; children: React.ReactNode; busy: boolean; error: string | null; submit: string; danger?: boolean; disabled?: boolean; onSubmit: () => void; onCancel: () => void }) {
  return (
    <form className="subform" onSubmit={(ev) => { ev.preventDefault(); if (!disabled && !busy) onSubmit(); }}>
      <h4>{title}</h4>{children}
      {error && <div className="alert error" role="alert">{error}</div>}
      <div className="btn-row"><button className={`btn ${danger ? 'bad' : 'primary'}`} disabled={disabled || busy}>{busy ? 'Saving…' : submit}</button><button type="button" className="btn" onClick={onCancel}>Back</button></div>
    </form>
  );
}
