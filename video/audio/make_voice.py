"""Generates the voiceover for each tutorial with Kokoro (pip install kokoro-onnx soundfile numpy).
Writes audio/vo/<id>/<key>.wav and each line's length to src/voice-durations.json.
Usage: python make_voice.py [tutorial id | all] [voice]     (default voice af_heart; KOKORO_DIR points at the model files)
Model files (kokoro-v1.0.int8.onnx, voices-v1.0.bin): github.com/thewh1teagle/kokoro-onnx releases, model-files-v1.0."""
import json, os, re, sys
import numpy as np, soundfile as sf
from kokoro_onnx import Kokoro
from common import TUTORIALS, SRC, HERE

which = sys.argv[1] if len(sys.argv) > 1 else "all"
voice = sys.argv[2] if len(sys.argv) > 2 else "af_heart"
model_dir = os.environ.get("KOKORO_DIR", ".")
k = Kokoro(os.path.join(model_dir, "kokoro-v1.0.int8.onnx"), os.path.join(model_dir, "voices-v1.0.bin"))
dpath = os.path.join(SRC, "voice-durations.json")
durations = json.load(open(dpath)) if os.path.exists(dpath) else {}

# A bare letter is read as a word ("a"), so spelled-out letters get explicit phonemes.
LETTERS = {"A": "ˈeɪ", "B": "bˈi", "C": "sˈi", "D": "dˈi", "E": "ˈi", "F": "ˈɛf", "G": "ʤˈi", "H": "ˈeɪʧ", "I": "ˈaɪ", "K": "kˈeɪ", "L": "ˈɛl", "M": "ˈɛm",
           "O": "ˈoʊ", "P": "pˈi", "Q": "kjˈu", "R": "ˈɑɹ", "S": "ˈɛs", "T": "tˈi", "U": "jˈu", "V": "vˈi", "W": "dˈʌbəljˌu", "X": "ˈɛks", "Y": "wˈaɪ", "Z": "zˈi"}
def to_phonemes(text, lang):
    out = []
    for p in re.split(r"(\[\[[A-Z]\]\])", text):
        m = re.fullmatch(r"\[\[([A-Z])\]\]", p)
        if m: out.append(LETTERS[m.group(1)])
        elif p.strip(): out.append(k.tokenizer.phonemize(p.strip(), lang))
    return " ".join(out)

lang = "en-us" if voice.startswith("a") else "en-gb"
for tut in TUTORIALS:
    if which not in ("all", tut["id"]): continue
    outdir = os.path.join(HERE, "vo", tut["id"]); os.makedirs(outdir, exist_ok=True)
    sp = tut.get("voiceSpeed", 1.12)        # a touch brisk: upbeat, not rushed
    for step in tut["steps"]:
        text = step["voice"]; spelled = "[[" in text
        s, sr = k.create(to_phonemes(text, lang) if spelled else text, voice=voice, speed=sp, lang=lang, is_phonemes=spelled)
        idx = np.where(np.abs(s) > 0.01)[0]
        s = s[max(idx[0] - int(.02 * sr), 0): idx[-1] + int(.08 * sr)]
        sf.write(os.path.join(outdir, step["key"] + ".wav"), s, sr)
        durations.setdefault(tut["id"], {})[step["key"]] = round(len(s) / sr, 2)
        print(tut["id"], step["key"], f"{len(s)/sr:.2f}s", text)
json.dump(durations, open(dpath, "w"), indent=1)
