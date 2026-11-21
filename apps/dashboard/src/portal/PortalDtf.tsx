import { useCallback, useEffect, useMemo, useState } from 'react';
import { fmtDate, rpc, sb } from './client';
import { DTF_MARK, canFinish, canStart, downloadable, dtfWords, groupByOrder, orderSheet, uniqueFiles, type PortalDtfItem, type PortalDtfStatus } from './dtf';

// The decorator's DTF screen. ATAM sends no goods for DTF: the decorator buys the transfers from Super Print, so this page gives them the print files,
// an order sheet of how many of each design to order, and a place to say what is being printed and what is done.
const TONE: Record<PortalDtfStatus, string> = { required: 'var(--critical)', in_progress: 'var(--medium, #d99a00)', done: 'var(--good, #2e9d5b)' };
const Light = ({ s }: { s: PortalDtfStatus }) => <span className="chip on" style={{ cursor: 'default', color: TONE[s] }}><span aria-hidden="true">{DTF_MARK[s]} </span>{dtfWords(s)}</span>;

async function download(files: { file: string; name: string }[]): Promise<number> {
  let failed = 0;
  for (const f of files) {
    const { data, error } = await sb.storage.from('artwork').createSignedUrl(f.file, 300, { download: f.name });
    if (error || !data?.signedUrl) { failed++; continue; }
    const a = document.createElement('a'); a.href = data.signedUrl; a.download = f.name; document.body.appendChild(a); a.click(); a.remove();
    await new Promise((r) => setTimeout(r, 250)); // browsers drop downloads started in the same instant
  }
  return failed;
}

export function PortalDtf() {
  const [items, setItems] = useState<PortalDtfItem[] | null>(null); const [err, setErr] = useState<string | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set()); const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null); const [askStart, setAskStart] = useState<string[] | null>(null);
  const load = useCallback(async () => { const r = await rpc<{ items: PortalDtfItem[] }>('portal_dtf'); if (r.ok) { setItems(r.data?.items ?? []); setErr(null); } else setErr(r.error ?? 'Could not load your DTF prints.'); }, []);
  useEffect(() => { void load(); }, [load]);
  const groups = useMemo(() => groupByOrder(items ?? []), [items]);
  const chosen = useMemo(() => (items ?? []).filter((i) => picked.has(i.order_ref)), [items, picked]);
  const sheetItems = chosen.length ? chosen : (items ?? []).filter((i) => i.status !== 'done');
  const sheet = useMemo(() => orderSheet(sheetItems), [sheetItems]);
  if (err) return <div className="stack"><a href="#/">← Your work</a><div className="callout" role="alert">{err}</div></div>;
  if (!items) return <p className="dim">Loading your DTF prints…</p>;

  const toggle = (ref: string) => setPicked((p) => { const n = new Set(p); if (n.has(ref)) n.delete(ref); else n.add(ref); return n; });
  async function setStatus(fn: 'portal_dtf_start' | 'portal_dtf_done', ids: string[], done: string) {
    setBusy(true); setMsg(null); const r = await rpc(fn, { p_item_ids: ids }); setBusy(false); setAskStart(null);
    if (!r.ok) { setMsg(r.error ?? 'That did not save. Try again.'); return; }
    setMsg(done); await load();
  }
  async function getFiles() {
    const ready = downloadable(chosen); const files = uniqueFiles(ready); const skipped = chosen.length - ready.length;
    if (!files.length) { setMsg('None of the selected prints has a file ready yet. Message us and we will sort it out.'); return; }
    setBusy(true); setMsg(null); const failed = await download(files); setBusy(false);
    const notes = [failed ? `${failed} file${failed === 1 ? '' : 's'} could not be downloaded. Try again, or message us.` : '', skipped ? `${skipped} placement${skipped === 1 ? ' has' : 's have'} no file ready yet — message us about ${skipped === 1 ? 'it' : 'them'}.` : ''].filter(Boolean);
    setMsg(notes.length ? notes.join(' ') : `Downloaded ${files.length} file${files.length === 1 ? '' : 's'}.`);
    const toStart = canStart(ready).map((i) => i.id); if (toStart.length && failed < files.length) setAskStart(toStart);
  }
  const finishable = canFinish(chosen).map((i) => i.id);

  return (
    <div className="stack" style={{ gap: 16 }}>
      <a href="#/" className="no-print">← Your work</a>
      <h1 style={{ margin: 0 }}>DTF prints</h1>
      <div className="callout no-print" role="note">You order the DTF transfers from Super Print yourselves. Tick the orders you are doing, download their print files, and use the order sheet to see how many of each design you need.</div>
      {items.length === 0 && <div className="callout" role="status">No DTF prints for you right now. They appear here once an order with DTF is assigned to you.</div>}
      {items.length > 0 && <>
        <div className="row wrap no-print" style={{ gap: 8, position: 'sticky', top: 0, background: 'var(--bg, #fff)', padding: '6px 0', zIndex: 2 }}>
          <button className="btn" onClick={() => setPicked(picked.size === groups.length ? new Set() : new Set(groups.map((g) => g.order_ref)))}>{picked.size === groups.length ? 'Clear ticks' : 'Tick all orders'}</button>
          <button className="btn primary" disabled={!chosen.length || busy} onClick={() => void getFiles()}>Download files{chosen.length ? ` (${picked.size} order${picked.size === 1 ? '' : 's'})` : ''}</button>
          <button className="btn" disabled={!finishable.length || busy} onClick={() => void setStatus('portal_dtf_done', finishable, `Marked ${finishable.length} print${finishable.length === 1 ? '' : 's'} as produced.`)}>Mark selected as produced</button>
        </div>
        {msg && <div className="callout" role="status" data-testid="dtf-msg">{msg}</div>}
        {askStart && <div className="callout" role="alert" data-testid="dtf-ask"><b>Files downloaded.</b> Have you started printing these? ATAM will see them as “Prints in production”.
          <div className="row" style={{ gap: 8, marginTop: 8 }}><button className="btn primary" disabled={busy} onClick={() => void setStatus('portal_dtf_start', askStart, 'Marked as in production.')}>Mark as in production</button><button className="btn" onClick={() => setAskStart(null)}>Not yet</button></div></div>}
        <section className="stack no-print" style={{ gap: 10 }} aria-label="Orders with DTF">
          {groups.map((g) => (
            <div key={g.order_ref} className="panel stack" style={{ padding: 14, gap: 8 }}>
              <label className="row wrap" style={{ gap: 10, cursor: 'pointer' }}><input type="checkbox" checked={picked.has(g.order_ref)} onChange={() => toggle(g.order_ref)} aria-label={`Select ${g.order_ref}`} /><b>{g.order_ref}</b>{g.customer && <span>{g.customer}</span>}<span className="grow" /><span className="dim">Due {fmtDate(g.due_date)}</span><Light s={g.status} /></label>
              {g.items.map((i) => (
                <div key={i.id} className="row wrap" style={{ gap: 10, alignItems: 'center' }}>
                  {i.thumbnail_url ? <img src={i.thumbnail_url} alt="" width={44} height={44} style={{ objectFit: 'contain', background: '#eee', borderRadius: 4 }} /> : <span style={{ width: 44, height: 44, background: '#eee', borderRadius: 4 }} aria-hidden="true" />}
                  <div className="grow"><div>{i.area} · {i.product ?? 'Garment'} · <b>{i.qty}</b></div>{!i.file && <div className="warn">No file ready yet — message us.</div>}</div>
                  <Light s={i.status} />
                  {i.status !== 'done' && <button className="btn" disabled={busy} onClick={() => void setStatus('portal_dtf_done', [i.id], `Marked ${i.area} on ${i.order_ref} as produced.`)}>Mark produced</button>}
                </div>))}
            </div>))}
        </section>
        <section className="panel stack" style={{ padding: 14, gap: 8 }} aria-label="Order sheet" data-testid="dtf-sheet">
          <div className="row wrap" style={{ justifyContent: 'space-between' }}><h2 style={{ margin: 0, fontSize: 16 }}>Order sheet{chosen.length ? ' (ticked orders)' : ' (everything still to make)'}</h2><button className="btn no-print" onClick={() => window.print()}>Print this sheet</button></div>
          {sheet.length === 0 ? <p className="dim">Nothing left to make.</p> : (
            <table style={{ width: '100%', borderCollapse: 'collapse' }}><thead><tr style={{ textAlign: 'left' }}><th>Design</th><th>File</th><th>Garments</th><th>Still to make</th><th>Orders</th></tr></thead>
              <tbody>{sheet.map((l) => (
                <tr key={l.key}>
                  <td style={{ padding: '6px 4px' }}>{l.thumbnail_url ? <img src={l.thumbnail_url} alt="" width={40} height={40} style={{ objectFit: 'contain', background: '#eee', borderRadius: 4, verticalAlign: 'middle' }} /> : null} {l.label}</td>
                  <td>{l.hasFile ? l.file_name : <span className="warn">No file yet</span>}</td><td>{l.qty}</td><td><b>{l.outstanding}</b></td><td>{l.orders.join(', ')}</td>
                </tr>))}</tbody></table>)}
        </section>
      </>}
    </div>
  );
}
