import { useEffect, useRef, useState, type FormEvent } from 'react';

// One scanning panel for the staff app and the decorator portal. Three ways in, all giving the same text to `onScan`:
//   1. the camera (the browser's built-in reader where it has one, otherwise a decoder that is only downloaded when someone opens the camera),
//   2. a hardware scanner (it types the code and presses Enter, so the box below just works),
//   3. typing the code by hand.
interface Detector { detect: (v: HTMLVideoElement) => Promise<{ rawValue: string }[]> }
type DetectorCtor = new (o?: { formats?: string[] }) => Detector;
const nativeDetector = (): DetectorCtor | null => (typeof window !== 'undefined' ? (window as unknown as { BarcodeDetector?: DetectorCtor }).BarcodeDetector ?? null : null);
const FORMATS = ['qr_code', 'code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'data_matrix'];

export function ScanPanel({ onScan, onClose, hint }: { onScan: (text: string) => void; onClose: () => void; hint?: string }) {
  const video = useRef<HTMLVideoElement>(null); const stop = useRef<(() => void) | null>(null); const done = useRef(false);
  const [state, setState] = useState<'off' | 'starting' | 'on'>('off'); const [err, setErr] = useState<string | null>(null); const [text, setText] = useState('');
  const canCamera = typeof navigator !== 'undefined' && !!navigator.mediaDevices?.getUserMedia;

  const finish = (v: string) => { if (done.current) return; done.current = true; stop.current?.(); stop.current = null; onScan(v); };
  useEffect(() => () => { stop.current?.(); stop.current = null; }, []);

  async function startCamera() {
    setErr(null); setState('starting'); done.current = false;
    try {
      const Native = nativeDetector();
      if (Native) {
        const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false });
        const v = video.current; if (!v) { stream.getTracks().forEach((t) => t.stop()); return; }
        v.srcObject = stream; await v.play(); setState('on');
        const det = new Native({ formats: FORMATS }); let alive = true;
        const tick = async () => { if (!alive) return; try { const r = await det.detect(v); if (r[0]?.rawValue) { finish(r[0].rawValue); return; } } catch { /* a frame that cannot be read is skipped */ } setTimeout(tick, 200); };
        stop.current = () => { alive = false; stream.getTracks().forEach((t) => t.stop()); };
        void tick();
      } else {
        const { BrowserMultiFormatReader } = await import('@zxing/browser');
        const reader = new BrowserMultiFormatReader(); const v = video.current; if (!v) return;
        const controls = await reader.decodeFromConstraints({ video: { facingMode: { ideal: 'environment' } }, audio: false }, v, (result) => { if (result) finish(result.getText()); });
        stop.current = () => controls.stop(); setState('on');
      }
    } catch (e) {
      setState('off'); const name = (e as { name?: string })?.name;
      setErr(name === 'NotAllowedError' ? 'The camera is blocked. Allow camera access for this page in your browser, or type the code below.' : name === 'NotFoundError' ? 'No camera was found. Type the code below instead.' : 'The camera could not start. Type the code below instead.');
    }
  }
  function submit(e: FormEvent) { e.preventDefault(); const v = text.trim(); if (v) { setText(''); done.current = false; finish(v); } }   // a typed or hardware-scanned code always goes through

  return (
    <div className="stack" style={{ gap: 12 }}>
      {hint && <p className="muted">{hint}</p>}
      {canCamera && (
        <div className="stack" style={{ gap: 8 }}>
          <video ref={video} muted playsInline aria-label="Camera view" style={{ width: '100%', maxHeight: 300, background: '#000', borderRadius: 12, display: state === 'on' ? 'block' : 'none' }} />
          {state !== 'on' && <button type="button" className="btn primary" disabled={state === 'starting'} onClick={() => void startCamera()}>{state === 'starting' ? 'Starting the camera…' : 'Scan with the camera'}</button>}
        </div>)}
      {err && <div className="callout" role="alert">{err}</div>}
      <form className="row" style={{ gap: 8 }} onSubmit={submit}>
        <input className="input grow" autoFocus value={text} onChange={(e) => setText(e.target.value)} placeholder="Scan with a scanner, or type the code" aria-label="Scan or type a code" autoComplete="off" autoCapitalize="off" spellCheck={false} />
        <button className="btn primary" disabled={!text.trim()}>Go</button>
      </form>
      <div className="row"><button type="button" className="btn" onClick={onClose}>Close</button></div>
    </div>
  );
}

// A hardware scanner types very fast and finishes with Enter. Listen for that anywhere on the page, but never while someone is typing in a field.
export function useWedgeScanner(onScan: (text: string) => void, enabled = true) {
  const cb = useRef(onScan); cb.current = onScan;
  useEffect(() => {
    if (!enabled) return;
    let buf = ''; let last = 0;
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) { buf = ''; return; }
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const now = Date.now(); if (now - last > 80) buf = ''; last = now;
      if (e.key === 'Enter') { if (buf.length >= 5) { const v = buf; buf = ''; e.preventDefault(); cb.current(v); } else buf = ''; return; }
      if (e.key.length === 1) buf += e.key;
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [enabled]);
}
