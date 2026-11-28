"""Prints the voice lines of a tutorial as text for a text-to-speech service that does not take phonemes (such as ElevenLabs):
spelled-out letters become separate capitals so they are read as letters ([[P]] [[O]] -> "P O").
Usage: python el_lines.py <tutorial id>     -> {"a": "...", "b": "..."}"""
import json, re, sys
from common import TUTORIALS
spoken = lambda t: re.sub(r"\s+", " ", re.sub(r"\[\[([A-Z])\]\]", r"\1 ", t)).replace(" .", ".").replace(" ,", ",").replace(" !", "!").replace(" ?", "?").strip()
tut = next(t for t in TUTORIALS if t["id"] == sys.argv[1])
print(json.dumps({s["key"]: spoken(s["voice"]) for s in tut["steps"]}, indent=1, ensure_ascii=False))
