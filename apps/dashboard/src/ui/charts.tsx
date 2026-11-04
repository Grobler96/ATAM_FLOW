// Small dependency-free SVG charts that read colours from the design tokens.
export function Sparkline({ data, w = 120, h = 32, tone = 'var(--accent)' }: { data: number[]; w?: number; h?: number; tone?: string }) {
  if (data.length < 2) return <svg width={w} height={h} aria-hidden="true" />;
  const max = Math.max(...data), min = Math.min(...data), span = max - min || 1;
  const pts = data.map((v, i) => `${(i / (data.length - 1)) * (w - 2) + 1},${h - 2 - ((v - min) / span) * (h - 4)}`);
  return <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} aria-hidden="true"><polyline points={pts.join(' ')} fill="none" stroke={tone} strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round" /><polygon points={`1,${h - 1} ${pts.join(' ')} ${w - 1},${h - 1}`} fill={tone} opacity="0.12" /></svg>;
}

export interface BarDatum { label: string; value: number; tone?: string; onClick?: () => void }
export function BarChart({ data, height = 170, unit = '' }: { data: BarDatum[]; height?: number; unit?: string }) {
  const max = Math.max(1, ...data.map((d) => d.value)), bw = 100 / Math.max(data.length, 1);
  return (
    <div role="img" aria-label={data.map((d) => `${d.label} ${d.value}${unit}`).join(', ')}>
      <svg width="100%" height={height} viewBox={`0 0 100 ${height}`} preserveAspectRatio="none">
        {[0.25, 0.5, 0.75, 1].map((g) => <line key={g} x1="0" x2="100" y1={(height - 22) * (1 - g) + 4} y2={(height - 22) * (1 - g) + 4} stroke="var(--border)" strokeWidth="0.3" vectorEffect="non-scaling-stroke" />)}
        {data.map((d, i) => { const bh = Math.max(d.value > 0 ? 2 : 0, (d.value / max) * (height - 26)); return <rect key={d.label} x={i * bw + bw * 0.18} y={height - 20 - bh} width={bw * 0.64} height={bh} rx="1.2" fill={d.tone ?? 'var(--accent)'} opacity="0.9" style={{ cursor: d.onClick ? 'pointer' : undefined }} onClick={d.onClick}><title>{`${d.label}: ${d.value}${unit}`}</title></rect>; })}
      </svg>
      <div className="row" style={{ justifyContent: 'space-between', gap: 0 }}>{data.map((d) => <span key={d.label} className="dim num" style={{ fontSize: 10.5, width: `${bw}%`, textAlign: 'center', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{d.label}</span>)}</div>
    </div>
  );
}

export function StackBar({ parts, height = 10 }: { parts: { label: string; value: number; tone: string }[]; height?: number }) {
  const total = parts.reduce((t, p) => t + p.value, 0) || 1;
  return <div role="img" aria-label={parts.map((p) => `${p.label} ${p.value}`).join(', ')} style={{ display: 'flex', height, borderRadius: 999, overflow: 'hidden', background: 'var(--neutral-soft)' }}>{parts.map((p) => p.value > 0 && <div key={p.label} title={`${p.label}: ${p.value}`} style={{ width: `${(p.value / total) * 100}%`, background: p.tone }} />)}</div>;
}

export function Heat({ rows, cols, cells, max }: { rows: string[]; cols: string[]; cells: number[][]; max?: number }) {
  const m = max ?? Math.max(1, ...cells.flat());
  return (
    <div style={{ display: 'grid', gridTemplateColumns: `90px repeat(${cols.length}, 1fr)`, gap: 3, fontSize: 11 }} role="img" aria-label="Heatmap">
      <span />{cols.map((c) => <span key={c} className="dim" style={{ textAlign: 'center' }}>{c}</span>)}
      {rows.map((r, i) => [<span key={r} className="muted" style={{ alignSelf: 'center' }}>{r}</span>, ...cols.map((c, j) => <div key={r + c} title={`${r} · ${c}: ${cells[i][j]}`} style={{ height: 26, borderRadius: 5, background: `rgba(79,141,255,${0.08 + 0.85 * (cells[i][j] / m)})`, display: 'grid', placeItems: 'center', color: cells[i][j] / m > 0.5 ? '#fff' : 'var(--text-2)' }}>{cells[i][j] || ''}</div>)])}
    </div>
  );
}
