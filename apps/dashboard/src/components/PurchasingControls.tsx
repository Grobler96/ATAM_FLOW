import { useMemo, useState } from 'react';
import { Button, Facts, Skeleton, Status } from '../ui/primitives';
import { Modal, useToast } from '../ui/overlay';
import { useView } from '../data/store';
import { useCtx } from '../data/context';
import { exceptionActionTo } from '../lib/api';
import { money, shortDate } from '../lib/domain';
import { dateTime } from '../lib/format';
import { RESOLUTION_LABEL, RESOLVE_TEXT, approvalCheck, invoiceFormError, invoiceSentence, matchInfo, needsDecision, reasonOk, rulesFrom, type ResolveAction } from '../lib/purchasing';
import type { PoInvoiceRow, PoRow, SettingRow } from '../data/types';

// Purchasing controls on the PO drawer: approving a PO (with the rules visible), and recording and settling supplier invoices.
// The database enforces every rule; these screens explain them and show the database's own answer when it refuses.

export function ApprovePoDialog({ po, onClose, onDone }: { po: PoRow; onClose: () => void; onDone: () => void }) {
  const settings = useView<SettingRow>('ui_settings'); const { role } = useCtx(); const toast = useToast();
  const rules = useMemo(() => rulesFrom(settings.rows), [settings.rows]);
  const check = approvalCheck(rules, po.total_cost, role);
  const [reason, setReason] = useState(''); const [needsReason, setNeedsReason] = useState(false); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const go = async () => {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('purchasing', 'approve_po', { po_id: po.po_id, reason: reason.trim() || undefined });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); if (r.needs_reason === true) setNeedsReason(true); return; }
    toast.push({ tone: 'good', title: `${po.po_ref} approved`, body: 'You can now prepare the email to the supplier.' }); onDone();
  };
  return (
    <Modal open onClose={onClose} title={`Approve ${po.po_ref}`}>
      <div className="stack">
        <Facts items={[['Supplier', po.supplier ?? '—'], ['Total', money(po.total_cost, 2)], ['Lines', String(po.lines)], ['Units', po.units_ordered.toLocaleString('en-GB')]]} />
        <p style={{ margin: 0 }}>A purchase order must be approved before it can be emailed to the supplier. Approving it commits ATAM to buying these goods.</p>
        <div><b>Who can approve it</b>
          <ul className="dim" style={{ margin: '4px 0 0', paddingLeft: 18 }}>
            <li>A manager or admin can approve a PO worth up to {money(rules.approve_over_value, 2)}.</li>
            <li>Over {money(rules.approve_over_value, 2)}, only an admin can approve it.</li>
            {rules.no_self_approval && <li>The person who created a PO should not approve it. If that is you, only an admin can, and they must give a reason, which is recorded.</li>}
          </ul></div>
        {check.message && <div className="callout" role="alert">{check.message}</div>}
        <label className="field">{needsReason ? 'Reason (required)' : 'Reason (only needed if you created this PO)'}
          <textarea className="textarea" rows={3} value={reason} onChange={(e) => setReason(e.target.value)} placeholder={needsReason ? 'Why is it right for you to approve your own PO?' : ''} /></label>
        {err && <div className="callout" role="alert"><b>Not approved.</b> {err}</div>}
        <div className="row"><Button variant="primary" disabled={busy || check.blocked || (needsReason && !reasonOk(reason))} onClick={() => void go()}>{busy ? 'Approving…' : 'Approve PO'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

function RecordInvoiceDialog({ po, onClose, onDone }: { po: PoRow; onClose: () => void; onDone: () => void }) {
  const toast = useToast(); const [ref, setRef] = useState(''); const [date, setDate] = useState(''); const [net, setNet] = useState(''); const [vat, setVat] = useState(''); const [note, setNote] = useState(''); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const problem = invoiceFormError(ref, net, vat);
  const go = async () => {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('purchasing', 'invoice_record', { po_id: po.po_id, invoice_ref: ref.trim(), invoice_date: date || undefined, net_total: net, vat_total: vat === '' ? undefined : vat, note: note.trim() || undefined });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    const status = String(r.match_status ?? ''); const variance = Number(r.variance ?? 0);
    toast.push(status === 'matched' ? { tone: 'good', title: 'Invoice recorded', body: 'It matches what was received.' }
      : status === 'awaiting_goods' ? { tone: 'info', title: 'Invoice recorded', body: 'No goods are booked in yet, so it will be checked once they are.' }
      : { tone: 'info', title: 'Invoice recorded: it does not match', body: `${money(Math.abs(variance), 2)} ${variance > 0 ? 'more' : 'less'} than expected. Accept the difference or dispute it with the supplier.` });
    onDone();
  };
  return (
    <Modal open onClose={onClose} title={`Record an invoice for ${po.po_ref}`}>
      <div className="stack">
        <p className="dim" style={{ margin: 0 }}>Enter what the supplier billed. It is checked against the units actually received, at this PO's unit costs, plus any delivery charge.</p>
        <label className="field">Invoice number<input className="input" value={ref} onChange={(e) => setRef(e.target.value)} autoFocus /></label>
        <label className="field">Invoice date (optional)<input type="date" className="input" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <div className="row wrap" style={{ gap: 12 }}>
          <label className="field grow">Total before VAT (£)<input className="input" inputMode="decimal" value={net} onChange={(e) => setNet(e.target.value)} /></label>
          <label className="field grow">VAT (£, optional)<input className="input" inputMode="decimal" value={vat} onChange={(e) => setVat(e.target.value)} /></label></div>
        <label className="field">Note (optional)<textarea className="textarea" rows={2} value={note} onChange={(e) => setNote(e.target.value)} /></label>
        {err && <div className="callout" role="alert"><b>Not recorded.</b> {err}</div>}
        <div className="row"><Button variant="primary" disabled={busy || !!problem} title={problem ?? ''} onClick={() => void go()}>{busy ? 'Saving…' : 'Record invoice'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

function ResolveInvoiceDialog({ invoice, action, onClose, onDone }: { invoice: PoInvoiceRow; action: ResolveAction; onClose: () => void; onDone: () => void }) {
  const toast = useToast(); const t = RESOLVE_TEXT[action]; const [reason, setReason] = useState(''); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const go = async () => {
    setBusy(true); setErr(null);
    const r = await exceptionActionTo('purchasing', 'invoice_resolve', { invoice_id: invoice.id, resolution: action, reason: reason.trim() });
    setBusy(false);
    if (r.ok === false) { setErr(String(r.error ?? 'That did not work.')); return; }
    toast.push({ tone: 'good', title: action === 'accept' ? 'Difference accepted' : action === 'dispute' ? 'Marked as disputed' : 'Invoice reopened', body: 'Your reason is recorded.' }); onDone();
  };
  return (
    <Modal open onClose={onClose} title={`${t.title}: ${invoice.invoice_ref}`}>
      <div className="stack">
        <p style={{ margin: 0 }}>{invoiceSentence(invoice)}</p>
        <p className="dim" style={{ margin: 0 }}>{t.help}</p>
        <label className="field">Reason (required)<textarea className="textarea" rows={3} value={reason} onChange={(e) => setReason(e.target.value)} autoFocus /></label>
        {err && <div className="callout" role="alert"><b>Not saved.</b> {err}</div>}
        <div className="row"><Button variant={action === 'accept' ? 'primary' : ''} disabled={busy || !reasonOk(reason)} onClick={() => void go()}>{busy ? 'Saving…' : t.button}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}

export function PoInvoicesSection({ po }: { po: PoRow }) {
  const inv = useView<PoInvoiceRow>('ui_po_invoices'); const { senior } = useCtx();
  const [recording, setRecording] = useState(false); const [resolving, setResolving] = useState<{ invoice: PoInvoiceRow; action: ResolveAction } | null>(null);
  const mine = useMemo(() => inv.rows.filter((i) => i.po_id === po.po_id).sort((a, b) => b.created_at.localeCompare(a.created_at)), [inv.rows, po.po_id]);
  if (po.origin !== 'atam_flow') return null;   // invoices are matched against ATAM_FLOW POs only
  const status = po.po_status ?? '';
  const canRecord = senior && !['draft', 'cancelled', ''].includes(status);
  const done = () => { setRecording(false); setResolving(null); void inv.refresh(); };
  return (
    <section className="stack" aria-label="Supplier invoices">
      <div className="row wrap" style={{ justifyContent: 'space-between' }}><h3 style={{ margin: 0 }}>Supplier invoices{mine.length ? ` (${mine.length})` : ''}</h3>
        {canRecord && <Button size="sm" onClick={() => setRecording(true)}>Record invoice</Button>}</div>
      {inv.loading ? <Skeleton h={48} /> : inv.error ? <p className="dim">Could not load invoices: {inv.error}</p>
        : mine.length === 0 ? <p className="dim">{status === 'draft' ? 'Invoices can be recorded once the PO is approved.' : status === 'cancelled' ? 'This PO was cancelled.' : 'No invoice recorded yet.'}</p>
        : mine.map((i) => { const m = matchInfo(i.match_status); return (
          <div key={i.id} className="callout soft stack" style={{ gap: 6 }}>
            <div className="row wrap" style={{ gap: 10 }}><b className="mono">{i.invoice_ref}</b><Status tone={m.tone}>{m.label}</Status>{i.resolution && <Status tone={i.resolution === 'accepted' ? 'good' : 'medium'}>{RESOLUTION_LABEL[i.resolution]}</Status>}
              <span className="dim grow">{i.invoice_date ? shortDate(i.invoice_date) + ' · ' : ''}{money(i.net_total, 2)} before VAT{i.vat_total != null ? ` + ${money(i.vat_total, 2)} VAT` : ''}</span></div>
            <div>{invoiceSentence(i)}</div>
            {i.note && <div className="dim">Note: {i.note}</div>}
            {i.resolution && <div className="dim">{RESOLUTION_LABEL[i.resolution]} by {i.resolved_by ?? 'someone'}{i.resolved_at ? ` on ${dateTime(i.resolved_at)}` : ''}: {i.resolution_reason}</div>}
            {senior && needsDecision(i) && <div className="row wrap"><Button size="sm" variant="primary" onClick={() => setResolving({ invoice: i, action: 'accept' })}>Accept difference</Button><Button size="sm" onClick={() => setResolving({ invoice: i, action: 'dispute' })}>Dispute with supplier</Button></div>}
            {senior && i.resolution && <div className="row"><Button size="sm" variant="ghost" onClick={() => setResolving({ invoice: i, action: 'reopen' })}>Reopen</Button></div>}
          </div>); })}
      {recording && <RecordInvoiceDialog po={po} onClose={() => setRecording(false)} onDone={done} />}
      {resolving && <ResolveInvoiceDialog invoice={resolving.invoice} action={resolving.action} onClose={() => setResolving(null)} onDone={done} />}
    </section>
  );
}
