#!/usr/bin/env python3
"""Corpus from the real recordings: Application Support/Sotto/audio/*/entry.json.
Writes corpus/all.json and a stratified corpus/dev.json (fast iteration set).
corpus/ and results/ are git-ignored: they are the user's speech."""
import glob, json, os, random
root = os.path.expanduser("~/Library/Application Support/Sotto/audio")
entries = []
for p in sorted(glob.glob(f"{root}/*/entry.json")):
    e = json.load(open(p))
    raw = e.get("raw", "").strip()
    if not raw:
        continue
    loc = (e.get("locales") or [None])[0]
    entries.append({"id": e["id"], "raw": raw, "locale": loc,
                    "words": len(raw.replace("[pause", " ").split())})
here = os.path.dirname(os.path.abspath(__file__))
json.dump(entries, open(f"{here}/corpus/all.json", "w"), indent=1, ensure_ascii=False)
# Dev: every Spanish entry, then English spread across length buckets.
random.seed(7)
es = [e for e in entries if (e["locale"] or "").startswith("es")]
en = [e for e in entries if e not in es]
buckets = [(0, 12), (12, 30), (30, 70), (70, 10_000)]
dev = es[:6]
for lo, hi in buckets:
    pool = [e for e in en if lo <= e["words"] < hi]
    dev += random.sample(pool, min(len(pool), 9))
dev.sort(key=lambda e: e["words"])
json.dump(dev, open(f"{here}/corpus/dev.json", "w"), indent=1, ensure_ascii=False)
print(len(entries), "entries;", len(dev), "dev;", len(es), "spanish")
