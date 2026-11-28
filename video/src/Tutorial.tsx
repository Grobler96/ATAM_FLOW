import React from "react";
import { AbsoluteFill, Audio, Img, interpolate, spring, staticFile, useCurrentFrame } from "remotion";
import tutorials from "./tutorials.json";
import timingAll from "./timing.json";
import shotsAll from "./shots.json";
import { Background, Mascot } from "./art";
import { Confetti, PopView, popLife } from "./pops";
import { C, FONT, FPS, H, W, WIN } from "./theme";
import type { Cam, Pop, Rect, ShotInfo, Timing } from "./types";

const shots = shotsAll as unknown as Record<string, ShotInfo>;
const FULL: Cam = { s: 1, tx: 0, ty: 0 };
const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));

function camFor(r: Rect | null): Cam {
  if (!r) return FULL;
  const mw = Math.max(r.w, 0.24), mh = Math.max(r.h, 0.17), rx = r.x + r.w / 2 - mw / 2, ry = r.y + r.h / 2 - mh / 2;   // small targets still get a window of context
  const x = rx - 0.025, y = ry - 0.04, w = mw + 0.05, h = mh + 0.08;
  const s = clamp(Math.min(1 / w, 1 / h), 1, 1.75), cx = x + w / 2, cy = y + h / 2;
  return { s, tx: clamp(WIN.w / 2 - cx * WIN.w * s, WIN.w - WIN.w * s, 0), ty: clamp(WIN.h / 2 - cy * WIN.h * s, WIN.h - WIN.h * s, 0) };
}

export const Tutorial: React.FC<{ id: string }> = ({ id }) => {
  const frame = useCurrentFrame(), t = frame / FPS;
  const meta = tutorials.find((x) => x.id === id)!, tm = (timingAll as unknown as Record<string, Timing>)[id];
  const steps = tm.steps, n = steps.length;

  // camera keyframes: one per step (zoom target or the whole screen), plus any explicit zoom pop-ups
  type KF = { t: number; cam: Cam; fresh: boolean };
  const kfs: KF[] = [];
  steps.forEach((s, i) => {
    const rects = shots[s.shot].rects, fresh = i === 0 || steps[i - 1].shot !== s.shot;
    kfs.push({ t: s.start + 0.12, cam: camFor(s.zoom ? rects[s.zoom] : null), fresh });
    s.pops.filter((p) => p.kind === "zoom" && p.rect).forEach((p) => kfs.push({ t: p.t, cam: camFor(rects[p.rect!]), fresh: false }));
  });
  const camAt = (tt: number): Cam => {
    let k = -1; kfs.forEach((x, i) => { if (x.t <= tt) k = i; });
    if (k < 0) return FULL;
    const prev = kfs[k].fresh || k === 0 ? FULL : kfs[k - 1].cam, to = kfs[k].cam;
    const p = spring({ frame: (tt - kfs[k].t) * FPS, fps: FPS, config: { damping: 15, stiffness: 110, mass: 0.7 } });
    return { s: prev.s + (to.s - prev.s) * p, tx: prev.tx + (to.tx - prev.tx) * p, ty: prev.ty + (to.ty - prev.ty) * p };
  };

  let si = -1; steps.forEach((s, i) => { if (t >= s.start) si = i; });
  const step = si >= 0 ? steps[si] : null, prevStep = si > 0 ? steps[si - 1] : null;
  const rects = step ? shots[step.shot].rects : {}, cam = camAt(t);
  const toScreen = (r: Rect): Rect => ({ x: WIN.x + r.x * WIN.w * cam.s + cam.tx, y: WIN.y + r.y * WIN.h * cam.s + cam.ty, w: r.w * WIN.w * cam.s, h: r.h * WIN.h * cam.s });
  const outroAt = tm.total - tm.outro;
  const winIn = spring({ frame: frame - (tm.intro - 0.55) * FPS, fps: FPS, config: { damping: 12, stiffness: 110 } });
  const winOut = t >= outroAt ? spring({ frame: frame - outroAt * FPS, fps: FPS, config: { damping: 14, stiffness: 120 } }) : 0;
  const allPops: { p: Pop; i: number; stepEnd: number; sp: typeof steps[number] }[] = [];
  steps.forEach((s) => s.pops.forEach((p, j) => allPops.push({ p, i: allPops.length + j, stepEnd: s.end, sp: s })));
  const hop = allPops.reduce((m, { p }) => { const life = t - p.t; return life >= 0 && life < 0.6 && p.kind !== "zoom" ? Math.max(m, Math.sin((life / 0.6) * Math.PI)) : m; }, 0);

  // eyes follow whatever is being pointed at
  const active = allPops.filter(({ p }) => t >= p.t && t < p.t + popLife(p) && p.rect).slice(-1)[0];
  let look: [number, number] = [-0.6, 0.1];
  if (active && step) { const r = toScreen(shots[active.sp.shot].rects[active.p.rect!]); look = [clamp((r.x + r.w / 2 - 1760) / 700, -1, 1), clamp((r.y + r.h / 2 - 830) / 500, -1, 1)]; }
  const talking = !!step && t >= step.start && t < step.start + step.voice;

  const shotChanged = !!step && (!prevStep || prevStep.shot !== step.shot), since = step ? t - step.start : 0;
  const enter = step && shotChanged ? spring({ frame: since * FPS, fps: FPS, config: { damping: 13, stiffness: 120, mass: 0.8 } }) : 1;
  const Layer: React.FC<{ file: string; c: Cam; style?: React.CSSProperties }> = ({ file, c, style }) => (
    <div style={{ position: "absolute", inset: 0, ...style }}><Img src={staticFile(file)} style={{ position: "absolute", left: 0, top: 0, width: WIN.w, height: WIN.h, transformOrigin: "0 0", transform: `translate(${c.tx}px,${c.ty}px) scale(${c.s})` }} /></div>
  );

  const introFade = interpolate(t, [tm.intro - 0.6, tm.intro - 0.1], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const outroIn = t >= outroAt ? spring({ frame: frame - (outroAt + 0.15) * FPS, fps: FPS, config: { damping: 11, stiffness: 100 } }) : 0;
  const words = meta.title.split(" ");

  return (
    <AbsoluteFill style={{ fontFamily: FONT, color: C.text }}>
      <Background />
      <Audio src={staticFile(`audio/${id}.wav`)} />

      {/* ---------- intro ---------- */}
      {introFade > 0 && (
        <AbsoluteFill style={{ opacity: introFade, transform: `scale(${1 + (1 - introFade) * 0.15})` }}>
          <div style={{ position: "absolute", left: 0, right: 0, top: 200, textAlign: "center" }}>
            <div style={{ display: "inline-block", transform: `rotate(-3deg) scale(${spring({ frame: frame - 4, fps: FPS, config: { damping: 9, stiffness: 180 } })})`, padding: "10px 34px", background: C.yellow, color: C.ink, border: `6px solid ${C.ink}`, borderRadius: 40, boxShadow: `8px 8px 0 ${C.ink}`, fontWeight: 700, fontSize: 52 }}>✨ How to ✨</div>
            <div style={{ marginTop: 40, display: "flex", justifyContent: "center", flexWrap: "wrap", gap: "0 28px", padding: "0 220px" }}>
              {words.map((w, i) => { const s = spring({ frame: frame - 10 - i * 5, fps: FPS, config: { damping: 9, stiffness: 160 } }); return <span key={i} style={{ fontWeight: 700, fontSize: 118, lineHeight: 1.12, color: "#fff", WebkitTextStroke: `14px ${C.ink}`, paintOrder: "stroke fill", display: "inline-block", transform: `translateY(${(1 - s) * 90}px) scale(${s}) rotate(${(1 - s) * -8}deg)`, opacity: Math.min(1, s * 2), textShadow: `0 8px 0 ${C.ink}` }}>{w}</span>; })}
            </div>
            <div style={{ marginTop: 34, display: "inline-flex", gap: 16, transform: `scale(${spring({ frame: frame - 34, fps: FPS, config: { damping: 10 } })})` }}>
              <span style={{ padding: "6px 26px", background: C.teal, color: C.ink, border: `5px solid ${C.ink}`, borderRadius: 30, fontWeight: 600, fontSize: 38, boxShadow: `6px 6px 0 ${C.ink}` }}>{meta.section}</span>
              <span style={{ padding: "6px 26px", background: "#8fb5ff", color: C.ink, border: `5px solid ${C.ink}`, borderRadius: 30, fontWeight: 600, fontSize: 38, boxShadow: `6px 6px 0 ${C.ink}` }}>{meta.level}</span>
            </div>
          </div>
          <Mascot x={W / 2} y={915} size={250} look={[0, -0.2]} talking={false} hop={Math.max(0, Math.sin(Math.min(1, Math.max(0, (frame - 20) / 14)) * Math.PI))} happy />
          <div style={{ position: "absolute", left: 0, right: 0, top: 96, textAlign: "center", fontWeight: 700, fontSize: 44, letterSpacing: 8, color: C.text2 }}>⚡ ATAM FLOW</div>
        </AbsoluteFill>
      )}

      {/* ---------- the window with the real screens ---------- */}
      {step && winIn > 0.001 && winOut < 0.999 && (
        <div style={{ position: "absolute", left: WIN.x, top: WIN.y, width: WIN.w, height: WIN.h, transform: `scale(${(0.7 + 0.3 * winIn) * (1 - 0.2 * winOut)}) rotate(${(1 - winIn) * -7 + winOut * 8}deg) translateY(${winOut * 700}px)`, opacity: Math.min(1, winIn * 1.5) * (1 - winOut), borderRadius: 26, border: `7px solid ${C.ink}`, boxShadow: `16px 16px 0 rgba(0,0,0,.45), 0 0 90px rgba(79,141,255,.28)`, overflow: "hidden", background: C.bg1 }}>
          {shotChanged && prevStep && since < 0.9 && <Layer file={shots[prevStep.shot].file} c={camAt(step.start - 0.01)} />}
          <Layer file={shots[step.shot].file} c={cam} style={shotChanged ? { transform: `translateX(${(1 - enter) * 160}px) rotate(${(1 - enter) * 2.5}deg) scale(${0.94 + 0.06 * enter})`, opacity: Math.min(1, enter * 3), boxShadow: "-12px 0 40px rgba(0,0,0,.4)" } : undefined} />
        </div>
      )}

      {step && winOut < 0.9 && <>
        {allPops.map(({ p, i, stepEnd }) => <PopView key={i} p={p} t={t} i={i} toScreen={toScreen} rects={rects} stepEnd={stepEnd} />)}
        {/* step badge + section chip */}
        <div style={{ position: "absolute", left: WIN.x - 8, top: 22, transform: `rotate(-3deg) scale(${spring({ frame: (t - step.start) * FPS, fps: FPS, config: { damping: 8, stiffness: 200 } })})`, padding: "4px 26px", background: C.yellow, color: C.ink, border: `5px solid ${C.ink}`, borderRadius: 30, fontWeight: 700, fontSize: 34, boxShadow: `5px 5px 0 ${C.ink}` }}>STEP {si + 1} OF {n}</div>
        <div style={{ position: "absolute", right: W - WIN.x - WIN.w - 8, top: 22, transform: "rotate(2deg)", padding: "4px 26px", background: C.teal, color: C.ink, border: `5px solid ${C.ink}`, borderRadius: 30, fontWeight: 600, fontSize: 32, boxShadow: `5px 5px 0 ${C.ink}`, opacity: winIn }}>{meta.title}</div>
        <Mascot x={1765} y={830} size={200} look={look} talking={talking} hop={hop} />
        {/* kinetic captions: each word pops in as it is spoken */}
        {t < step.end + 0.2 && (
          <div style={{ position: "absolute", left: 120, right: 120, bottom: 26, display: "flex", flexWrap: "wrap", justifyContent: "center", gap: "2px 20px", fontWeight: 600, fontSize: 54, lineHeight: 1.08 }}>
            {step.words.map((w, k) => {
              const at = step.start + w.t0, life = t - at, s = life < 0 ? 0 : spring({ frame: life * FPS, fps: FPS, config: { damping: 10, stiffness: 220, mass: 0.5 } });
              const key = step.pops.some((p) => p.on && w.w.toLowerCase().replace(/[^a-z0-9£/-]/g, "").startsWith(p.on.toLowerCase().replace(/[^a-z0-9£/-]/g, ""))), now = life >= 0 && life < Math.max(0.35, w.t1 - w.t0);
              return <span key={k} style={{ display: "inline-block", opacity: Math.min(1, s * 2.5), transform: `translateY(${(1 - s) * 26}px) scale(${0.85 + 0.15 * s + (now ? 0.1 : 0)})`, color: key ? C.yellow : "#fff", WebkitTextStroke: `11px ${C.ink}`, paintOrder: "stroke fill" }}>{w.w}</span>;
            })}
          </div>
        )}
      </>}

      {/* ---------- outro ---------- */}
      {t >= outroAt && (
        <AbsoluteFill style={{ opacity: Math.min(1, outroIn * 2) }}>
          <div style={{ position: "absolute", left: 0, right: 0, top: 250, textAlign: "center", transform: `scale(${0.6 + 0.4 * outroIn}) rotate(${(1 - outroIn) * 6}deg)` }}>
            <div style={{ display: "inline-block", fontWeight: 700, fontSize: 150, color: "#fff", WebkitTextStroke: `16px ${C.ink}`, paintOrder: "stroke fill", textShadow: `0 10px 0 ${C.ink}` }}>That’s a wrap! 🎬</div>
            <div style={{ marginTop: 30 }}><span style={{ display: "inline-block", padding: "10px 40px", background: C.yellow, color: C.ink, border: `6px solid ${C.ink}`, borderRadius: 40, boxShadow: `8px 8px 0 ${C.ink}`, fontWeight: 700, fontSize: 52, transform: "rotate(-2deg)" }}>Find more on the How-to videos page</span></div>
          </div>
          <Mascot x={W / 2} y={800} size={330} look={[0, 0]} talking={false} happy hop={Math.abs(Math.sin((frame - outroAt * FPS) / 9)) * 0.7} />
          {t - outroAt < 2.4 && <Confetti life={t - outroAt} seed="outro" ox={W / 2} oy={H * 0.8} count={110} />}
        </AbsoluteFill>
      )}

      {/* progress bar */}
      <div style={{ position: "absolute", left: 0, bottom: 0, height: 10, width: (t / tm.total) * W, background: `linear-gradient(90deg, ${C.blue}, ${C.teal})`, borderRadius: "0 8px 8px 0" }} />
    </AbsoluteFill>
  );
};
