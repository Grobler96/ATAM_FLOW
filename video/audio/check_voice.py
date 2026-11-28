"""Catches mispronunciations: runs every voice line in vo/<id>/ through Whisper speech recognition and compares what it heard with the script.
Usage: python check_voice.py <id> [<id> ...]
Needs: pip install sherpa-onnx numpy soundfile, and the Whisper base.en model from
github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.en.tar.bz2 unpacked into WHISPER_DIR."""
import difflib, json, os, re, sys
import numpy as np, soundfile as sf, sherpa_onnx

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
ALL = [{"id": t["id"], "voice": {x["key"]: x["voice"] for x in t["steps"]}} for t in json.load(open(os.path.join(SRC, "tutorials.json")))]
W = os.environ.get("WHISPER_DIR", "sherpa-onnx-whisper-base.en")
rec = sherpa_onnx.OfflineRecognizer.from_whisper(
    encoder=os.path.join(W, "base.en-encoder.int8.onnx"), decoder=os.path.join(W, "base.en-decoder.int8.onnx"),
    tokens=os.path.join(W, "base.en-tokens.txt"), language="en", task="transcribe")

# Whisper writes numbers as digits and brand names as it hears them, so both sides are normalised.
SAME = {"deco network": "deconetwork", "handover": "hand over", "a4": "a four", "100x150mm": "a hundred by one fifty millimetre", "atam": "a t a m", "p o": "po", "q r": "qr", "p o s": "pos", "command centre": "command center", "centre": "center", "millimetre": "millimeter", "a 4": "a four", "100": "a hundred", "150": "one fifty", "500": "five hundred", "360": "three sixty", "35": "thirty five", "£35": "thirty five pounds", "spin pics": "spinpix", "spin pix": "spinpix", "spinpics": "spinpix",
        "u k": "uk", "q r": "qr", "a o": "ao", "slomo": "slow mo", "slowmo": "slow mo", "spin picks": "spinpix", "dues": "dos", "do's": "dos"}
def norm(s):
    s = re.sub(r"\[\[([A-Z])\]\]", r"\1", s).lower().replace("-", " ").replace(".", " ")
    s = re.sub(r"[^a-z0-9£' ]", " ", s)
    s = " ".join(s.split())
    for a, b in SAME.items(): s = re.sub(rf"\b{re.escape(a)}(?=\s|$)", b, s)
    return s.split()

if __name__ == "__main__":
    bad = 0
    for id_ in sys.argv[1:]:
        ad = next(a for a in ALL if a["id"] == id_)
        for key, text in ad["voice"].items():
            x, sr = sf.read(os.path.join(HERE, "vo", id_, key + ".wav"), dtype="float32")
            st = rec.create_stream(); st.accept_waveform(sr, x); rec.decode_stream(st)
            heard = st.result.text.strip()
            a, b = norm(text), norm(heard)
            ratio = difflib.SequenceMatcher(None, a, b).ratio()
            flag = "OK " if ratio >= 0.85 else "CHECK"
            bad += flag != "OK "
            print(f"{flag} {id_} {key} {ratio:.2f} | script: {re.sub(r'\[\[([A-Z])\]\]', r'\1', text)!r} | heard: {heard!r}")
    print(f"\n{bad} line(s) to check")
    sys.exit(1 if bad else 0)
