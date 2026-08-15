# Audio and transcription — capture, chunking, timings, and what the HUD is allowed to say

**Open this before touching capture, VAD, chunking, the transcription pipeline, word timings, click-to-seek, or the HUD's content.** `CLAUDE.md` §0.1 routes you here.

Each rule below has a reason attached. The reason is load-bearing: a rule without one gets rationalised away at 2am.

---

## 1. Chunking

**`maxChunk` = 240,000 samples ≈ 15 s at 16 kHz (§4.2).** Staying under it is a **requirement**, not a target. It is FluidAudio's internal `ChunkProcessor` threshold: cross it and seam handling is handed to FluidAudio, which is exactly what this design refuses. Measured word loss at FluidAudio seams is ~0.17 % — one span in 589 words, ~15 spans per hour. Sotto's overlap-and-reconcile design (§10.3) exists to catch that class of drop, and deferring to the library forfeits it. This is also why the old 30 s whole-buffer rule is gone. `chunkFloor` is 8 s, tunable, always < 15 s.

**A recording that ends under 15 s is always transcribed whole (§4.2).** Any pause found between `chunkFloor` and 15 s starts speculative work that gets discarded if the utterance turns out short. That waste is deliberate — the alternative is waiting 15 s before starting any transcription on long dictation, which is the case that actually needs the head start.

---

## 2. Timings and seeking

**Word timings: `startTime` only (§9.3).** `endTime` is never read. This sidesteps the FluidAudio #381 bug class and is independently validated by the measurement: word starts hit a floor (all error early, bounded at about −320 ms, 100 % within ±500 ms), while sentence *ends* smear to +1075 ms at long pauses. Parse `buildWordTimings(from:)` and store; do not build an aligner.

**Click-to-seek ships at zero offset (§9.3).** `TDT_EMISSION_DELAY_FRAMES=0` would shift timestamps ~80 ms later for free and is **deliberately unused** — that knob corrects emission delay against CTC peaks, and repurposing it conflates two concerns that will diverge. Early is pre-roll, not error: landing half a second before the clicked word gives the beat of lead-in an audio editor adds on purpose. Keep a config hook; ship at zero.

---

## 3. The HUD's entire vocabulary

**A waveform, two completion messages, and an error morph. That is all of it.** The waveform is mandatory and has no toggle. Audio-side failures surface here — transcription failure, audio or cleanup model load failure, cleanup failing mid-pass, an AX write rejected (§4.5). See `.claude/rules/design.md` §10 for the full routing table.

The HUD reports through the idle / not-idle signal, one of the four cross-slice threads — see `.claude/rules/slices.md`.

---

## 4. Cut, and staying cut

| Deleted | Why it was cut |
|---|---|
| **Live transcript layer in the HUD** | Deleted, not defaulted off. It would show raw text that cleanup then rewrites, so what the user read would not be what got inserted — and it would force per-chunk results to surface before §4.2's whole-buffer pass could correct them |
| **Live-streaming insertion** | Cut from v1 entirely. It was specified as available-when-cleanup-is-off, which made the interaction between two settings load-bearing for a feature nobody had used. Cleanup stays optional and ships; streaming does not. **Dictation always dumps at the end** |
| **Sentence-following playback highlight** | Cut. Seeking is navigation; a following highlight is decoration. The real uses — spot-checking a suspicious transcript, finding the one thing someone said in an hour-long import — are both "take me to that moment." Independently validated by the `endTime` smear finding (§9.3) |
| **Binoculars AI-detection** | Gone, not coming back |

---

## 5. Stack, for reference

| | |
|---|---|
| STT | Parakeet TDT v3 on the ANE (does not contend with the LLM on GPU); Whisper large-v3-turbo alternate |
| VAD | Silero, 32 ms frames |
| Storage | Audio as Opus @ 24 kbps (~0.18 MB/min vs WAV's ~1.9) |
| Retention | Audio: ring of 8 by default, configurable, with a pin flag. Imports auto-pinned |

---

## 6. Open question that lands here

**Cleanup reasoning: toggle, and default** — open issue 4 in `.claude/rules/open-questions.md`. Lands in slice 11. Undecided; ask, do not pick.
