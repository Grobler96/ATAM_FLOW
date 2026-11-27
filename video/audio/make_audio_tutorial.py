"""Builds public/audio/<id>.wav for a tutorial: upbeat score + a sound effect for every pop-up, whoosh and key press, with the voiceover on top
(the music ducks under the voice). Everything is timed from src/timing.json, the same file the animation reads. Needs numpy + scipy.
Usage: python make_audio_tutorial.py [id | all]"""
import json, os, sys, wave, zlib
import numpy as np
from scipy.signal import lfilter, butter, resample_poly
HERE = os.path.dirname(os.path.abspath(__file__))
TIMING = json.load(open(os.path.join(HERE, "..", "src", "timing.json")))
SR = 44100

def lp(x, fc, o=2): b, a = butter(o, fc / (SR / 2), "low"); return lfilter(b, a, x)
def hp(x, fc, o=2): b, a = butter(o, fc / (SR / 2), "high"); return lfilter(b, a, x)
def bp(x, lo, hi): b, a = butter(2, [lo / (SR / 2), hi / (SR / 2)], "band"); return lfilter(b, a, x)
def env(n, a=0.005, d=0.2): t = np.arange(n) / SR; return np.minimum(t / a, 1) * np.exp(-t / d)
def tone(f, dur, a=0.005, d=0.2, shape="sine"):
    t = np.arange(int(SR * dur)) / SR
    ph = 2 * np.pi * f * t if np.isscalar(f) else 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) if shape == "sine" else (2 * ((ph / (2 * np.pi)) % 1) - 1)
    return s * env(len(t), a, d)
def midi(n): return 440 * 2 ** ((n - 69) / 12)
def pluck(n, dur=0.6, d=0.18, bright=3500):
    f = midi(n); t = np.arange(int(SR * dur)) / SR
    return lp(np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * 2 * f * t) + 0.15 * np.sin(2 * np.pi * 3 * f * t), bright) * env(len(t), 0.003, d)
def bell(n, dur=1.0, d=0.3):
    f = midi(n); t = np.arange(int(SR * dur)) / SR
    return (np.sin(2 * np.pi * f * t) + 0.5 * np.sin(2 * np.pi * 2.76 * f * t) * np.exp(-t / 0.15) + 0.25 * np.sin(2 * np.pi * 5.4 * f * t) * np.exp(-t / 0.06)) * env(len(t), 0.002, d)

def build(tid):
    tm = TIMING[tid]; DUR = tm["total"]; N = int(SR * DUR); T = np.arange(N) / SR
    rng = np.random.default_rng(zlib.crc32(tid.encode()))   # same music every run
    noise = lambda d: rng.standard_normal(int(SR * d))
    music, sfx, vo = np.zeros(N), np.zeros(N), np.zeros(N)
    def put(buf, x, t0, g=1.0):
        i = int(t0 * SR)
        if i >= N or i + len(x) <= 0: return
        if i < 0: x, i = x[-i:], 0
        x = x[: N - i]; buf[i:i + len(x)] += x * g

    # ---- score: 116 bpm, C - G - Am - F, fades in over the intro ----
    bpm = 116; beat = 60 / bpm; bar = 4 * beat
    prog = [(48, (60, 64, 67)), (43, (59, 62, 67)), (45, (57, 60, 64)), (41, (57, 60, 65))]
    pent = [72, 74, 76, 79, 81, 84]
    groove0 = tm["intro"] - 0.4
    for b in range(int((DUR + bar) / bar)):
        t0 = b * bar; root, ch = prog[b % 4]
        if t0 >= DUR: break
        for n in ch:
            for det in (-0.1, 0.1): put(music, lp(tone(midi(n) * (1 + det * 0.01), bar * 0.9, 0.02, 0.9, "saw"), 1800), t0, 0.018)
        for s_, off in enumerate((0, 1.5, 2, 3.5)):                       # bouncy bass
            put(music, lp(tone(midi(root), 0.3, 0.004, 0.14, "saw"), 420), t0 + off * beat, 0.2)
        for off in (1.5, 3.5):                                              # off-beat chord stabs
            for n in ch: put(music, pluck(n, 0.4, 0.1, 3000), t0 + off * beat, 0.04)
        for k in range(8):                                                  # sparkly arpeggio
            if rng.random() < 0.7: put(music, pluck(int(rng.choice(pent)), 0.35, 0.1, 5000), t0 + k * beat / 2 + beat / 4, 0.022)
        if t0 + bar > groove0:
            for k in range(4):
                tt = t0 + k * beat
                if tt >= groove0: put(music, tone(np.concatenate([np.linspace(130, 48, int(SR * .1)), np.full(int(SR * .18), 48.)]), 0.28, 0.001, 0.09), tt, 0.32)
            for k in (1, 3):
                tt = t0 + k * beat
                if tt >= groove0: put(music, bp(noise(0.18), 900, 3800) * env(int(SR * 0.18), 0.001, 0.06), tt, 0.13)
            for k in range(8):
                tt = t0 + k * beat / 2 + beat / 4 * (k % 2 == 1) * 0
                if tt >= groove0: put(music, hp(noise(0.08), 7000) * env(int(SR * 0.08), 0.0005, 0.02), tt + beat / 4 * 0, 0.045)
    music *= np.interp(T, [0, 1.4, DUR - 1.4, DUR], [0.0, 1.0, 1.0, 0.0])

    # ---- intro / outro flourishes ----
    put(sfx, hp(noise(1.6), 1500) * np.linspace(0, 1, int(SR * 1.6)) ** 2.5, 0.5, 0.1)
    for k, n in enumerate((72, 76, 79, 84)): put(sfx, bell(n, 1.2, 0.35), 0.35 + k * 0.1, 0.09)
    put(sfx, bp(noise(0.6), 400, 7000) * np.sin(np.linspace(0, np.pi, int(SR * 0.6))) ** 2, tm["intro"] - 0.6, 0.3)       # window whoosh in
    o = DUR - tm["outro"]
    put(sfx, bp(noise(0.5), 500, 8000) * np.sin(np.linspace(0, np.pi, int(SR * 0.5))) ** 2, o - 0.05, 0.3)
    for k, n in enumerate((72, 76, 79, 84, 88)): put(sfx, bell(n, 1.6, 0.5), o + 0.2 + k * 0.07, 0.11)
    put(sfx, hp(noise(1.2), 3000) * env(int(SR * 1.2), 0.002, 0.4), o + 0.15, 0.12)

    # ---- per-step and per-pop sound effects, all on the animation's own timing ----
    prev = None
    for s in tm["steps"]:
        put(sfx, tone(np.linspace(500, 900, int(SR * 0.09)), 0.09, 0.003, 0.05), s["start"], 0.09)           # step tick
        if prev is not None and prev != s["shot"]: put(sfx, bp(noise(0.3), 500, 6500) * np.sin(np.linspace(0, np.pi, int(SR * 0.3))) ** 2, s["start"] - 0.32, 0.2)
        prev = s["shot"]
        for p in s["pops"]:
            t0, k = p["t"], p["kind"]
            if k == "sticker":
                put(sfx, tone(np.linspace(300, 950, int(SR * 0.12)), 0.12, 0.002, 0.07), t0, 0.28); put(sfx, bell(84, 0.7, 0.18), t0 + 0.05, 0.1)
            elif k == "ring":
                put(sfx, bp(noise(0.4), 1500, 7000) * np.sin(np.linspace(0, np.pi, int(SR * 0.4))) ** 2, t0, 0.16)
                for j, n in enumerate((88, 93)): put(sfx, bell(n, 0.8, 0.2), t0 + 0.4 + j * 0.08, 0.08)
            elif k == "arrow":
                put(sfx, bp(noise(0.36), 2000, 6000) * np.sin(np.linspace(0, np.pi, int(SR * 0.36))) ** 1.5, t0, 0.2); put(sfx, tone(np.linspace(700, 520, int(SR * 0.1)), 0.1, 0.002, 0.05), t0 + 0.5, 0.2)
            elif k == "keys":
                put(sfx, tone(np.linspace(300, 800, int(SR * 0.1)), 0.1, 0.002, 0.06), t0, 0.2)
                for i in range(len(p.get("keys", []))): put(sfx, hp(noise(0.03), 1500) * env(int(SR * 0.03), 0.0005, 0.01) + 0.5 * tone(1400, 0.03, 0.001, 0.02), t0 + 0.7 + i * 0.5, 0.25)
            elif k == "stamp":
                put(sfx, tone(np.concatenate([np.linspace(160, 45, int(SR * .15)), np.full(int(SR * .4), 45.)]), 0.55, 0.001, 0.2), t0, 0.7); put(sfx, hp(noise(0.5), 1800) * env(int(SR * 0.5), 0.001, 0.15), t0, 0.22)
            elif k == "confetti":
                put(sfx, bp(noise(0.25), 800, 6000) * env(int(SR * 0.25), 0.001, 0.08), t0, 0.35); put(sfx, tone(np.linspace(150, 60, int(SR * 0.12)), 0.12, 0.001, 0.05), t0, 0.3)
                for j, n in enumerate((79, 84, 88, 91, 96)): put(sfx, bell(n, 1.0, 0.3), t0 + 0.08 + j * 0.06, 0.1)

    # ---- voiceover: gentle drive and a touch of room, placed on each step's start ----
    for s in tm["steps"]:
        with wave.open(os.path.join(HERE, "vo", tid, s["key"] + ".wav")) as w:
            x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float) / 32768; sr = w.getframerate()
        x = hp(resample_poly(x, SR, sr), 90); x = np.tanh(x * 2.0) / np.tanh(2.0); x = x / np.max(np.abs(x)) * 0.85
        n = int(SR * 0.22); ir = lp(rng.standard_normal(n) * np.exp(-np.arange(n) / (SR * 0.06)), 5000)
        put(vo, x + 0.1 * np.convolve(x, ir / np.sqrt(np.sum(ir ** 2)))[: len(x)], s["start"])
    e = lp(np.abs(vo), 6); e = np.clip(e / (np.percentile(e, 98) + 1e-9), 0, 1); duck = 1 - 0.55 * e
    mix = music * duck * 0.9 + sfx * (1 - 0.5 * e) + vo * 1.15
    mix *= np.minimum(T / 0.2, 1) * np.minimum((DUR - T) / 0.8, 1)
    mix = np.tanh(mix * 1.05); mix = mix / np.max(np.abs(mix)) * 0.76
    wide = np.roll(music * duck, int(SR * 0.011)) - music * duck
    st = np.stack([mix - 0.1 * wide, mix + 0.1 * wide], 1); st /= max(1, np.max(np.abs(st)) / 0.76)
    out = os.path.join(HERE, "..", "public", "audio", tid + ".wav"); os.makedirs(os.path.dirname(out), exist_ok=True)
    with wave.open(out, "wb") as w: w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes((st * 32767).astype(np.int16).tobytes())
    print("wrote", os.path.normpath(out), f"{DUR:.1f}s")

for tid in TIMING:
    if len(sys.argv) < 2 or sys.argv[1] in ("all", tid): build(tid)
