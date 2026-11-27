"""Works out when everything happens: each step's start, each caption word, and the moment every pop-up fires (on the spoken word it names).
Writes src/timing.json, which both the animation and the audio mix read, so sound and picture can't drift apart.
Also checks every pop-up's word and every zoom/rect name exists. Usage: python make_timing.py"""
import json, os, re, sys
from common import TUTORIALS, SRC, INTRO, GAP, OUTRO, words
D = json.load(open(os.path.join(SRC, "voice-durations.json")))
S = json.load(open(os.path.join(SRC, "shots.json")))
out, bad = {}, 0
for tut in TUTORIALS:
    t = INTRO; steps = []
    for step in tut["steps"]:
        d = D[tut["id"]][step["key"]]
        ws = words(step["voice"], d)
        rects = S.get(step["shot"], {}).get("rects", {})
        if step["shot"] not in S: print(f"MISSING shot {step['shot']} ({tut['id']} {step['key']})"); bad += 1
        if step.get("zoom") and step["zoom"] not in rects: print(f"MISSING zoom rect {step['zoom']} on {step['shot']}"); bad += 1
        pops = []
        for p in step.get("pops", []):
            hit = next((w for w in ws if re.sub(r"[^a-z0-9£/-]", "", w["w"].lower()).startswith(re.sub(r"[^a-z0-9£/-]", "", p["on"].lower()))), None)
            if not hit: print(f"MISSING word '{p['on']}' in {tut['id']} {step['key']}: {step['voice']}"); bad += 1; continue
            if p.get("rect") and p["rect"] not in rects: print(f"MISSING rect {p['rect']} on {step['shot']}"); bad += 1
            pops.append({**p, "t": round(t + hit["t0"] + p.get("delay", 0), 3)})
        steps.append({"key": step["key"], "shot": step["shot"], "zoom": step.get("zoom"), "start": round(t, 3), "voice": d, "end": round(t + d + GAP, 3), "words": ws, "pops": pops})
        t += d + GAP
    out[tut["id"]] = {"intro": INTRO, "outro": OUTRO, "total": round(t + OUTRO, 3), "steps": steps}
    print(tut["id"], f"{out[tut['id']]['total']:.1f}s")
json.dump(out, open(os.path.join(SRC, "timing.json"), "w"), indent=1)
sys.exit(1 if bad else 0)
