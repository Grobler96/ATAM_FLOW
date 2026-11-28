"""Imports voice lines recorded elsewhere (for example ElevenLabs, voice "Brady J") in place of the Kokoro ones.
Put one file per line in a folder, named <key>.mp3 (or .wav): a.mp3, b.mp3, ... Then:
    python import_voice.py <tutorial id> <folder> [out dir]
It trims silence the same way make_voice.py does, writes audio/vo/<id>/<key>.wav and the line lengths to src/voice-durations.json.
After that run make_timing.py, make_audio_tutorial.py and the checks as usual. Needs ffmpeg + numpy + soundfile."""
import json, os, subprocess, sys, tempfile
import numpy as np, soundfile as sf
from common import TUTORIALS, SRC, HERE
tid, folder = sys.argv[1], sys.argv[2]
outdir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, "vo", tid)
os.makedirs(outdir, exist_ok=True)
dpath = os.path.join(SRC, "voice-durations.json"); durations = json.load(open(dpath)) if os.path.exists(dpath) else {}
for step in next(t for t in TUTORIALS if t["id"] == tid)["steps"]:
    src = next((os.path.join(folder, step["key"] + e) for e in (".mp3", ".wav") if os.path.exists(os.path.join(folder, step["key"] + e))), None)
    if not src: sys.exit(f"missing {step['key']}.mp3 in {folder}")
    tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-ac", "1", "-ar", "44100", tmp], check=True)
    s, sr = sf.read(tmp, dtype="float32"); os.remove(tmp)
    idx = np.where(np.abs(s) > 0.01)[0]; s = s[max(idx[0] - int(.02 * sr), 0): idx[-1] + int(.08 * sr)]
    sf.write(os.path.join(outdir, step["key"] + ".wav"), s, sr)
    if outdir == os.path.join(HERE, "vo", tid): durations.setdefault(tid, {})[step["key"]] = round(len(s) / sr, 2)
    print(tid, step["key"], f"{len(s)/sr:.2f}s")
json.dump(durations, open(dpath, "w"), indent=1)
