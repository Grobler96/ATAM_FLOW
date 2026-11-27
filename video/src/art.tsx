import React from "react";
import { interpolate, random, useCurrentFrame } from "remotion";
import { C, FPS, H, W } from "./theme";

// Soft moving colour blobs, a dot grid and little floating doodles behind everything.
export const Background: React.FC = () => {
  const f = useCurrentFrame(); const t = f / FPS;
  const blobs = [{ c: C.blue, x: 0.15, y: 0.2, r: 520, sp: 0.35 }, { c: C.teal, x: 0.85, y: 0.8, r: 560, sp: 0.28 }, { c: "#a56bff", x: 0.7, y: 0.1, r: 420, sp: 0.42 }];
  return (
    <div style={{ position: "absolute", inset: 0, background: `linear-gradient(135deg, ${C.bg0}, ${C.bg2})`, overflow: "hidden" }}>
      {blobs.map((b, i) => (
        <div key={i} style={{ position: "absolute", left: b.x * W + Math.sin(t * b.sp + i) * 90 - b.r / 2, top: b.y * H + Math.cos(t * b.sp * 1.2 + i) * 70 - b.r / 2, width: b.r, height: b.r, borderRadius: "50%", background: b.c, opacity: 0.2, filter: "blur(110px)" }} />
      ))}
      <div style={{ position: "absolute", inset: 0, backgroundImage: "radial-gradient(rgba(148,170,210,0.16) 2px, transparent 2px)", backgroundSize: "44px 44px" }} />
      {Array.from({ length: 18 }, (_, i) => {
        const x = random(`dx${i}`) * W, y = random(`dy${i}`) * H, kind = i % 4, size = 26 + random(`ds${i}`) * 34;
        const col = [C.yellow, C.pink, C.teal, C.blue][i % 4];
        const dy = Math.sin(t * (0.6 + random(`dv${i}`)) + i) * 18, rot = t * (10 + (i % 5) * 6) * (i % 2 ? 1 : -1);
        return (
          <svg key={i} width={size} height={size} viewBox="0 0 40 40" style={{ position: "absolute", left: x, top: y + dy, opacity: 0.5, transform: `rotate(${rot}deg)` }}>
            {kind === 0 && <path d="M20 4v32M4 20h32" stroke={col} strokeWidth="6" strokeLinecap="round" />}
            {kind === 1 && <circle cx="20" cy="20" r="13" fill="none" stroke={col} strokeWidth="6" />}
            {kind === 2 && <path d="M4 26q8-14 16 0t16 0" fill="none" stroke={col} strokeWidth="6" strokeLinecap="round" />}
            {kind === 3 && <path d="M20 4l5 11 12 1-9 8 3 12-11-6-11 6 3-12-9-8 12-1z" fill={col} />}
          </svg>
        );
      })}
    </div>
  );
};

// "Flo", the Flow bolt mascot: eyes follow what's being pointed at, the mouth moves with the voice, and he hops when a pop-up lands.
export const Mascot: React.FC<{ x: number; y: number; size: number; look: [number, number]; talking: boolean; hop: number; happy?: boolean }> = ({ x, y, size, look, talking, hop, happy }) => {
  const f = useCurrentFrame(); const t = f / FPS;
  const idle = Math.sin(t * 3) * 5, open = talking ? 0.35 + 0.65 * Math.abs(Math.sin(f * 0.75)) : 0.05;
  const lx = interpolate(look[0], [-1, 1], [-9, 9]), ly = interpolate(look[1], [-1, 1], [-7, 7]);
  const blink = f % 110 > 104 ? 0.12 : 1;
  return (
    <div style={{ position: "absolute", left: x - size / 2, top: y - size / 2 + idle - hop * 38, width: size, height: size, transform: `rotate(${Math.sin(t * 2) * 3 + hop * 6}deg) scale(${1 + hop * 0.08}, ${1 - hop * 0.05})`, filter: "drop-shadow(8px 10px 0 rgba(0,0,0,.35))" }}>
      <svg viewBox="0 0 200 200" width="100%" height="100%">
        <defs><linearGradient id="fl" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor={C.blue} /><stop offset="1" stopColor={C.teal} /></linearGradient></defs>
        <path d="M112 2L74 56h22l-12 36 46-54h-24z" fill={C.yellow} stroke={C.ink} strokeWidth="6" strokeLinejoin="round" />
        <ellipse cx="100" cy="124" rx="80" ry="72" fill="url(#fl)" stroke={C.ink} strokeWidth="7" />
        <ellipse cx="68" cy="108" rx="21" ry={25 * blink} fill="#fff" stroke={C.ink} strokeWidth="5" />
        <ellipse cx="132" cy="108" rx="21" ry={25 * blink} fill="#fff" stroke={C.ink} strokeWidth="5" />
        <circle cx={68 + lx} cy={110 + ly} r="10" fill={C.ink} /><circle cx={132 + lx} cy={110 + ly} r="10" fill={C.ink} />
        <circle cx={64 + lx} cy={105 + ly} r="3.5" fill="#fff" /><circle cx={128 + lx} cy={105 + ly} r="3.5" fill="#fff" />
        <ellipse cx="42" cy="142" rx="13" ry="8" fill={C.pink} opacity="0.75" /><ellipse cx="158" cy="142" rx="13" ry="8" fill={C.pink} opacity="0.75" />
        {happy || !talking ? <path d={`M78 144q22 ${24 + open * 10} 44 0${talking ? "z" : ""}`} fill={talking ? C.ink : "none"} stroke={C.ink} strokeWidth="6" strokeLinecap="round" /> : null}
        {talking && !happy ? <><ellipse cx="100" cy="152" rx="17" ry={4 + open * 15} fill={C.ink} /><ellipse cx="100" cy={158 + open * 5} rx="9" ry={2 + open * 5} fill={C.pink} /></> : null}
      </svg>
    </div>
  );
};
