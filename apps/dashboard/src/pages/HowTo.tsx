import { useEffect, useMemo, useState } from 'react';
import { Chip, EmptyState, Field, Panel, Button } from '../ui/primitives';
import { Drawer } from '../ui/overlay';
import { supabase } from '../lib/api';
import { TUTORIAL_BUCKET } from '../config';
import { navigate, type Route } from '../router';
import { COMING_SOON, filterHowTo, HOWTO, lengthText, posterUrl, sectionsOf, videoPath, type HowTo } from '../lib/howto';

// How-to videos: short, friendly videos showing how to do things in ATAM_FLOW. Pick one to watch it, with the same steps written out underneath.
// The videos are made with the project in video/ (made-up sample data only) and stored in a private Storage bucket.
export function HowToPage({ route }: { route: Route }) {
  const [f, setF] = useState({ q: '', section: '' });
  const open = HOWTO.find((t) => t.id === route.path[1]);
  const list = useMemo(() => filterHowTo(HOWTO, f), [f]);
  return (
    <div className="stack" style={{ gap: 16 }}>
      <div className="page-head"><div><h1>How-to videos</h1><p>{HOWTO.length} short video{HOWTO.length === 1 ? '' : 's'} so far, more on the way</p></div></div>
      <div className="callout soft">Pick a video to see how something is done. Each one uses made-up sample data, so what you see is the real screen but never a real customer. The steps are written out under every video.</div>
      <Panel title="Find a video" icon="search">
        <div className="stack" style={{ gap: 10 }}>
          <Field label="Search"><input type="search" value={f.q} placeholder="Try: purchase order, labels, search…" onChange={(e) => setF({ ...f, q: e.target.value })} /></Field>
          <div className="row wrap" style={{ gap: 6 }} role="group" aria-label="Topics">
            <Chip on={!f.section} onClick={() => setF({ ...f, section: '' })}>All</Chip>
            {sectionsOf(HOWTO).map((s) => <Chip key={s} on={f.section === s} onClick={() => setF({ ...f, section: f.section === s ? '' : s })}>{s}</Chip>)}
          </div>
        </div>
      </Panel>
      {list.length === 0 ? <EmptyState icon="search" title="No video matches that">Try a different word, or clear the topic.</EmptyState>
        : <div className="howto-grid">{list.map((t) => (
          <button key={t.id} className="howto-card" onClick={() => navigate('howto/' + t.id)} aria-label={`Watch: ${t.title}`}>
            <span className="howto-thumb"><img src={posterUrl(t.id)} alt="" loading="lazy" /><span className="howto-len">{lengthText(t.seconds)}</span></span>
            <span className="howto-body"><span className="howto-meta"><span>{t.section}</span><span>{t.level}</span></span><b>{t.title}</b><span className="muted">{t.summary}</span></span>
          </button>))}</div>}
      <Panel title="On the list" icon="clock">
        <p className="muted" style={{ marginTop: 0 }}>These videos are planned but not made yet.</p>
        <div className="stack" style={{ gap: 10 }}>{COMING_SOON.map((g) => <div key={g.section}><b>{g.section}</b><div className="row wrap" style={{ gap: 6, marginTop: 4 }}>{g.titles.map((x) => <span key={x} className="tag">{x}</span>)}</div></div>)}</div>
      </Panel>
      {open && <VideoDrawer t={open} onClose={() => navigate('howto')} />}
    </div>
  );
}

type Link = { state: 'loading' } | { state: 'ready'; url: string } | { state: 'missing' };
function useVideoLink(id: string): Link {
  const [link, setLink] = useState<Link>({ state: 'loading' });
  useEffect(() => {
    let live = true; setLink({ state: 'loading' });
    supabase.storage.from(TUTORIAL_BUCKET).createSignedUrl(videoPath(id), 3600).then(({ data, error }) => { if (live) setLink(error || !data?.signedUrl ? { state: 'missing' } : { state: 'ready', url: data.signedUrl }); }, () => { if (live) setLink({ state: 'missing' }); });
    return () => { live = false; };
  }, [id]);
  return link;
}

function VideoDrawer({ t, onClose }: { t: HowTo; onClose: () => void }) {
  const link = useVideoLink(t.id);
  return (
    <Drawer open onClose={onClose} wide title={t.title} subtitle={`${t.section} · for ${t.level.toLowerCase()} · ${lengthText(t.seconds)}`}>
      <div className="stack" style={{ gap: 16 }}>
        {link.state === 'ready' ? <video className="howto-video" controls preload="metadata" poster={posterUrl(t.id)} src={link.url} aria-label={t.title} />
          : <div className="howto-video howto-wait" role="status">{link.state === 'loading' ? 'Loading the video…' : 'This video is not available to watch yet. The steps below cover the same ground.'}</div>}
        <div className="row wrap" style={{ gap: 8 }}><Button variant="primary" onClick={() => navigate(t.page)}>Open {t.pageLabel}</Button><span className="muted">Try it yourself on the real page.</span></div>
        <Panel title="The steps, written out" icon="check"><ol className="howto-steps">{t.steps.map((s, i) => <li key={i}>{s}</li>)}</ol></Panel>
      </div>
    </Drawer>
  );
}
