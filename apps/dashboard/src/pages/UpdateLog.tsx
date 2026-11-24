import { useMemo, useState } from 'react';
import { Button, Chip, EmptyState, Field, Panel, Status, Tabs } from '../ui/primitives';
import { Modal, useToast } from '../ui/overlay';
import { useCtx } from '../data/context';
import { refreshAll, useView } from '../data/store';
import { supabase } from '../lib/api';
import { navigate, type Route } from '../router';
import { PLANNED, UPDATES, type UpdateEntry } from '../data/updatelog';
import { areasOf, dayWords, filterUpdates, IMPORTANCE_WORDS, isLiveSuggestion, isSuspect, newestFirst, rankSuggestions, STATUS_LABEL, STATUS_TONE, SUGGESTION_STATUS, suggestionsCsv, SUSPECT_DAYS, type SuggestionRow } from '../lib/updatelog';

// The Update log: a timeline of every change made to ATAM_FLOW, and the team's suggestions for what to build next, rated 1 to 5.
// The timeline is written into the code with each change (data/updatelog.ts). The suggestions live in the database.
const TABS = ['timeline', 'suggestions'] as const; type TabId = (typeof TABS)[number];
const row: React.CSSProperties = { padding: '10px 16px', borderBottom: '1px solid var(--border)' };

export function UpdateLogPage({ route }: { route: Route }) {
  const tab: TabId = route.path[1] === 'suggestions' ? 'suggestions' : 'timeline';
  const sug = useView<SuggestionRow>('ui_update_suggestions');
  const live = sug.rows.filter(isLiveSuggestion).length;
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>Update log</h1><p>{UPDATES.length} updates so far · {live} suggestion{live === 1 ? '' : 's'} on the board</p></div></div>
      <div className="callout soft">Every change made to ATAM_FLOW is added here as part of the same update, so if something stops working you can find roughly when it started and look at what changed just before. Anyone on the team can <b>suggest what to build next</b> and rate every suggestion from 1 (nice to have) to 5 (needed now). Changes made directly inside DecoNetwork, Xero or other systems by someone else are not tracked here.</div>
      <Tabs label="Update log sections" value={tab} tabs={[{ id: 'timeline', label: 'Timeline', count: UPDATES.length }, { id: 'suggestions', label: 'Suggestions', count: live }]} onChange={(t) => navigate(t === 'timeline' ? 'update-log' : 'update-log/suggestions')} />
      {tab === 'timeline' ? <Timeline /> : <Suggestions sug={sug} />}
    </div>
  );
}

function Timeline() {
  const [f, setF] = useState({ q: '', status: '', area: '', around: '' }); const [open, setOpen] = useState<Record<string, boolean>>({}); const [oldest, setOldest] = useState(false);
  const areas = useMemo(() => areasOf(UPDATES, PLANNED.flatMap((p) => p.areas)), []);
  const list = useMemo(() => { const l = filterUpdates(newestFirst(UPDATES), f); return oldest ? [...l].reverse() : l; }, [f, oldest]);
  const suspects = f.around ? UPDATES.filter((u) => isSuspect(u, f.around)) : [];
  const showPlanned = !f.around && (!f.status || f.status === 'planned');
  const planned = PLANNED.filter((p) => (!f.area || p.areas.includes(f.area)) && (!f.q || (p.title + ' ' + p.detail + ' ' + p.areas.join(' ')).toLowerCase().includes(f.q.trim().toLowerCase())));
  const counts = (s: UpdateEntry['status']) => UPDATES.filter((u) => u.status === s).length;
  return (
    <>
      <Panel title="Find an update" icon="search">
        <div className="stack" style={{ gap: 10 }}>
          <input className="input" type="search" value={f.q} onChange={(e) => setF({ ...f, q: e.target.value })} placeholder="Search updates (for example embroidery, purchasing, v30)" aria-label="Search updates" />
          <div className="row wrap" style={{ gap: 6 }} aria-label="Status"><Chip on={!f.status} onClick={() => setF({ ...f, status: '' })}>All</Chip>{(['live', 'partly', 'built'] as const).map((s) => <Chip key={s} on={f.status === s} count={counts(s)} onClick={() => setF({ ...f, status: s })}>{STATUS_LABEL[s]}</Chip>)}</div>
          <div className="row wrap" style={{ gap: 6 }} aria-label="Area"><Chip on={!f.area} onClick={() => setF({ ...f, area: '' })}>Every area</Chip>{areas.map((a) => <Chip key={a} on={f.area === a} onClick={() => setF({ ...f, area: a })}>{a}</Chip>)}</div>
          <div className="row wrap" style={{ gap: 10 }}><Button size="sm" onClick={() => setOldest(!oldest)}>{oldest ? '↑ Oldest first' : '↓ Newest first'}</Button>
            <label className="row" style={{ gap: 6 }}>Something broke? It started failing around <input className="input" type="date" value={f.around} onChange={(e) => setF({ ...f, around: e.target.value })} aria-label="Date it started failing" style={{ width: 160 }} /></label>
            {f.around && <Button size="sm" variant="ghost" onClick={() => setF({ ...f, around: '' })}>Clear</Button>}</div>
          {f.around && <div className="callout soft" role="status">{suspects.length ? <>Updates that went live in the {SUSPECT_DAYS} days up to {dayWords(f.around)}: {suspects.map((u) => <span key={u.v}><b>{u.v}</b> {u.title}. </span>)}These are the first places to look, not proof.</> : <>Nothing in this log went live in the {SUSPECT_DAYS} days up to {dayWords(f.around)}, so the cause is probably outside it (DecoNetwork, a supplier or something else).</>}</div>}
        </div>
      </Panel>
      {showPlanned && planned.length > 0 && <Panel title="Coming up" count={planned.length} icon="clock" flush>{planned.map((p) => <div key={p.title} style={row}><b>{p.title}</b> <span className="dim">{p.areas.join(' · ')}</span><div className="dim">{p.detail}</div></div>)}</Panel>}
      <Panel title="Timeline" count={`${list.length} of ${UPDATES.length}`} icon="orders" flush>
        {list.length === 0 ? <EmptyState icon="check" title="No updates match">Clear a filter or the search.</EmptyState> : list.map((u, i) => {
          const isOpen = open[u.v] ?? (i === 0 && !oldest && !f.q && !f.status && !f.area && !f.around); const sus = isSuspect(u, f.around);
          return (
            <div key={u.v} style={{ ...row, background: sus ? 'var(--high-soft, rgba(255,170,0,.10))' : undefined }} data-testid={`update-${u.v}`}>
              <button type="button" className="row wrap" aria-expanded={isOpen} onClick={() => setOpen({ ...open, [u.v]: !isOpen })} style={{ gap: 10, width: '100%', background: 'none', border: 0, color: 'inherit', textAlign: 'left', cursor: 'pointer', padding: 0 }}>
                <b className="mono" style={{ minWidth: 44 }}>{u.v}</b><span className="grow"><b>{u.title}</b>{sus && <em> · possible cause</em>}<span className="dim"> · {dayWords(u.date)}</span></span>
                <Status tone={STATUS_TONE[u.status]}>{STATUS_LABEL[u.status]}</Status><span aria-hidden>{isOpen ? '−' : '+'}</span></button>
              <div className="dim" style={{ marginTop: 4 }}>{u.summary}</div>
              <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>{u.areas.map((a) => <span key={a} className="tag">{a}</span>)}{u.timeTaken && <span className="dim">Took {u.timeTaken}</span>}</div>
              {isOpen && <div style={{ marginTop: 8 }}><b>What changed</b><ul style={{ margin: '4px 0 0', paddingLeft: 20 }}>{u.changes.map((c) => <li key={c}>{c}</li>)}</ul>{u.watch && <div style={{ marginTop: 8 }}><b>If something goes wrong</b><div className="dim">{u.watch}</div></div>}</div>}
            </div>);
        })}
      </Panel>
    </>
  );
}

async function call(fn: string, args: Record<string, unknown>): Promise<{ ok: boolean; error?: string }> {
  const { data, error } = await supabase.rpc(fn, args); const r = (data ?? {}) as { ok?: boolean; error?: string };
  return error ? { ok: false, error: error.message } : { ok: r.ok !== false, error: r.error };
}

function Suggestions({ sug }: { sug: ReturnType<typeof useView<SuggestionRow>> }) {
  const { senior, role } = useCtx(); const toast = useToast(); const [adding, setAdding] = useState(false); const [busy, setBusy] = useState<string | null>(null); const [showDone, setShowDone] = useState(false);
  const ranked = useMemo(() => rankSuggestions(sug.rows), [sug.rows]);
  const current = ranked.filter(isLiveSuggestion), done = ranked.filter((s) => !isLiveSuggestion(s));
  async function act(id: string, fn: string, args: Record<string, unknown>, okText: string) {
    setBusy(id); const r = await call(fn, args); setBusy(null);
    if (!r.ok) { toast.push({ tone: 'bad', title: 'Could not do that', body: r.error }); return; }
    toast.push({ tone: 'good', title: okText }); void sug.refresh(); void refreshAll();
  }
  function download() { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([suggestionsCsv(sug.rows)], { type: 'text/csv' })); a.download = 'atam-flow-suggestions.csv'; document.body.appendChild(a); a.click(); a.remove(); }
  const card = (s: SuggestionRow, rank: number | null) => (
    <div key={s.id} style={row} data-testid={`suggestion-${s.title}`}>
      <div className="row wrap" style={{ gap: 10 }}>
        {rank !== null && <b className="num" style={{ minWidth: 28 }}>#{rank}</b>}<b className="grow" style={{ minWidth: 200 }}>{s.title}</b>
        <Status tone={s.status === 'built' ? 'good' : s.status === 'planned' ? 'info' : s.status === 'declined' ? 'medium' : ''}>{SUGGESTION_STATUS[s.status]}</Status>
        <span className="num" title={`${s.votes} rating${s.votes === 1 ? '' : 's'}, average ${s.avg_importance ?? '–'}`}>{s.points} point{s.points === 1 ? '' : 's'}</span></div>
      {s.detail && <div className="dim" style={{ marginTop: 4, whiteSpace: 'pre-wrap' }}>{s.detail}</div>}
      <div className="row wrap" style={{ gap: 8, marginTop: 6 }}>
        {s.area && <span className="tag">{s.area}</span>}<span className="dim">Suggested by {s.suggested_by_name ?? 'someone'} · {dayWords(s.created_at)} · {s.votes} rating{s.votes === 1 ? '' : 's'}{s.avg_importance != null ? `, average ${s.avg_importance}` : ''}</span></div>
      <div className="row wrap" style={{ gap: 6, marginTop: 8 }} role="group" aria-label={`Your rating for ${s.title}`}>
        <span className="dim">Your rating:</span>
        {[1, 2, 3, 4, 5].map((n) => <button key={n} type="button" className={`chip ${s.my_rating === n ? 'on' : ''}`} aria-pressed={s.my_rating === n} disabled={busy === s.id} title={IMPORTANCE_WORDS[n]} onClick={() => void act(s.id, 'rate_update_suggestion', { p_id: s.id, p_importance: s.my_rating === n ? null : n }, s.my_rating === n ? 'Rating taken back' : 'Rating saved')}>{n}</button>)}
        {s.my_rating && <span className="dim">{IMPORTANCE_WORDS[s.my_rating]}</span>}
        <span className="grow" />
        {senior && <select className="input" aria-label={`Status of ${s.title}`} value={s.status} disabled={busy === s.id} onChange={(e) => void act(s.id, 'set_update_suggestion_status', { p_id: s.id, p_status: e.target.value }, 'Status changed')} style={{ width: 130 }}>{(Object.keys(SUGGESTION_STATUS) as SuggestionRow['status'][]).map((k) => <option key={k} value={k}>{SUGGESTION_STATUS[k]}</option>)}</select>}
        {s.mine && s.status === 'open' && <Button size="sm" variant="ghost" disabled={busy === s.id} onClick={() => { if (window.confirm('Take this suggestion back? It will be removed from the list.')) void act(s.id, 'withdraw_update_suggestion', { p_id: s.id }, 'Your suggestion was removed'); }}>Take my suggestion back</Button>}
      </div>
    </div>);
  return (
    <>
      <Panel title="Suggestions, ranked" count={current.length} icon="orders" flush actions={<span className="row" style={{ gap: 6 }}><Button size="sm" onClick={download} disabled={sug.rows.length === 0}>Download list</Button><Button variant="primary" size="sm" onClick={() => setAdding(true)} disabled={role === null}>Suggest an update</Button></span>}>
        {sug.loading ? <p className="dim" style={{ padding: 16, margin: 0 }}>Loading…</p> : sug.error ? <div style={{ padding: 16 }}><div className="callout" role="alert">Could not load the suggestions. Try again in a moment.</div><Button size="sm" onClick={() => void sug.refresh()}>Try again</Button></div>
          : current.length === 0 ? <EmptyState icon="check" title="No suggestions yet">Be the first to add one.</EmptyState> : current.map((s, i) => card(s, i + 1))}
      </Panel>
      {done.length > 0 && <Panel title="Already built or declined" count={done.length} icon="check" flush actions={<Button size="sm" onClick={() => setShowDone(!showDone)}>{showDone ? 'Hide' : 'Show'}</Button>}>{showDone ? done.map((s) => card(s, null)) : <p className="dim" style={{ padding: '8px 16px', margin: 0 }}>{done.length} suggestion{done.length === 1 ? '' : 's'} that are finished or were turned down.</p>}</Panel>}
      {adding && <AddSuggestion onClose={() => setAdding(false)} onDone={() => { setAdding(false); void sug.refresh(); void refreshAll(); }} />}
    </>
  );
}

function AddSuggestion({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const toast = useToast(); const [title, setTitle] = useState(''); const [detail, setDetail] = useState(''); const [area, setArea] = useState(''); const [imp, setImp] = useState(3); const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null);
  const areas = useMemo(() => areasOf(UPDATES), []);
  async function save() {
    if (title.trim().length < 3) { setErr('Give the suggestion a short title first.'); return; }
    setBusy(true); setErr(null); const r = await call('suggest_update', { p_title: title.trim(), p_detail: detail.trim(), p_area: area, p_importance: imp }); setBusy(false);
    if (!r.ok) { setErr(r.error ?? 'That did not work.'); return; }
    toast.push({ tone: 'good', title: 'Thanks, your suggestion is on the list' }); onDone();
  }
  return (
    <Modal open onClose={onClose} title="Suggest an update">
      <div className="stack">
        <Field label="What should we add or change?"><input className="input" value={title} maxLength={120} onChange={(e) => setTitle(e.target.value)} placeholder="For example A league table of late suppliers" /></Field>
        <Field label="Details (optional)"><textarea className="input" rows={4} value={detail} maxLength={1000} onChange={(e) => setDetail(e.target.value)} placeholder="Why it would help, and how you would use it" /></Field>
        <Field label="Which part of Flow is it about? (optional)"><select className="input" value={area} onChange={(e) => setArea(e.target.value)}><option value="">Not sure</option>{areas.map((a) => <option key={a} value={a}>{a}</option>)}</select></Field>
        <div className="stack" style={{ gap: 6 }} role="group" aria-label="How important is it"><b>How important is it?</b>
          <div className="row wrap" style={{ gap: 6 }}>{[1, 2, 3, 4, 5].map((n) => <button key={n} type="button" className={`chip ${imp === n ? 'on' : ''}`} aria-pressed={imp === n} onClick={() => setImp(n)}>{n}</button>)}<span className="dim">{IMPORTANCE_WORDS[imp]}</span></div></div>
        {err && <div className="callout" role="alert">{err}</div>}
        <div className="row"><Button variant="primary" disabled={busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Add suggestion'}</Button><Button variant="ghost" onClick={onClose}>Cancel</Button></div>
      </div>
    </Modal>
  );
}
