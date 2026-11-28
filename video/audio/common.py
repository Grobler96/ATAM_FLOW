"""Shared bits for the tutorial audio scripts: the tutorial list, caption text and word timing.
Captions are the spoken line with spelled-out letters written normally ([[P]] [[O]] -> PO). Word timing is proportional to word
length, with a small pause after punctuation; it is only used to line up pop-ups and caption words with the voice."""
import json, os, re
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
TUTORIALS = json.load(open(os.path.join(SRC, "tutorials.json")))
INTRO, GAP, OUTRO = 2.6, 0.5, 3.2

def display(text):
    def group(m):
        letters = "".join(re.findall(r"\[\[([A-Z])\]\]", m.group(0)))
        return letters + (" " if m.group(0)[-1].isspace() else "")
    return re.sub(r"(?:\[\[[A-Z]\]\]\s*)+", group, text)

def words(text, dur):
    ws = display(text).split()
    wt = [len(w) + (4 if re.search(r"[,.!?:]$", w) else 0) for w in ws]
    tot = float(sum(wt)); out = []; acc = 0.0
    for w, x in zip(ws, wt):
        out.append({"w": w, "t0": round(acc / tot * dur, 3), "t1": round((acc + len(w)) / tot * dur, 3)})
        acc += x
    return out
