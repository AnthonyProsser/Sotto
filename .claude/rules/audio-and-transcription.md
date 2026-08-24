# Audio and transcription — capture, chunking, timings, and what the HUD is allowed to say

**Open this before touching capture, VAD, chunking, the transcription pipeline, word timings, click-to-seek, or the HUD's content.** `CLAUDE.md` §0.1 routes you here.

Each rule below has a reason attached. The reason is load-bearing: a rule without one gets rationalised away at 2am.

---

## 1. Chunking — and why most of this no longer applies

**Read §1.0 before §1.1. The rules below it describe the Parakeet/FluidAudio path, which does not ship in v1 at all** — §1.1 is kept as history for a second backend that is not currently being built.

### 1.0 STT is Apple's Speech framework, exclusively (2026-08-19, `DECISIONS.md`)

**This is the whole of v1's STT. Parakeet, FluidAudio, Silero, and Whisper do not ship in any form.** A non-Apple backend stays possible in a later version behind §2.2's "audio in, timestamped text out" interface, but nothing in v1 is built to receive one — do not add a second engine, a backend-selection setting, or a chunking stage on its behalf.

`SpeechAnalyzer` + `SpeechTranscriber`. **Sotto does not chunk audio for this backend** — the analyzer segments and streams by itself. Measured on the reference machine: 545.6 s of audio in 7.89 s (**69× realtime**), **110 finalized results emitted progressively**, first one at **0.507 s**, **95 MB resident and flat**, per-word timings at ~60 ms with start and end, native punctuation and capitalisation.

**The models are already on the machine and `reserve()` is the gate, not a download.** ~1.0 GB of system ASR assets ship with macOS for its own dictation. `AssetInventory.status(forModules:)` returning `.supported` means **"not claimed by this app,"** not "not present" — one `AssetInventory.reserve(locale:)` flips it to `.installed` with no network access. Reservation is **per-process**, so Sotto reserves at startup; the cap is `maximumReservedLocales` (5), and `release(reservedLocale:)` frees a slot.

**Four API traps, all verified against the installed SDK:**

- **`installedLocales` is not a safe gate.** It reported `en_US` installed on a machine where `status(forModules:)` said `.supported` for that same locale. Gating on it and calling `downloadAndInstall()` downloads a model the machine already has.
- **A transcriber module belongs to one `SpeechAnalyzer` for its lifetime.** Handing the same `SpeechTranscriber` to a second analyzer traps inside the framework and kills the process — `EXC_BREAKPOINT` at `TranscriberCommon.worker.setter`, from `prepareModulesIfNeeded()`, on the **second dictation of every launch** (2026-08-19). Build a fresh module per recording; keep the locale and the resolved format, not the module.
- **A module's `results` sequence does not reliably end when the analyzer does, and waiting on it unbounded wedges the app.** `finalizeAndFinishThroughEndOfInput()` returning is the analyzer's statement that every result has been delivered, so `results` should finish with it. Measured 2026-08-24: after several short recordings in quick succession it sometimes never finishes, and the task draining it suspends forever — which held `Dictation.pipeline` non-nil, left the HUD on screen, kept the menu-bar icon reporting `recording`, and made every later gesture a silent no-op until relaunch. **Bound the wait and cancel the draining task** (`Transcription.resultGrace`, 2 s against a healthy 0–1 ms); the draft then returns 1 ms later with whatever was collected. **`analyzer.cancelAndFinishNow()` does not end the sequence** — tried as the escalation first, and 4 of 5 rounds still wedged. The same applies to `SpeechDetector.results`. This is the one place in the dictation path where a bounded wait is correct rather than a watchdog: the input stream has been finished and finalize has returned, so the only missing signal is Apple's.
- **`SpeechTranscriber.Preset.offlineTranscription` does not exist.** The five real presets are `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription`, `.timeIndexedProgressiveTranscription`. `analyzeSequence(from: AVAudioFile)` *does* exist and is the file convenience.

**`SpeechDetector` is preinstalled**, which is what retires Silero. It is a second module on the same `SpeechAnalyzer` as the transcriber, built fresh per recording (same one-analyzer rule), with `reportResults: true`. Silence ranges ≥ 80 ms become pause markers on the draft and go into the history sidecar; they are also inlined in the raw transcript as `[pause Nms]` for cleanup (§4.6). `SpeechTranscriber` supports 30 locales, 17 installed out of the box (`en_*`, `es_*`, `fr_*`); the other 13 are real downloads. **`DictationTranscriber` covers 54** and is the fallback past those 30 — see §5, which is where coverage and behaviour live.

**Both STT and the LLM run on the ANE. Neither touches the GPU** (measured 2026-08-19, `DECISIONS.md`). STT powers the ANE for 96.2 % of its window; Foundation Models holds it at 100 %; the GPU stays at idle baseline for both. **That inverts §2.2's reason for choosing Parakeet** — the ANE was chosen precisely because it does not contend with an LLM on the GPU, and under the all-Apple stack both are on the ANE instead.

**What follows from it is a rate rule, not a ban:**

- **Microphone-rate dictation may overlap Foundation Models freely.** STT at 1× realtime costs cleanup +5 % latency, inside run-to-run drift. Dictation and cleanup are sequential anyway.
- **File and import transcription is serialised around active chat generation.** At 60× realtime it costs cleanup **+76 %** and loses **24 %** of its own throughput. Slice 14 does not run an import against a generating chat response; it waits.

Bounds: one machine, no `sudo`, so this is ANE occupancy and latency rather than per-block power. ANE power-down has hysteresis, so a "powered" reading overhangs the work that caused it — use the client-count delta if you re-measure.

### 1.1 The Parakeet path — history only, not a v1 backend

**`maxChunk` = 240,000 samples ≈ 15 s at 16 kHz (§4.2).** It is not a chosen number — it is FluidAudio's internal `ChunkProcessor` threshold, and the overlap-and-reconcile design exists to stay under it. **With FluidAudio gone, so is the threshold**; chunking is now a per-backend detail *below* §2.2's "audio in, timestamped text out" interface, not a pipeline stage. Whisper's hard 30 s receptive field would still force chunking, but that is the *model's* constraint and belongs in a Whisper backend.

**If Parakeet ever returns it needs CoreML, not FluidAudio and not MLX.** MLX has no ANE backend, so it puts STT on the GPU against the LLM; FluidInference built `swift-parakeet-mlx` and abandoned it on performance. FluidAudio is one CoreML packaging among several.

**A recording that ends under 15 s is always transcribed whole (§4.2)** — Parakeet path only.

## 1.2 Capture — the armed window, the persistent tap, and the buffer that is not a knob

**All three measured 2026-08-24; the reasoning is in `DECISIONS.md`, and only what a future session needs to not undo is here.**

**The microphone opens on the Right Cmd key-down, before the gesture is classified.** `Dictation.arm()` starts capture and puts the HUD on screen at zero alpha inside the 250 ms the user is holding the key anyway; `start()` then adopts the already-running stream. **The transcriber is never touched on key-down** — a module belongs to one analyzer for its lifetime (§1.0), so building one speculatively would burn it on a press that turns out to be a chord.

**There is one discard path and it is `Dictation.abort()`.** A release under the threshold, a chord, an Escape, and the second-tap window expiring all route to it. Do not add a second one; the only difference between the cases is which of `pipeline` and `armed` was live.

**`arm()` is guarded on the microphone grant Sotto already holds, and that guard is not optional.** `engine.start()` blocks its caller until the TCC dialog is answered — 45 s, measured — so an unguarded speculative start would hang the tap thread's callee on a bare Right Cmd at first run. Unauthorized, arming does nothing and the real gesture asks at first use, exactly as §2.4 requires.

**The capture tap is installed once per device, not once per recording**, and `engine.prepare()` runs after `engine.stop()` rather than before `engine.start()`. Reinstall on a device or format change only — §4.8's rule that a device change must not drop an in-flight recording is what that guard protects.

**`installTap`'s `bufferSize` is ignored.** 4096, 1024, 512 and 256 all deliver 4800-frame buffers — 100 ms at 48 kHz — above a device IO buffer of 512. **Do not tune it.** Time-to-first-audio cannot fall below `engine.start()` plus one 100 ms buffer without capturing from an `AudioUnit` directly instead of `AVAudioEngine`, which is a rewrite of the capture layer.

**What remains is hardware.** `engine.start()` is ~55 ms warm and ~160 ms cold after every in-process cost around it was removed. That is CoreAudio bringing the device up; there is no further lever, and the armed window is what takes it off the path the user can feel.

---

## 2. Timings and seeking

**On the Apple path, timings come from the `.audioTimeRange` attribute on the result's `AttributedString` runs** — per word, ~60 ms, start and end. `buildWordTimings(from:)` was FluidAudio's and is gone with it. **The `startTime`-only rule survives on its pre-roll argument** (below); the FluidAudio #381 reason for it does not apply here.

**Word timings: `startTime` only (§9.3).** `endTime` is never read. This sidesteps the FluidAudio #381 bug class and is independently validated by the measurement: word starts hit a floor (all error early, bounded at about −320 ms, 100 % within ±500 ms), while sentence *ends* smear to +1075 ms at long pauses. Read the `.audioTimeRange` run attribute and store the start; do not build an aligner.

**Click-to-seek ships at zero offset (§9.3).** Early is pre-roll, not error: landing half a second before the clicked word gives the beat of lead-in an audio editor adds on purpose. Keep a config hook; ship at zero. The original form of this rule rejected Parakeet's `TDT_EMISSION_DELAY_FRAMES` as a way to buy ~80 ms of shift — that knob went with the Parakeet path, but the reasoning that rejected it stands on its own and is why the hook is not wired to anything on the Apple path either.

---

## 3. The HUD's entire vocabulary

**A waveform, two completion messages, and an error morph. That is all of it.** The waveform is mandatory and has no toggle. Audio-side failures surface here — transcription failure, audio model load failure, cleanup failing **mid-pass**, an AX write rejected (§4.5). See `.claude/rules/design.md` §10 for the full routing table.

**One case that looks like it belongs here and does not: the cleanup model being unavailable.** `SystemLanguageModel.availability != .available` is a configuration state, knowable before the gesture fires, and it routes to Settings → Dictation with a banner instead (2026-08-19, `DECISIONS.md`). **Slice 3 designs the error morph with no model-unavailable string in it.** The HUD says something went wrong with work the user just started; it does not report what the machine was never set up to do.

The HUD reports through the idle / not-idle signal, one of the four cross-slice threads — see `.claude/rules/slices.md`.

---

## 3.1 Cleanup's default model, and warming it

**Cleanup defaults to Apple's on-device model** — `SystemLanguageModel`, `FoundationModels` — so Sotto punctuates dictation at first run with nothing downloaded (2026-08-19, `DECISIONS.md`). It stays per-profile per §4.6; this is a default, not a lock. Use `Guardrails.permissiveContentTransformations`, **not** the default set: the default guardrails refuse on the user's own dictated content, and an app that declines to punctuate what someone just said because it contained profanity or a medical term is not a dictation app.

**Prewarm at launch, not when the gesture arms and not when cleanup starts** (2026-08-23, `DECISIONS.md`; it armed the gesture until then). Measured on the reference machine: the first request after launch costs ~3.5 s, every request after it ~850 ms. Un-prewarmed, the first dictation of each session pays that 3.5 s in the gap between speaking and seeing text. `LanguageModelSession.prewarm(promptPrefix:)` is the hook, fired from `Dictation.prepare()` alongside the HUD and audio warm-ups, and **slice 3 leaves the seam even though slice 11 fills it** — the gesture is slice 2/3 and cleanup is slice 11, so without it slice 11 reaches back into gesture handling.

**Prewarming is never `Activity.Contributor.cleanup`.** The icon reports that Sotto is awake (§14.8); a speculative warm-up the user did not ask for is not that. Set the contributor when a pass actually runs.

**Cleanup owns its own `LanguageModelSession` and never shares chat's.** Reusing one session for two simultaneous requests throws `concurrentRequests` deterministically; two distinct sessions both complete (2026-08-19, `DECISIONS.md`). **There is no parallel speedup** — the model serialises underneath — so a cleanup pass firing while a chat response generates costs roughly a full request on whichever the user is waiting for. Full numbers in `rules/models-and-network.md` §1.1.

**4096 is the whole window, prompt and output.** Confirmed at runtime, not just in the interface. Dictation is unaffected — §4.6 measures a five-minute latched session at ~1,000 tokens — but §4.6's chunked-cleanup formula for long imports computes against a much smaller number than an MLX model would give, so imports get materially more boundaries and each one is a chance to split a self-correction.

**Known instruction gap, found in testing:** the model punctuates from pause markers well (240 ms → comma, 780 ms and 1120 ms → sentence breaks, verified), removes fillers, and fixes stutters — but it *preserves* self-corrections rather than resolving them, keeping "no wait, actually" instead of dropping the abandoned first choice as §4.6 asks. That is prompt wording, not a model limit. Fix it in slice 11's instructions rather than rediscovering it as a complaint.

**Fill `AudioEntry.cleaned`, `.profile`, and `.languages` in this slice.** Slice 5 writes them empty so the sidecar shape is already honest. Cleanup produces `cleaned`; the active profile's name is `profile`. `languages` has no Apple equivalent of Whisper's per-segment language tokens — pick the source here, do not invent one in passing. The type lives in `Sotto/History/AudioHistory.swift`.

---

## 4. Cut, and staying cut

| Deleted | Why it was cut |
|---|---|
| **Live transcript layer in the HUD** | Deleted, not defaulted off. It would show raw text that cleanup then rewrites, so what the user read would not be what got inserted — and it would force per-chunk results to surface before §4.2's whole-buffer pass could correct them |
| **Live-streaming insertion** | Cut from v1 entirely. It was specified as available-when-cleanup-is-off, which made the interaction between two settings load-bearing for a feature nobody had used. Cleanup stays optional and ships; streaming does not. **Dictation always dumps at the end** |
| **Sentence-following playback highlight** | Cut. Seeking is navigation; a following highlight is decoration. The real uses — spot-checking a suspicious transcript, finding the one thing someone said in an hour-long import — are both "take me to that moment." Independently validated by the `endTime` smear finding (§9.3) |
| **Binoculars AI-detection** | Gone, not coming back |

---

## 5. The two Apple transcribers — coverage and behaviour

**`SpeechTranscriber` is the engine. `DictationTranscriber` is the fallback past its locale list.** Both run under `SpeechAnalyzer`, both are on-device, and both install via `AssetInventory` into system storage outside the app sandbox — no app-size cost, no weights, no KV geometry, nothing for §2.3's memory estimate to compute. Same shape as the Foundation Models entry in `rules/models-and-network.md` §1.1.

```swift
let transcriber = SpeechTranscriber(locale:, transcriptionOptions:, reportingOptions:, attributeOptions:)
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence:)
// ...
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

| | `SpeechTranscriber` | `DictationTranscriber` |
|---|---|---|
| Locales | **30** supported, 17 installed out of the box | **54** supported |
| Word timings | `.audioTimeRange`, ~60 ms, start and end | `.audioTimeRange` with `.timeIndexedLongDictation` — **verified, 23 of 23 runs timed** |
| Punctuation and capitalisation | **Native** | **None** |

**The 54 is why no non-Apple backend ships in v1 (2026-08-19, `DECISIONS.md`).** Apple's own fallback nearly doubles the locale list — Russian, Dutch, Hindi, Arabic, Polish, Thai, Vietnamese, Ukrainian among them — and every locale probed where `SpeechTranscriber` returned `.unsupported` came back `.supported` there. Whisper's remaining advantage is the ~99-locale tail, which does not buy a second engine and a chunking stage.

**Where `DictationTranscriber` runs, cleanup supplies the punctuation and the capitalisation.** On the same clip `SpeechTranscriber` returns *"So the thing is, I think we should ship the smaller model first."* and `DictationTranscriber` returns the same words with neither. That is not a gap Sotto has to close — §3.1's cleanup pass is already running and already punctuates from pause markers. **It does mean the fallback path is harder-dependent on cleanup than the primary one**, so a profile that turns cleanup off gets unpunctuated text on those locales. Say so in the setting rather than discovering it as a bug report.

**Accuracy, stated as the floor it is:** WER **1.71 %** on the reference clip — 26 errors in 1518 words, of which 18 are `and`→`end` and 7 are `first`→`1st`. **That was `say`-synthesised audio with no noise, accent, or disfluency, so it is a floor and not a real-microphone figure**, and it is explicitly not a Whisper comparison. **Apple normalises ordinals to digits**, which is what the `1st` count really measures; slice 11's cleanup instructions are writing against text that already carries house formatting.

**Two things Apple's own sample code recommends that Sotto has cut, and they stay cut (§4):**

- `.volatileResults` — the intermediate live guess. This is §4's **live transcript layer** and **live-streaming insertion**. Only the `isFinal` path is in scope.
- Highlighting `audioTimeRange` runs during playback. This is §4's **sentence-following playback highlight**. Click-to-seek (§2) is the only playback-time use of timing data that survived.

**Platform coverage:** iOS/iPadOS/macOS/tvOS/visionOS, not watchOS — moot; Sotto is macOS-only (`CLAUDE.md` §2).

---

## 6. Stack, for reference

| | |
|---|---|
| STT | **Apple `SpeechAnalyzer` / `SpeechTranscriber`, exclusively** (2026-08-19). `DictationTranscriber` past its 30 locales. **No non-Apple backend ships in v1** — Parakeet TDT v3, FluidAudio, and Whisper are all out |
| VAD | **`SpeechDetector`**, preinstalled, wired in slice 5. Silero retired with the Parakeet path |
| Compute | **ANE, shared with Foundation Models.** Mic-rate STT may overlap the LLM; import-rate STT is serialised around chat generation (§1.0) |
| Storage | Audio as Opus @ 24 kbps in CAF (`audio.caf` + `entry.json`). Obsidian is not a feature |
| Retention | Audio: ring of 8 by default, configurable, with a pin flag. Imports auto-pinned |

---

## 7. Open question that lands here

**Cleanup reasoning: toggle, and default** — open issue 4 in `.claude/rules/open-questions.md`. Lands in slice 11. Undecided; ask, do not pick.
