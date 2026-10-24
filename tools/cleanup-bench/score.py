#!/usr/bin/env python3
"""Scores bench results against corpus/refs.json (+ corpus/synthetic.json refs).
score.py results/a.jsonl [results/b.jsonl ...] [--detail VARIANT] [--corpus corpus/dev.json]"""
import json, re, sys, os, statistics
here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
detail = args[args.index("--detail") + 1] if "--detail" in args else None
files = [a for a in args if a.endswith(".jsonl")]

refs = {}
for name in ("refs.json",):
    p = f"{here}/corpus/{name}"
    if os.path.exists(p): refs.update(json.load(open(p)))
raws = {}
for name in ("all.json", "synthetic.json"):
    p = f"{here}/corpus/{name}"
    if os.path.exists(p):
        for e in json.load(open(p)):
            raws[e["id"]] = e["raw"]
            if "ref" in e: refs[e["id"]] = e["ref"]

def unmark(t): return re.sub(r"\s*\[pause [0-9]+ms\]", "", t).strip()
def words(t): return re.findall(r"[\w']+", t.lower())
def tokens(t): return re.findall(r"[\w']+|[^\w\s']", t)
def ed(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]

rows = [json.loads(l) for f in files for l in open(f) if l.strip()]
by = {}
for r in rows: by.setdefault(r["variant"], []).append(r)

def agg(rs, text):
    w = t = wn = tn = 0
    for r in rs:
        ref = refs.get(r["id"])
        if ref is None: continue
        out = text(r)
        w += ed(words(out), words(ref)); wn += len(words(ref))
        t += ed(tokens(out), tokens(ref)); tn += len(tokens(ref))
    return w / max(wn, 1), t / max(tn, 1)

print(f"{'variant':24} {'n':>4} {'wer':>6} {'ter':>6} {'rawWer':>6} {'rawTer':>6} {'rej':>4} {'model':>5} {'med ms':>7} {'p90 ms':>7} {'ms/word':>7} {'inTok':>6} {'outTok':>6}")
for v, rs in by.items():
    scored = [r for r in rs if r["id"] in refs]
    wer, ter = agg(scored, lambda r: r["inserted"])
    rw, rt = agg(scored, lambda r: unmark(raws.get(r["id"], "")))
    ms = sorted(r["ms"] for r in rs)
    per = [r["ms"] / max(1, len(words(unmark(raws.get(r["id"], ""))))) for r in rs if r["model"]]
    print(f"{v:24} {len(scored):>4} {wer:6.3f} {ter:6.3f} {rw:6.3f} {rt:6.3f} {sum(not r['accepted'] for r in rs):>4} "
          f"{sum(r['model'] for r in rs):>5} {ms[len(ms)//2]:7.0f} {ms[min(len(ms)-1, len(ms)*9//10)]:7.0f} "
          f"{(statistics.median(per) if per else 0):7.1f} {sum(r.get('inTokens') or 0 for r in rs):6} {sum(r.get('outTokens') or 0 for r in rs):6}")

if detail:
    for r in by.get(detail, []):
        ref = refs.get(r["id"])
        if ref is None: continue
        e = ed(tokens(r["inserted"]), tokens(ref))
        if e == 0: continue
        print(f"\n[{r['id']}] ter-edits={e} accepted={r['accepted']} ms={r['ms']:.0f} {r.get('error') or ''}")
        print("  RAW:", unmark(raws.get(r["id"], ""))[:300])
        print("  REF:", ref[:300])
        print("  OUT:", r["inserted"][:300])
