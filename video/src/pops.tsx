import React from "react";
import { interpolate, random, spring } from "remotion";
import { C, FONT, FPS, H, W, WIN } from "./theme";
import type { Pop, Rect } from "./types";

const TONE: Record<string, string> = { yellow: C.yellow, teal: C.teal, pink: C.pink, blue: "#8fb5ff" };
const LIFE: Record<string, number> = { sticker: 3.6, ring: 3.4, arrow: 3.4, keys: 3.8, stamp: 2.4, confetti: 2.8, zoom: 0 };
const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
const bounce = (life: number, damping = 9, stiffness = 190) => spring({ frame: life * FPS, fps: FPS, config: { damping, stiffness, mass: 0.6 } });
const fade = (life: number, dur: number) => interpolate(life, [dur - 0.3, dur], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

export const popLife = (p: Pop) => LIFE[p.kind] ?? 3;

const Sticker: React.FC<{ p: Pop; life: number; cx: number; cy: number; i: number }> = ({ p, life, cx, cy, i }) => {
  const s = bounce(life), rot = (random(`rot${p.t}${i}`) - 0.5) * 12 + Math.sin(life * 7) * 2.2;
  return (
    <div style={{ position: "absolute", left: cx, top: cy, transform: `translate(-50%,-50%) rotate(${rot}deg) scale(${s})`, opacity: fade(life, LIFE.sticker), fontFamily: FONT }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "12px 28px 12px 20px", background: TONE[p.tone ?? "yellow"], border: `6px solid ${C.ink}`, borderRadius: 34, boxShadow: `9px 9px 0 ${C.ink}`, color: C.ink, fontWeight: 700, fontSize: 48, whiteSpace: "nowrap" }}>
        {p.icon && <span style={{ fontSize: 58, lineHeight: 1 }}>{p.icon}</span>}<span>{p.text}</span>
      </div>
    </div>
  );
};

const Ring: React.FC<{ r: Rect; life: number; dur: number }> = ({ r, life, dur }) => {
  const pad = 14, w = r.w + pad * 2, h = r.h + pad * 2, per = 2 * (w + h);
  const draw = interpolate(life, [0, 0.55], [0, 1], { extrapolateRight: "clamp" }), pulse = 1 + Math.sin(life * 7) * 0.008;
  const corners: [number, number][] = [[0, 0], [w, 0], [w, h], [0, h]];
  return (
    <div style={{ position: "absolute", left: r.x - pad, top: r.y - pad, width: w, height: h, opacity: fade(life, dur), transform: `scale(${pulse})` }}>
      <svg width={w} height={h} style={{ overflow: "visible" }}>
        <rect x="0" y="0" width={w} height={h} rx="22" fill="none" stroke={C.ink} strokeWidth="14" strokeDasharray={per} strokeDashoffset={per * (1 - draw)} />
        <rect x="0" y="0" width={w} height={h} rx="22" fill="none" stroke={C.yellow} strokeWidth="7" strokeDasharray={per} strokeDashoffset={per * (1 - draw)} style={{ filter: `drop-shadow(0 0 14px ${C.yellow})` }} />
        {corners.map(([x, y], k) => { const sc = clamp(Math.sin(life * 8 + k * 1.7) * 0.5 + 0.8, 0, 1.2) * bounce(life - 0.4 - k * 0.07); return <path key={k} transform={`translate(${x},${y}) scale(${sc * 1.6})`} d="M0-14l4 10 10 4-10 4-4 10-4-10-10-4 10-4z" fill={C.yellow} stroke={C.ink} strokeWidth="2.5" strokeLinejoin="round" />; })}
      </svg>
    </div>
  );
};

const Arrow: React.FC<{ p: Pop; r: Rect; life: number; i: number }> = ({ p, r, life, i }) => {
  const from = p.from ?? "bottom-right", right = from.includes("right"), bottom = from.includes("bottom");
  const tx = r.x + r.w * (right ? 0.72 : 0.28), ty = bottom ? r.y + r.h + 10 : r.y - 10;
  const sx = clamp(tx + (right ? 230 : -230), 150, W - 150), sy = clamp(ty + (bottom ? 170 : -170), 110, H - 190);
  const d = `M${sx} ${sy} Q${sx} ${ty} ${tx} ${ty}`;
  const draw = interpolate(life, [0.05, 0.6], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }), ang = sx > tx ? 180 : 0;
  const head = bounce(life - 0.5, 10, 200), o = fade(life, LIFE.arrow);
  return (
    <div style={{ position: "absolute", inset: 0, opacity: o }}>
      <svg width={W} height={H} style={{ position: "absolute", inset: 0, overflow: "visible" }}>
        <path d={d} pathLength={1} fill="none" stroke={C.ink} strokeWidth="18" strokeLinecap="round" strokeDasharray="1" strokeDashoffset={1 - draw} />
        <path d={d} pathLength={1} fill="none" stroke={C.yellow} strokeWidth="9" strokeLinecap="round" strokeDasharray="1" strokeDashoffset={1 - draw} />
        <g transform={`translate(${tx},${ty}) rotate(${ang}) scale(${head})`}><path d="M10 0L-26 -24L-18 0L-26 24z" fill={C.yellow} stroke={C.ink} strokeWidth="8" strokeLinejoin="round" /></g>
      </svg>
      {p.text && <Sticker p={{ ...p, kind: "sticker", tone: "pink" }} life={life} cx={sx + (right ? 40 : -40)} cy={sy + (bottom ? 56 : -56)} i={i} />}
    </div>
  );
};

const Keys: React.FC<{ p: Pop; life: number }> = ({ p, life }) => {
  const [ax, ay] = p.at ?? [0.5, 0.2], keys = p.keys ?? [];
  return (
    <div style={{ position: "absolute", left: ax * W, top: ay * H, transform: "translate(-50%,-50%)", display: "flex", gap: 18, alignItems: "center", opacity: fade(life, LIFE.keys), fontFamily: FONT }}>
      {keys.map((k, i) => {
        const s = bounce(life - i * 0.12, 8, 200), isWord = k === "or", press = interpolate(life - (0.7 + i * 0.5), [0, 0.1, 0.28], [0, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
        return isWord ? <span key={i} style={{ fontSize: 40, fontWeight: 600, color: "#fff", WebkitTextStroke: `8px ${C.ink}`, paintOrder: "stroke fill", transform: `scale(${s})` }}>{k}</span> : (
          <div key={i} style={{ minWidth: 112, height: 112, padding: "0 22px", display: "grid", placeItems: "center", background: "#f4f6ff", border: `6px solid ${C.ink}`, borderRadius: 26, boxShadow: `0 ${12 - press * 8}px 0 ${C.ink}`, transform: `translateY(${press * 8}px) scale(${s}) rotate(${(i - 1.5) * 3}deg)`, color: C.ink, fontWeight: 700, fontSize: k.length > 1 ? 44 : 62 }}>{k}</div>
        );
      })}
    </div>
  );
};

const Stamp: React.FC<{ p: Pop; life: number }> = ({ p, life }) => {
  const s = spring({ frame: life * FPS, fps: FPS, config: { damping: 11, stiffness: 240, mass: 0.7 } }), sc = interpolate(s, [0, 1], [3.4, 1]);
  const shake = life < 0.5 ? Math.sin(life * 90) * (0.5 - life) * 14 : 0;
  return (
    <div style={{ position: "absolute", left: W * 0.69 + shake, top: H * 0.74, transform: `translate(-50%,-50%) rotate(-9deg) scale(${sc})`, opacity: Math.min(1, s * 2) * fade(life, LIFE.stamp), fontFamily: FONT }}>
      <div style={{ padding: "10px 52px", border: `12px double ${C.good}`, borderRadius: 30, color: C.good, background: "rgba(6,10,19,.78)", fontWeight: 700, fontSize: 92, letterSpacing: 4, boxShadow: `10px 10px 0 ${C.ink}`, WebkitTextStroke: `3px ${C.ink}` }}>{p.text}</div>
    </div>
  );
};

export const Confetti: React.FC<{ life: number; ox?: number; oy?: number; seed?: string; count?: number }> = ({ life, ox = W / 2, oy = H * 0.78, seed = "c", count = 60 }) => {
  const cols = [C.yellow, C.pink, C.teal, C.blue, C.good, "#fff"];
  return (
    <div style={{ position: "absolute", inset: 0, overflow: "hidden", pointerEvents: "none" }}>
      {Array.from({ length: count }, (_, i) => {
        const a = -Math.PI / 2 + (random(`${seed}a${i}`) - 0.5) * 2.0, sp = 700 + random(`${seed}s${i}`) * 900;
        const x = ox + Math.cos(a) * sp * life, y = oy + Math.sin(a) * sp * life + 0.5 * 1900 * life * life;
        const size = 14 + random(`${seed}z${i}`) * 16, circle = i % 3 === 0;
        return <div key={i} style={{ position: "absolute", left: x, top: y, width: size, height: circle ? size : size * 0.55, borderRadius: circle ? "50%" : 3, background: cols[i % cols.length], border: `2px solid ${C.ink}`, transform: `rotate(${life * (300 + random(`${seed}r${i}`) * 600)}deg)`, opacity: interpolate(life, [1.9, 2.7], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) }} />;
      })}
    </div>
  );
};

export const PopView: React.FC<{ p: Pop; t: number; i: number; toScreen: (r: Rect) => Rect; rects: Record<string, Rect>; stepEnd: number }> = ({ p, t, i, toScreen, rects, stepEnd }) => {
  const life = t - p.t, dur = Math.max(1.2, p.kind === "ring" ? stepEnd - p.t + 0.2 : Math.min(popLife(p), stepEnd - p.t + 0.2));   // a ring stays for the rest of its step; nothing outlives its step
  if (life < 0 || life > dur || p.kind === "zoom") return null;
  const r = p.rect && rects[p.rect] ? toScreen(rects[p.rect]) : null;
  if (p.kind === "confetti") return <Confetti life={life} seed={`c${p.t}`} />;
  if (p.kind === "ring" && r) {   // keep the ring inside the window so it never runs over the badges
    const x0 = Math.max(r.x, WIN.x + 16), y0 = Math.max(r.y, WIN.y + 16), x1 = Math.min(r.x + r.w, WIN.x + WIN.w - 16), y1 = Math.min(r.y + r.h, WIN.y + WIN.h - 16);
    return <Ring r={{ x: x0, y: y0, w: Math.max(40, x1 - x0), h: Math.max(40, y1 - y0) }} life={life} dur={dur} />;
  }
  if (p.kind === "arrow" && r) return <Arrow p={p} r={r} life={life} i={i} />;
  if (p.kind === "keys") return <Keys p={p} life={life} />;
  if (p.kind === "stamp") return <Stamp p={p} life={life} />;
  if (p.kind === "sticker") {
    let cx = (p.at?.[0] ?? 0.5) * W, cy = (p.at?.[1] ?? 0.3) * H;
    if (r) { const c = p.corner ?? "tr"; cx = c.includes("r") ? r.x + r.w - 40 : r.x + 40; cy = c.includes("t") ? r.y - 6 : r.y + r.h + 6; }
    return <Sticker p={p} life={life} cx={clamp(cx, 190, W - 190)} cy={clamp(cy, 90, H - 200)} i={i} />;
  }
  return null;
};
