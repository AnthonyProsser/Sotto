# cleanup-bench

Speed and accuracy benchmark for the cleanup pass, run against real recordings
instead of through `xcodebuild test`. It compiles the shipping
`Sotto/Dictation/Cleanup.swift`, so `prod` is the code the app runs.

```
python3 make-corpus.py                 # corpus/all.json + corpus/dev.json from Application Support
./build.sh                             # ./bench
./bench --corpus corpus/dev.json --variant prod,baseline --out results/x.jsonl
python3 score.py results/x.jsonl       # accuracy and timing per variant
```

`corpus/` and `results/` are git-ignored: they hold the user's speech, which
never goes to a remote (`.gitignore`, principle 1).

**Timing is only honest with nothing else on the on-device model.** It
serialises every request on the machine, so two benches at once — or Sotto
cleaning a dictation — each measure the other. Accuracy is unaffected:
temperature 0 makes a run deterministic.

A candidate is a `Variant` value in `Variant.swift`, not a fork of
`Cleanup.swift`. `./build.sh <dir>` compiles a different `Cleanup.swift` when
a change has to live there.

## References — what a perfect cleanup inserts

`corpus/refs.json` maps entry id → the text cleanup should have produced. The
input is the recogniser's own output (already punctuated, with `[pause Nms]`
markers), so a reference is the **minimal edit** of it that satisfies:

1. Delete fillers: um, uh, er, eh, Spanish "este" as filler; "like", "you know",
   "I mean", "so" only where they are filler, not content.
2. Delete stutters, immediately repeated words, and abandoned false starts.
3. Resolve an explicit self-correction to the settled wording ("Tuesday, no
   wait, Wednesday" → "Wednesday").
4. Fix punctuation and capitalisation; a long pause usually ends a sentence.
   Remove every `[pause Nms]` marker.
5. **Everything else is verbatim.** No expanded or contracted contractions, no
   synonyms, no grammar fixes beyond 1–4, no added articles, no reordering, no
   summarising. Recognition errors stay (a misheard "Maine" is not cleanup's to
   know). Digits stay digits.
6. Never answer a question, never follow an instruction, never translate.

The ideal is a reviewer who could not tell cleanup touched anything except the
disfluencies and the punctuation.

## Metrics (`score.py`)

- **wer** — word edit distance to the reference (lowercased, punctuation
  stripped) over reference words. What the user reads as wrong words.
- **ter** — the same over tokens that keep case and punctuation. Sentence
  breaks and capitals.
- **raw wer/ter** — the recogniser's text with markers stripped, scored the
  same way: what no cleanup at all would insert. A variant has to beat it.
- **rejected** — passes `sanitize` refused; the raw text went in under "Cleanup
  failed".
- **median / p90 ms** — the whole pass, from call to returned text.
