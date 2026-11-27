"""Checks a finished soundtrack without listening to it:
- loudness (LUFS, via ffmpeg) and peak level, and whether anything clips
- how far the voice sits above the music (level while each line plays vs. the gaps between lines)
- speech recognition on the finished mix, line by line, so a voice buried under the beat gets flagged
- a spectrogram image at out/stills/<id>-spectrum.png
Usage: python check_mix.py <id> [<id> ...]   (WHISPER_DIR as for check_voice.py; needs ffmpeg)"""
import difflib, json, os, re, subprocess, sys
import numpy as np, soundfile as sf, sherpa_onnx
from check_voice import norm, rec, ALL

HERE = os.path.dirname(os.path.abspath(__file__))
TM = json.load(open(os.path.join(HERE, "..", "src", "timing.json")))
durs = json.load(open(os.path.join(HERE, "..", "src", "voice-durations.json")))
db = lambda x: 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-9)
bad = 0
for id_ in sys.argv[1:]:
    ad = next(a for a in ALL if a["id"] == id_)
    path = os.path.join(HERE, "..", "public", "audio", id_ + ".wav")
    x, sr = sf.read(path, dtype="float32"); mono = x.mean(1)
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
    lufs = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", r)[-1]); tp = float(re.findall(r"Peak:\s+(-?[\d.]+) dBFS", r)[-1])
    clip = int(np.sum(np.abs(x) > 0.999))
    speech = np.zeros(len(mono), bool)
    starts = {st_["key"]: st_["start"] for st_ in TM[id_]["steps"]}
    for k, s in starts.items():
        speech[int(s * sr): int((s + durs[id_][k]) * sr)] = True
    gap = db(mono[~speech][int(0.5 * sr):]) if (~speech).sum() > sr else float("nan")
    print(f"\n== {id_}: {lufs:.1f} LUFS, true peak {tp:.1f} dBFS, clipped samples {clip}, level in speech {db(mono[speech]):.1f} dB vs gaps {gap:.1f} dB")
    if clip or tp > -0.5: bad += 1; print("CHECK peak level")
    for k, s in starts.items():
        seg = mono[int((s - 0.1) * sr): int((s + durs[id_][k] + 0.25) * sr)]
        st = rec.create_stream(); st.accept_waveform(sr, seg); rec.decode_stream(st)
        heard = st.result.text.strip()
        ratio = difflib.SequenceMatcher(None, norm(ad["voice"][k]), norm(heard)).ratio()
        flag = "OK " if ratio >= 0.8 else "CHECK"; bad += flag != "OK "
        print(f"  {flag} {k} {ratio:.2f} heard over the music: {heard!r}")
    png = os.path.join(HERE, "..", "out", "stills", f"{id_}-spectrum.png"); os.makedirs(os.path.dirname(png), exist_ok=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-lavfi", "showspectrumpic=s=1500x400:legend=1:scale=log,format=rgb24", png])
print(f"\n{bad} issue(s)")
