# Sotto — Specification

*From* sotto voce *— "in a low voice."*

**Status:** Draft v0.18 — design system resolved to a template; five open issues
**Platform:** macOS 26 or later, Apple silicon only
**Language:** Swift / AppKit, native
**License intent:** Open source
**Author:** Anthony Prosser

**Changes since v0.17:**

- **The token sheet is a template, not a document.** Slice 0 delivers the structure, the resolution rules, and the provenance discipline — not a filled-in set of values. Each token is authored the first time a feature needs it and never before (§14, `sotto-tokens.md`).
- **Reserved states are deleted.** `state.error` and `state.network` are both gone, which empties tier 3 and collapses the token architecture to inherited and authored (§14.2, §14.3).
- **Errors route to the surface that owns the work**, not to a global state. Dictation and audio-model failures appear in the HUD; chat and LLM failures appear in the chat; file-transcription failures appear in the main window. There is no universal error treatment (§14.3).
- **Network-touching features are no longer visibly marked.** Opt-in and off-by-default carry principle 1; a permanent badge did not add to them (§1, §6.1).
- **Disabled treatment has two patterns**, split by whether there is a control to disable: system disabled state plus tooltip for controls, full-screen scrim for the screenshot gesture (§7.2, §14.7).
- **The menu bar icon is idle / not idle**, not idle / recording. It reports that Sotto is awake, and macOS's own microphone indicator carries the mic tell (§14.8).
- **The zero-outbound guarantee is gone**, and what replaces it is a consent rule rather than a shorter list: every outbound connection is either something the user just did or something the user switched on. That test, not an enumeration, is what permanently rules out telemetry, crash reporting, analytics, and remote config — nobody asks for those, so they can never pass it (§1).
- **Sotto downloads models** (§7.4). A curated list plus a pasted `repo_id`, Hugging Face for MLX weights and `ollama pull` delegated to Ollama, with §2.3's memory estimate shown *before* the download rather than after. No background re-download, no model auto-update, no phoning home to refresh the list.
- **The app updates itself.** Sparkle, automatic checks default on, weekly, disableable; `SUEnableSystemProfiling` explicitly off; EdDSA verification mandatory (§8.4, §10.6).
- **An optional cloud fallback is deferred, not rejected** — recorded in §12 as decided-in-principle so a later version does not re-argue whether it is allowed. It is, because it requires the user to paste a key. It is not in v1.

**Changes since v0.16:**

- **Hardware never gates a feature.** Model capability does — and vision is the only capability Sotto gates on. The app predicts memory cost and warns; the user picks any model at their own risk (§1, §2.3, §7.2).
- **Permissions are just-in-time.** Three on first run, Screen Recording deferred until the first screenshot (§2.4).
- **Insertion is two strategies**, AX then clipboard paste. The CGEvent Unicode strategy is deleted with the human-typing MCP, which is now an unrelated project. No focused field → clipboard only, with HUD confirmation (§3).
- **Chunking rewritten.** Nothing under a floor is chunked; the first boundary is the first pause after the floor; anything that ends before 15 s is discarded and re-transcribed whole (§4.2).
- **No live HUD.** The live raw transcript layer is deleted, not defaulted off. The HUD is a waveform, plus "Copied to clipboard" when relevant (§4.5).
- **Live-streaming insertion deleted from v1** entirely. Cleanup remains optional and stays (§4.4, §4.6).
- **Binoculars AI-detection and the Out-of-scope section are deleted** from the document.
- **The compose bar has a send button** — the design process found the bar reads as unfinished without one (§5.8).
- **One bundled MCP server**, web search, on the 2026-07-28 MCP revision (§6).
- Model breadth is now a stated goal: many LLM and voice-model families, not one (§2.2).
- §8–§14 compressed to decisions; the §9.3 timestamp study is reduced to its result.

---

## 1. Product summary

A menu-bar-resident macOS app that combines Wispr Flow-style system-wide dictation with a Claude-Desktop-style chat, both running entirely on-device. Two global gestures drive everything:

- **Hold or double-tap Right Command** → dictate. With text selected, routes to the chat as a question instead.
- **Double-tap Option** → open the overlay chat, seeded with the current selection if there is one.

Network access is opt-in and never implicit: models are downloaded when the user asks for one (§7.4), MCP tools reach the network only once the user enables the server (§6), and the app checks for its own updates on a schedule the user can switch off (§10.6). Nothing else connects, and no content is ever what travels.

### Design principles

1. **Local by default, and nothing happens behind the user's back.** No content leaves the machine — not audio, not transcripts, not chats, not attachments. Sotto does make outbound connections, and every one of them is either something the user just did or something the user switched on:

   | Path | Consent | §|
   |---|---|---|
   | Model download | The user picks a model and starts the download | §7.4 |
   | Enabled MCP tools | The user enabled the server; disabled out of the box | §6 |
   | Update check | Default on, weekly, one toggle | §10.6 |

   **The rule is consent, not count.** An earlier version of this principle claimed zero outbound connections, then a closed list of two; both were the wrong shape, because the honest constraint was never about how many connections exist. It is that none of them is a surprise. That test is what rules out telemetry, crash reporting, analytics, and remote config permanently — not because they are on a list, but because nobody asks for them, so they can never pass. Anything that would connect without the user having done something or turned something on does not get built.

   Every MCP is disabled out of the box; enabling one is a deliberate act taken in settings, and nothing in the chrome marks it afterwards. A permanent badge was specified through v0.17 and cut — a marker seen on every launch after a choice made once is decoration, and it competes for the same peripheral attention the HUD needs.
2. **Gestures, not windows.** The main window is for reviewing history and changing settings, nothing else.
3. **Predict, don't gate.** Hardware never disables a feature. The app estimates what a model and context length will cost and says so; the user may load anything and accept the consequences. The one exception is model *capability*: a model without a vision tower cannot see an image, so image features gray out with that reason (§7.2). That is a fact about the model, not a judgment about the machine.
4. **Built for one user first.** Correctness and feature completeness beat broad appeal.
5. **An extension of macOS, not another program.** Where the system already makes an appearance decision, Sotto inherits it (§14). Sotto is visually indistinguishable from system chrome; that is the intent, not a side effect.
6. **Model-agnostic.** Sotto is a shell around whatever runs locally today. Assume the best local LLM and the best local speech model will both change more than once a year, and that they may converge — Gemma 4's E2B/E4B/12B variants already accept audio and do ASR directly, and Google ships an offline dictation app built on exactly that. Nothing in the pipeline may assume "the STT model is Parakeet" or "the LLM is text-only."

### Reference hardware

MacBook Neo, 8 GB unified memory. This is the machine Sotto is developed against and the basis for the worked example in §2.3 — it is not a floor that anything checks at runtime.

### Software floor

macOS 26, so Liquid Glass, continuous corners, and concentric radii come from real system APIs rather than hand-rolled `NSVisualEffectView` approximations (§14.1). This is a genuine floor: macOS 14 and 15 cannot run Sotto. It also fixes which SF Symbols and materials exist, so it is upstream of every decision in §14.

---

## 2. Architecture

### 2.1 Process model

Single application process. No helper daemons, no bundled Python, no external runtime requirement.

The one bundled MCP server (§6.1) runs **in-process** over a loopback transport — fewer executables to sign and notarize, and no benefit to separating it. Same protocol either way, so third-party MCPs over stdio still work normally.

### 2.2 Inference runtime

Roles, not products. Each row names today's default; none of them is load-bearing.

| Role | Default today | Notes |
|---|---|---|
| LLM (primary) | **MLX via `mlx-swift`**, embedded | No external dependency, unified-memory friendly |
| LLM (alternate) | OpenAI-compatible adapter | Auto-detects Ollama `:11434`, `llama-server`, LM Studio |
| STT | **Parakeet TDT v3** (CoreML, ANE) | Multilingual, ~60× realtime, runs on ANE while the LLM holds GPU |
| STT (alternate) | Whisper large-v3-turbo | Better code-switching, per-segment language tokens, GPU-resident |
| VAD | Silero | ~2 MB, CoreML |

**ANE/GPU split matters.** Parakeet on the Neural Engine does not contend with the LLM on the GPU — the main reason to prefer it over Whisper as the default.

**Audio-capable LLMs are a first-class future path, not a curiosity.** Gemma 4 E2B, E4B, and 12B accept audio natively and perform ASR and speech translation without a separate ASR stage. If a single audio-in LLM ever beats Parakeet + a cleanup pass on accuracy *and* fits memory, the pipeline should be able to collapse to it by changing a profile's STT model — which means the STT interface is "audio in, timestamped text out," and nothing above it may depend on Parakeet specifics.

### 2.3 Memory estimation

The app does not decide what fits. It **predicts** and displays, next to every model and context-length control:

```
estimate = weights + KV + ~15% runtime overhead
KV bytes = 2 * n_layers * n_kv_heads * head_dim * ctx_len * bytes_per_element
```

Rows turn amber past ~60 % of physical RAM and stay selectable. Loading past that is the user's call.

Worked example on the 8 GB reference machine, with a small audio-capable LLM:

| Component | Size |
|---|---|
| Gemma 4 E2B, 4-bit | ~2.5 GB |
| Parakeet TDT v3 | ~0.6 GB |
| KV cache @ 4k context | ~0.2 GB |
| Silero VAD | ~0.002 GB |
| App + UI | ~0.3 GB |
| **Total** | **~3.6 GB** |

Gemma 4 E4B (~5 GB at 4-bit) is the tight-but-usable step up; 12B Unified (~6.7 GB) leaves nothing for a resident STT model and is a "you may, and you will feel it" choice. All three accept audio. Qwen3-VL 4B remains the vision-first alternate.

### 2.4 Permissions

Asked **at first use of the feature that needs them**, never in a wall on first launch. Onboarding shows a status list with a re-check button; it does not demand anything up front.

| Permission | Needed for | Prompted when |
|---|---|---|
| Accessibility | `AXSelectedText` read/write, event tap | First run — the gestures are the app |
| Input Monitoring | `CGEventTap` on raw modifier keycodes | First run |
| Microphone | Dictation | First run |
| Screen Recording | Screenshot mode (§5.6) | First time the user enters screenshot mode |

So a user who never takes a screenshot is asked three times, not four.

The event tap observes **modifier keycodes only** (54/55 for Right/Left Cmd, 58/61 for Option) to distinguish left from right — Carbon's `RegisterEventHotKey` cannot. No key content is read, buffered, or stored.

### 2.5 Event tap threading

**The tap must run on a dedicated thread, not the main runloop.** Hard requirement. If a tap callback blocks the main thread the menu bar goes unresponsive, which breaks quit-as-panic (§10.5) — the only reliable shutdown path. A wedged tap must never take the UI down with it.

### 2.6 Synthetic event hygiene

Sotto posts synthetic keystrokes in two places: Cmd+C for selection fallback (§3) and Cmd+V for clipboard paste (§3). These must be tagged and filtered by the app's own tap, or the hotkey detector fires on the app's own output:

```swift
let src = CGEventSource(stateID: .privateState)
event.setIntegerValueField(.eventSourceUserData, value: MAGIC)
event.post(tap: .cgAnnotatedSessionEventTap)
```

Post to `.cgAnnotatedSessionEventTap`, not the HID tap, for reliable delivery to the frontmost app.

---

## 3. Text insertion

**Two strategies, tried in order — but only when a text field is focused.**

1. **Accessibility API** — write to `AXValue` / `AXSelectedText` on the focused element. Atomic and most robust.
2. **Clipboard paste** — write the transcript to `NSPasteboard`, post Cmd+V, restore. Fallback only.

The CGEvent Unicode strategy is gone. It existed to serve the human-typing MCP, which is now a **separate, unrelated project** (§6.2) — and as an out-of-process MCP it cannot post keystrokes under Sotto's Accessibility grant anyway, so there was nothing left for the strategy to serve.

### No focused field → clipboard, not paste

If focus detection finds no writable element, Sotto **writes to the clipboard and stops**. It does not paste into whatever happens to be frontmost. The HUD's waveform morphs into **"Copied to clipboard"** and fades (§4.5) — that confirmation is the whole reason this path is safe.

### Why paste is second, not first

Save-and-restore of `NSPasteboard` is lossy. Promised/lazy data — a file dragged from Finder, rich content from some apps — cannot be captured and restored, and anything that copies during the window clobbers the restore. SuperWhisper leads with it because it is the universal fallback, not because it is correct.

### Focus detection

Focused app → focused element → check `AXRole` is `AXTextField`/`AXTextArea`, or that `AXValue` is settable.

### Selection reading

`AXSelectedText` on the **focused element**. Fall back to synthetic Cmd+C for Electron apps and browsers that don't expose it. Reading only the focused element is what keeps §4.9 tolerable: a stale selection in a background window cannot hijack dictation.

---

## 4. Dictation

### 4.1 Gesture state machine

Right Command is **never consumed** — it stays a live modifier, so Right-Cmd+C keeps copying.

```
keydown #1 -> begin mic capture immediately (audio is cheap; classify later)
           -> start 250 ms hold timer

  non-modifier keydown while held  -> ABORT, discard, pass through (it's a chord)
  Escape while held                -> ABORT, discard, disarm the gesture
  held past 250 ms                 -> PUSH_TO_TALK
                                      keyup -> stop, transcribe, route
  released before 250 ms           -> AWAITING_SECOND (300 ms window, keep buffering)
      second keydown in window     -> LATCHED
                                      next single tap -> stop
      window expires               -> discard buffer, no-op
```

Starting capture on keydown and deciding retroactively is what makes push-to-talk feel zero-latency despite the ambiguity.

**Escape disarms the gesture, not just the buffer.** Pressing Escape mid-push-to-talk discards the audio *and* marks the current Right Cmd hold as spent. Releasing the key afterwards does nothing — no transcription, no insertion, no HUD. The user should never have to think about how to let go after cancelling.

Both modes then check for a selection (§4.9) to decide where the transcript goes.

### 4.2 Chunking and transcription

Silero VAD on 32 ms frames, ~1 ms CPU. Boundaries land on VAD-confirmed silence only, so chunks never slice mid-word. 200 ms of trailing audio is appended to each chunk.

Two constants govern everything:

| Constant | Value | Why |
|---|---|---|
| `chunkFloor` | 8 s default, tunable, always < 15 s | Below this, chunking costs more than it buys |
| `maxChunk` | 240,000 samples ≈ 15 s at 16 kHz | FluidAudio's internal `ChunkProcessor` threshold |

```
t < chunkFloor                  -> buffer only; no boundary search runs
t >= chunkFloor                 -> boundary search active
first qualifying pause          -> cut chunk 1, begin transcribing it
recording ends before 15 s      -> cancel in-flight chunk, DISCARD it,
                                   transcribe the whole buffer in one pass
t reaches maxChunk without a
qualifying pause                -> force a cut at the largest pause in the window
```

Read that from the other end: **a recording that ends under 15 s is always transcribed whole.** Any pause found between `chunkFloor` and 15 s starts speculative work that gets thrown away if the utterance turns out to be short. That waste is deliberate — the alternative is waiting 15 s before starting any transcription on long dictation, which is the case that actually needs the head start.

**The 15 s ceiling is why the old 30 s whole-buffer rule is gone.** A whole-buffer pass over 30 s of audio would hand the job to FluidAudio's internal chunker, which is precisely what this design refuses. Staying under `maxChunk` guarantees `ChunkProcessor` never engages, so **all seam handling is Sotto's own**. Measured word loss at FluidAudio seams is ~0.17 % (one span in 589 words, §9.3); Sotto's overlap-and-reconcile design (§10.3) exists to catch that class of drop, and deferring to the library forfeits it.

**Chunked results drive nothing visible.** There is no live HUD (§4.5). Chunking is a latency and memory strategy, not a display strategy.

**Open task after this ships:** measure Sotto's chunker against FluidAudio's internal one on the same corpus — WER, dropped spans, and time-to-first-token. The design argument above is a hypothesis until that number exists.

### 4.3 Pause-length calibration (background)

The 600 ms default pause threshold (200–1500 ms slider) is a guess about one speaker. It should become a measurement.

A **background job runs while the machine is idle** — no active dictation, no chat generation, on AC or above a battery floor. It re-examines stored recordings longer than a threshold, re-runs VAD at a range of pause settings, and reports which value best matches the boundaries a human would have drawn. Output is a suggestion in settings, never a silent change.

This is cheap because §9.2 already stores the audio and §4.2 already stores every pause and its duration. Nothing new is recorded to make it work.

### 4.4 Insertion timing

Dictation always **dumps at the end**. Nothing is inserted while speaking.

**Live-streaming insertion is not a v1 feature and is not in this document.** It was previously specified as available-when-cleanup-is-off, which made the interaction between two settings load-bearing for a feature nobody had used yet. Cleanup stays optional and ships in v1; streaming does not.

### 4.5 Dictation HUD

**On, always.** A floating HUD appears near the top of the screen for the duration of every dictation. It shows one thing:

| Element | Purpose |
|---|---|
| Moving audio waveform | Confirms the gesture registered and that audio is arriving |

The waveform is free — RMS off the capture buffer, no ASR involvement. It is also what makes latched mode safe to leave running; a latched session with no visual feedback is a footgun.

**There is no live transcript layer.** It is deleted, not defaulted off. It would have shown raw text that cleanup then rewrites, so what the user read would not be what got inserted — and it would have forced per-chunk results to surface before §4.2's whole-buffer pass could correct them.

**Completion states:**

| Outcome | HUD behavior |
|---|---|
| Inserted at cursor | Fades |
| Written to clipboard | Waveform morphs into "Copied to clipboard", then fades |
| Aborted via Escape | Fades immediately, no message |
| Failed | Waveform morphs into the failure message, holds, then fades |

**The HUD owns every audio-side failure**, because it is the only surface guaranteed to be on screen when one happens. Transcription failing, an audio or cleanup model failing to load, cleanup failing mid-pass, and the AX write being rejected all surface here in the same morph the clipboard message uses. What they say is per-error and specified where the error lives, not centrally (§14.3). Chat and LLM failures do **not** appear here — they belong to the chat (§14.3).

Those four plus the waveform are the entire HUD vocabulary. The only other thing that may appear over the desktop during a Sotto interaction is the overlay's "Attach image" drop affordance (§5.5), which must not resemble any of them.

### 4.6 Cleanup

Runs **after all chunks are transcribed**, never per-chunk. Optional, per-profile (§8.1). Raw transcript is always retained alongside the cleaned version — that is what powers "copy what I said again" in history.

**Cleanup does punctuation as well as wording.** Removing fillers and resolving self-corrections is half the job; the other half is commas, periods, and sentence breaks that the ASR either missed or placed by prosody alone.

**Pauses are handed to the model.** The raw transcript given to cleanup carries VAD pause markers with durations inline. The model should not have to guess where the speaker stopped — §4.2 already measured it, and a 700 ms gap is the strongest available evidence for a comma or a period. This is the single highest-leverage input cleanup gets, and it costs nothing to provide.

Cleanup model, generation parameters, and instructions are all **per-profile**.

#### Chunked cleanup applies to imports, not to dictation

A 5-minute latched session is ~700 words ≈ ~1,000 tokens, which is comfortable at 8 GB. Dictation does not need chunked cleanup.

**Long imports do** (§10.3) — an hour of audio is ~9,000 words. Those are cleaned in **disjoint chunks with no overlap**, split at acoustic pauses:

```
target   = 60% of context window   (leaves room for prompt + output)
window   = target ± 20%
boundary = argmax(pause_duration) within window
```

The largest pause in the window is the boundary; if none qualifies, the largest available is still used — degraded, but better than a blind token split. **No overlap**, because cleanup is local work and a boundary at a real pause is a boundary the speaker actually made. Cleanup instructions re-send with every chunk, so per-chunk fixed overhead counts against the target.

> Residual risk: a self-correction spanning the boundary ("go to the store — no wait, the pharmacy") splits if the pause lands mid-repair. Rare; speakers do not usually pause in the middle of a correction.

### 4.7 Language handling

Parakeet v3 covers English and Spanish with auto-detection. Whisper is the alternate for heavy code-switching.

**Language detection is not an extra LLM pass.** Whisper emits language tokens per segment natively; Parakeet can be probed. An LLM roundtrip per dictation costs 300 ms–2 s at the floor for information the ASR already has. The LLM is invoked for language reasoning only when cleanup is already running (free ride), or when segments disagree about language — which is the actual code-switching signal.

Detected languages are stored as history metadata.

### 4.8 Input device, vocabulary, undo

- Audio input device is selectable, defaulting to the system default. Exposed in the menu bar (§10.1) because it changes with headset use rather than with task. A device change mid-session must not drop an in-flight recording — hold the old device until the gesture ends, then switch.
- User-supplied term list is injected as the decoder's initial prompt. Per-profile.
- Each insertion is a single undo unit — one Cmd+Z removes the whole thing.

### 4.9 Selection routing

**If text is selected, dictation always routes to the overlay chat as a question** — both push-to-talk and latched. The gesture does not change the routing.

Consequences, all intended:

- **"Select text and dictate a replacement" is not a feature.** To replace text, delete it first, then dictate.
- Selected text always becomes chat context, never a dictation target.
- Because selection is read from the **focused element only** (§3), clicking elsewhere to place a cursor deselects first, so the condition clears naturally.

---

## 5. Overlay

### 5.1 Invocation

Double-tap Option. Same disambiguation approach as §4.1.

### 5.2 The draft model

**Nothing is committed to a chat until the message is sent.** Opening the overlay creates a transient draft, not a chat entry.

```
Draft {
  text         : String                       // compose bar contents
  attachments  : [highlighted blocks, images] // shown as chips above the bar
  target       : existing chat | new chat     // resolved at send time
}
```

Opening with a selection shows the compose bar with the selected text **attached as a chip**, visibly pending. With nothing selected, the bar opens empty.

**Drafts persist.** Closing the overlay with an uncommitted draft — text, attachments, or both — preserves it exactly for the next open.

**Attachments are individually removable.** Each chip carries a dismiss control. §4.9 makes accidental attachment easy — any dictation with a stray selection routes here — so chip removal is a correctness requirement, not a convenience.

**Attachments serialize before the text.** Whatever order the UI shows, the message sent to the model leads with its attachments and ends with the typed text. The draft struct listing `text` first is a field order, not a wire order.

#### Highlighted blocks are tagged

A highlighted block is ordinary chat text — not a separate data structure, not a system-prompt injection. But it needs a boundary the model can see, or a pasted paragraph is indistinguishable from the user's own words.

It travels as a **fenced block with an `selection` info string**, carrying the source app:

````
```selection app="Safari"
…the highlighted text…
```
````

Three things fall out of this, which is why it beats an invented delimiter:

- **The escape sequence already exists.** CommonMark's rule is that a longer fence wins, so text containing ``` is wrapped in ````. There is nothing new to invent, and no user input can break out.
- **It matches storage.** §9.1 already stores tool calls as fenced blocks tagged `tool`; this is the same mechanism with a different tag.
- **The UI has an unambiguous thing to style.** Rendering distinct provenance is a parse, not a heuristic.

### 5.3 Target selection and session continuity

| Condition | Default target |
|---|---|
| Within continuity window | Previous chat |
| Window expired, or continuity disabled | New chat |

A **chat picker sits below the compose bar** listing recent chats. Choosing one retargets the draft — typed text *and* all attachments move with it. The picker is always present regardless of the continuity setting; with continuity disabled it is the only route back into an older chat.

| Setting | Default |
|---|---|
| Continuity window | 5 minutes |
| Adjustable / disableable | Yes / Yes |

**The timer resets on send, not on activity.** Opening the overlay, taking a screenshot, or attaching an image does not reset it.

**On send into an existing chat:**

- Attached selection → appended as a **new highlighted block mid-chat**, not a replacement.
- Model switched since that chat's last message → **continue in the same chat with the new model**. A chat can span models, so storage records model per-turn (§9.1).

### 5.4 Dictation inside the overlay

Dictating while the overlay is focused fills the compose bar with an **ordinary message**. It is not automatically about an attached or earlier highlighted block — it may be related or not, exactly as typed input would be.

### 5.5 Images

Requires a vision-capable model (§7.2). Like selections, images are draft attachments and move with the draft if the target changes.

**There is no plain drag-and-drop onto the overlay**, because click-and-drag on the overlay background already means screenshot mode (§5.6) and that gesture cannot mean two things. Two routes exist instead:

1. **Paste.** Cmd+V an image into the compose bar.
2. **Drag, then summon.** Start dragging an image from Finder or a browser, double-tap Option mid-drag, and drop onto the overlay.

Route 2 needs an affordance, since the overlay was not on screen when the drag started: on opening mid-drag the overlay shows an **"Attach image" drop target**. It must be **visually distinct from "Copied to clipboard"** (§4.5) — different shape, different position, different motion. Those are the only two moments Sotto puts a transient message over the desktop, and confusing "I took your image" with "I put your words somewhere else" is the exact failure to design against.

### 5.6 Screenshot mode

```
click background -> overlay hides, screen border glows (screenshot mode)
                 -> drag a region
                 -> release -> image attaches to the draft, overlay returns
```

The glow is **purely decorative and must not appear in the capture**. Set `NSWindow.sharingType = .none` on the glow window — it becomes invisible to ScreenCaptureKit and `CGWindowList`. If driving SCK directly, also pass it to `SCContentFilter(display:excludingWindows:)`.

First entry into screenshot mode is what triggers the Screen Recording prompt (§2.4).

### 5.7 Dismissal

Escape closes the overlay (§10.4 for the full priority stack).

### 5.8 Compose bar contents and sizing

| Element | Notes |
|---|---|
| Add context `+` | Leading. Menu for file, image, screenshot, or current selection. Not merely a file picker |
| Message field | Fills the remaining width. Placeholder only — no label |
| Send button | Trailing |
| Chat picker | Names the current target and opens the recent-chat list (§5.3) |

**Keyboard still sends.** Return sends a non-empty draft; Shift-Return inserts a line break. During IME composition Return remains the input method's and does not send prematurely.

**The send button is present.** v0.15 cut it as redundant with Return. The design process reversed that: with a leading `+` and nothing on the trailing side, the bar reads as unfinished — the field runs to a hard edge and the composition has no close. The button is not the primary path, and it should not be the loudest thing in the bar (§14.3 still rejects a saturated send button), but it belongs there.

**The composer grows before the panel does.** The field starts at one line (44 pt), grows to six lines (180 pt), then scrolls internally. Attachment chips wrap above the field and count toward intrinsic height. The `+` stays vertically centered on the first text line.

**The overlay has no arbitrary empty state.** Height is content's intrinsic height — a short chat is only as tall as its turns, chips, composer, and picker require.

**The panel is bounded.** Maximum height is the lesser of 720 pt and 70 % of the display's usable height. At the cap the conversation body becomes the sole scroll region; chips, composer, and picker stay pinned. New responses stick to the bottom only if the user was already at the bottom; otherwise reading position is preserved and a subtle new-response indicator appears.

> **Open (§12):** what the *bare* bar does as a long draft grows before any conversation exists. The panel's answer — grow, then cap and scroll — is settled. Whether a standalone bar with no chat above it should do the same, or cap sooner, is not.

**No model selector.** The menu bar owns model choice (§10.1); duplicating it spends the bar's most valuable property, its emptiness.

**No microphone button by default.** Dictation is a global gesture; a button duplicating Right Command is redundant in the one app where dictation is a keypress away. Available as an opt-in for users who want the affordance.

---

## 6. MCP servers

### 6.1 Protocol revision

Sotto targets the **2026-07-28 MCP revision**, which is a larger break than a version bump suggests:

| Change | Consequence for Sotto |
|---|---|
| Sessions removed; `Mcp-Session-Id` gone | No per-connection list caching; server state arrives as explicit handles in tool arguments |
| `initialize` / `notifications/initialized` handshake removed | Every request carries protocol version, client info, and capabilities in `_meta` |
| `server/discover` added | Servers must implement it; clients may probe it up front for version selection |
| Multi Round-Trip Requests replace server-initiated requests | A server needing input returns `resultType: "input_required"`; the client retries with `inputResponses` |
| `resultType` required on every result | Results from older servers that omit it are treated as `"complete"` |
| Roots, Sampling, Logging deprecated | Do not implement any of the three. Pass paths as tool parameters; log to stderr |
| SSE resumability removed | A broken stream loses the request; re-issue with a new ID |

**This is why the harness is written against the revision, not against an SDK.** See §12 — the official Swift SDK is at 0.12.1 (May 2026) and implements 2025-11-25, which predates all of the above.

### 6.2 Bundled: one web search server

Runs in-process (§2.1) and **disabled by default**. It is not marked anywhere in the chrome once enabled — see principle 1 for why the badge was cut.

Exactly one server ships. Three shipped in v0.16 — SearXNG, DuckDuckGo, and a bring-your-own-key slot — which is three surfaces to maintain for one capability, and the DuckDuckGo HTML scrape was the fragile one that would break first.

**Verdict: Tavily.** Single call returns search results with extracted page content, 1,000 free credits/month covers personal use outright, and the pricing is per-query rather than per-page-crawled.

Rejected, with reasons worth keeping:

| Option | Why not |
|---|---|
| **Exa** | Closest call. Better neural/semantic discovery and full-text extraction in one call, same 1,000/month free tier. Loses on cost predictability at volume, and its strength — finding pages by meaning — matters less when a 4B model is doing the reading |
| **Brave** | Returns metadata and snippets, not page text |
| **Firecrawl** | A crawler with search attached. Overkill, and priced per page |
| **SearXNG** | Best privacy, but requires the user to run an instance. A self-hosting prerequisite in a bundled default is a non-starter |
| **DuckDuckGo scrape** | Free and keyless, but an HTML scrape is a breakage waiting to happen |

**Extracted page text, never snippets alone.** Small models hallucinate badly from snippets. This is a requirement on any provider, and it is what eliminated Brave.

Provider choice lives behind one config surface, so swapping is a key change and not a code change.

### 6.3 Third-party MCPs

Standard stdio transport (§7.1). No special handling.

The **human-typing MCP is a separate, unrelated project.** It connects here as an ordinary third-party server, shares no code, and needs its own Accessibility permission and signing. It cannot post hotkeys or chords under Sotto's grant, which is one of several reasons §3 no longer has a strategy built for it.

---

## 7. Chat

### 7.1 Harness

Custom, in-app. No suitable Swift harness exists and the loop is small (~400 lines): messages → model → if tool calls, execute, append, repeat.

**Transport is written against the 2026-07-28 revision** (§6.1). Statelessness makes this easier than it was — with no handshake and no session to keep alive, a client is request construction plus `_meta` bookkeeping.

> Small models are uneven at tool calling, but the floor has risen: Gemma 4 has native structured tool use, which Gemma 3 lacked. Keep a prompt-and-parse JSON fallback for models that don't.

### 7.2 Capability gating — vision only

Registry: `model_id → { vision, tools, max_ctx }`

- MLX: detect vision tower presence in `config.json`
- Ollama: `/api/show` returns a capabilities array

**When `vision == false`, image features are unavailable and say so.** This is the only feature Sotto gates, and it gates on the *model*, not the machine — a text-only model cannot see an image, which is a fact rather than a policy. Features stay present in the UI; the user switches models to enable them.

How they say so splits by whether there is a control to disable (§14.7):

| Surface | Treatment |
|---|---|
| Image attachment in the `+` menu | Standard disabled menu item, reason in the tooltip |
| Screenshot mode (§5.6) | A gesture, not a control. The overlay hides as it normally would, then a full-screen scrim states the reason |

Nothing else gates. Per principle 3, memory pressure produces an estimate and an amber row (§2.3), never a disabled control.

### 7.3 Context sizing

Settings show weights + KV + ~15 % overhead as a live estimate beside the context slider, using the formula in §2.3. Amber past ~60 % of physical RAM. Advisory.

### 7.4 Model acquisition

**Sotto downloads models.** Through v0.18 it did not, and the argument for that was principle 1's outbound list. Principle 1 is now a consent rule, and a download the user explicitly starts is the clearest case a consent rule can have — the user picks a model, sees its size, and presses a button. Requiring them to leave the app, find a repository, and place weights on disk by hand did not make anything more private; it made the app harder to start using, which is the whole first-run experience for principle 4's one user.

**Sources, in the order the app should try them:**

| Source | Applies to | Mechanism |
|---|---|---|
| Already on disk | Anything the user placed there | Scan the models directory. Still the first check, and still valid — hand-placed weights keep working |
| Hugging Face | MLX weights | Resolve `repo_id` → file list → download. The `mlx-community` conversions are the practical target |
| Ollama | Anything Ollama serves | `ollama pull`, delegated. Sotto does not re-implement it; Ollama is already a local process (§2.1) |

**A curated list, not a search field.** Sotto ships a short list of known-good model IDs with their sizes, quantizations, and vision flags, and the user can also paste an arbitrary `repo_id`. A full-text model search is a browsing surface for a catalogue that changes weekly and is somebody else's product; the list plus a paste field covers picking a model without Sotto becoming a model browser.

**The memory estimate is shown before the download, not after.** §2.3's formula already computes weights + KV + overhead from a model's config, and the download screen is the one place that estimate can change a decision — after the download it is 4 GB of regret. Amber past ~60 % of physical RAM, same threshold as §7.3, still advisory per principle 3.

**Downloads are background jobs**, with the same shape as §10.3's stitcher: progress in the surface that started them, cancellable, resumable across launches, and not blocking anything else. A partially downloaded model is never selectable.

**Integrity is checked, and failure is loud in the right place.** Verify size and hash against the source manifest; a corrupt or partial download is discarded rather than kept. Failures surface in the model list where the download was started (§14.3), never in the HUD — this is not a dictation failure.

**What this does not become:** no background re-download, no auto-update of models, no "recommended for you," no phoning the list home to see if it changed. The curated list ships in the binary and changes when the app does. A model the user has is a file the user has.

---

## 8. Settings

Two independent scopes, no overlap.

### 8.1 STT profiles

**All dictation settings live in profiles. STT models store nothing of their own.** Profiles exist because dictating an essay and dictating a prompt want different behavior. Example profiles: `Writing`, `Prompting`.

| Field | Notes |
|---|---|
| STT model | Parakeet / Whisper / audio-capable LLM (§2.2) |
| Cleanup enabled | Bool |
| Cleanup agent model | Which LLM performs cleanup |
| Cleanup generation params | Temperature, context — owned by the profile, not the model |
| Cleanup reasoning | On/off — **default open, see §12** |
| Cleanup instructions | Free text, appended to the cleanup system prompt |
| VAD pause threshold | ms, with the §4.3 calibration suggestion shown alongside |
| `chunkFloor` | s, must stay under 15 (§4.2) |
| Custom vocabulary | Term list |
| Show mic in compose bar | Off by default (§5.8) |

Switching profiles switches all of it at once. The menu bar exposes the switcher as a single control (§10.1).

Gone from this table since v0.16: insert mode (live-stream deleted, §4.4), live transcript in HUD (deleted, §4.5), HUD waveform on/off (the waveform is mandatory).

### 8.2 Chat model settings — per model

Applies to chat models, not the cleanup agent.

```
effective = overrides[model_id] ?? defaults
```

**"Save to all models"** writes to `defaults` and clears that key from every entry in `overrides`. Each row shows an inherited/overridden indicator. Switching away from a model and back preserves its overrides.

### 8.3 Settings access

`Cmd+,`. Not `Cmd+.` — that is the historical macOS cancel binding, and registering it globally would break cancel everywhere else.

### 8.4 Updates

One row, in General.

| Setting | Default | Notes |
|---|---|---|
| Check for updates automatically | **On**, weekly | Off disables the scheduled check entirely; **Check for Updates…** in the menu (§10.1) still works |

This is the only setting in the app that governs a network connection. MCP toggles are not here — they live in the MCP list (§6), because enabling a server is enabling a capability, not changing a preference.

### 8.5 Appearance — none

**No mode picker, no theme picker, no tint toggle, no glass-opacity slider.** All delegated to System Settings › Appearance (§14.2), which already exposes every control Sotto would have duplicated. Principle 5: the system's answer is the only answer.

Cost: users who want Sotto to look different from the rest of their system cannot. Accepted. Benefit: the entire theme layer disappears.

---

## 9. Storage

### 9.1 Chats

One folder per chat. Pure `.md` loses images, tool calls, and per-turn metadata.

```
chats/2026-08-09-selection-question/
  chat.md          # YAML frontmatter + turns
  attachments/     # pasted images, screenshots
```

- Frontmatter: created/updated timestamps, context size, participating models
- **Per-turn model attribution** — required because §5.3 allows switching models mid-chat
- Highlighted blocks stored as fenced `selection` blocks (§5.2); tool calls as fenced `tool` blocks
- Drops directly into Obsidian

**Retention:** unlimited by default; optional count cap. A **pin** flag prevents eviction when capped.

### 9.2 Audio and transcripts

Stored by default; toggleable off.

**Format: Opus @ 24 kbps** (~0.18 MB/min), not WAV (~1.9 MB/min at 16 kHz mono). With "never delete" that is 1 GB vs 11 GB per 100 hours. Decode on demand.

Each entry stores Opus audio, raw transcript (with pause markers, §4.6), cleaned transcript, **word-level timestamps** (required for §9.3), detected languages, and the profile used.

**Retention:** last 8 by default; configurable count; "never delete". Pin flag as above. §4.3's calibration job reads these; retention set to a very low count weakens it.

### 9.3 Playback and click-to-seek

Main window plays stored audio with **click-to-seek**: clicking a word in the transcript jumps playback to that moment.

Sentence-following highlight was **cut**. Seeking is navigation; a following highlight is decoration. The real uses — spot-checking a suspicious transcript, finding the one thing someone said in an hour-long import — are both "take me to that moment."

FluidAudio ships `buildWordTimings(from:)`, which groups SentencePiece subwords on the `▁` marker into `WordTiming { word, startTime, endTime }`; the CLI emits these via `--output-json --word-timestamps`. Parse-and-store, not build-an-aligner. Only `startTime` is load-bearing, which also sidesteps the `endTime` bug class in FluidAudio #381.

#### Verification — done. Verdict: use Parakeet timestamps, no correction.

| | short (52 s) | medium (223 s) | medium_wide (0.3–3.0 s pauses) |
|---|---|---|---|
| Word-start MAE | 313.8 ms | 288.3 ms | 293.8 ms |
| Max absolute error | 404.8 ms | 472.4 ms | 399.1 ms |
| Within ±500 ms | 100 % | 100 % | 100 % |
| Scatter (debiased MAE) | — | 54.3 ms | 43.7 ms |
| Drift | +21 ms total | +7 ms total | negligible |

Recognition was exact (589/589 on medium), so no anchor was lost to misrecognition. RTFx 132–259.

Three findings, each of which removed a reason to build something:

1. **All error is early, and it saturates.** Errors are one-sided and bounded at about −320 ms; longer pauses made accuracy *better*, not worse, and scatter tightens as gaps grow. Meeting audio with multi-second pauses is the easy case.
2. **Early is pre-roll, not error.** Landing half a second before the clicked word gives a beat of lead-in — what audio editors add deliberately. Late is the direction that hurts. The meaningful tolerance is asymmetric, roughly −800 / +200 ms, and the worst measurement uses 59 % of the negative budget.
3. **Span dilation is asymmetric.** Starts hit a floor; sentence *ends* smear to +1075 ms at long pauses. Click-to-seek never reads `endTime`, so this never reaches the product — and it independently validates cutting the sentence highlight.

**Ships at zero offset**, with a config hook. `TDT_EMISSION_DELAY_FRAMES=0` would shift timestamps ~80 ms later for free but is deliberately unused — that knob corrects emission delay against CTC peaks, and repurposing it conflates two concerns that will diverge.

Fallback ladder, retained for reference and not needed: Parakeet word timestamps → Whisper segment timestamps → VAD chunk offsets, which are free and already known (§4.2).

---

## 10. Application shell

### 10.1 Menu bar

`NSApp.setActivationPolicy(.accessory)` at launch — menu bar only, no Dock icon. Left click opens a standard `NSMenu`: actions on top, switchable state in the middle via submenus, version and Quit at the bottom.

```
Toggle Recording
──────────────────────────────
History...
Settings...                            ⌘,
──────────────────────────────
Profile: Writing                        ▸   Writing / Prompting / …
Chat Model: Gemma 4 E4B         👁       ▸   installed models, vision badge
Microphone: MacBook Neo Mic             ▸   input devices
MCPs                                    ▸   per-server toggles
──────────────────────────────
Version 0.1.0
Check for Updates...
Quit                                   ⌘Q
```

- **Profile** carries STT model, cleanup model, cleanup on/off, and instructions together (§8.1).
- **Vision badge** shows capability at a glance — the one gate (§7.2).
- **Toggle Recording** is a redundant path to latched mode, kept as an accessibility route when a gesture fails.
- **Quit** doubles as the shutdown path (§10.5).
- **Check for Updates** is Sparkle, for a self-distributed open-source build. See §10.6.
- **Transcribe File** lives in the main window (§10.2) — a workspace action, not a quick switch.

### 10.2 Main window

Opens on demand: `setActivationPolicy(.regular)` → Dock icon appears; back to `.accessory` on close. The transition steals focus (usually desired), and **the overlay must never trigger the flip**.

Two top-level modes, switched by a segmented pill in the toolbar (the Claude Desktop Home/Code pattern), with a sidebar and detail pane below:

| Mode | Sidebar | Detail pane |
|---|---|---|
| **Chat** | Chat list, newest first, pinned on top | Conversation, rendered highlighted blocks, per-turn model attribution |
| **Audio** | Recording list | Playback with click-to-seek (§9.3), raw/cleaned transcript toggle, copy either, `Transcribe File…` |

Search is **scoped to the active mode** — a blended list would mix two result shapes for no benefit. Settings open separately via `Cmd+,`.

> `NSSegmentedControl` and SwiftUI's `.segmented` style both handle icon-plus-label poorly. Expect a custom control: two buttons in an `HStack` over a rounded container with a matched-geometry selection pill.

### 10.3 Transcribe File

Import an audio file and run it through the same pipeline.

```
Transcribe File… -> pick file -> pick profile + stitcher model -> transcode
                 -> chunk -> transcribe -> [cleanup] -> history entry
```

- **Transcoding:** AVFoundation to 16 kHz mono. Accepts m4a, mp3, wav, aac, and anything else AVFoundation reads.
- **Profile chosen at import**, not inherited from the menu bar — cleanup for a recorded meeting differs from cleanup for your own dictation.
- **Always chunked.** Imports exceed the 15 s whole-buffer ceiling (§4.2) immediately.

**Overlapping chunks and stitching.** Unlike cleanup (§4.6), import chunks **overlap by one to two sentences**. Long recordings are noisier and often multi-speaker, and a boundary sentence transcribes differently depending on what preceded it; overlap makes disagreement detectable. Chunks still stay under `maxChunk` so FluidAudio's internal chunker never engages.

Reconciliation is two-stage, cheapest first:

1. **Deterministic alignment** — longest-common-subsequence match across the overlap. Resolves the large majority at zero inference cost.
2. **LLM stitch, only on mismatch** — hand both variants plus context to a larger, slower model.

Running a big model over the entire transcript is not viable — an hour is ~9,000 words and a larger model cannot be co-resident at 8 GB. Escalating only on mismatch keeps the expensive path rare. The stitcher model is selected at import and may be swapped in (unload chat model → stitch → reload). **Stitching runs as a background job** with progress in the Audio pane.

Results are ordinary history entries, **auto-pinned** so a deliberately imported hour is not evicted by the default 8-recording ring (§9.2).

> Measured baseline: FluidAudio's own chunker dropped one word span in 589 (~0.17 %) at a seam — ~15 spans per hour. Surviving words keep correct timestamps, so it is a completeness problem, not a timing one. Confirming that overlap-and-reconcile recovers them is an implementation-time task, and shares a corpus with §4.2's chunker comparison.

### 10.4 Escape — priority stack

Exactly one action fires, resolved top-down:

1. Abort in-flight gesture (Right Cmd held, or awaiting second tap) → discard audio, insert nothing, **and disarm the gesture** (§4.1)
2. Cancel transcription in progress
3. Stop chat generation
4. Close overlay

The global monitor is installed **only while app UI is live**. Escape is never swallowed system-wide.

### 10.5 Shutdown

**Quitting is the panic switch.** No separate disarm state, no dedicated chord. Event taps are per-process and die with the process, including on crash or force-quit. §2.5 is what makes it reliable: the tap runs on its own thread, so a wedged callback cannot freeze the menu bar. Cmd+Opt+Esc and Activity Monitor remain backstops, and macOS independently disables timed-out taps via `kCGEventTapDisabledByTimeout`.

### 10.6 Updates

**Sotto updates itself, and that is the one connection it makes on its own.** Through v0.17 principle 1 claimed zero outbound connections with no MCPs enabled, which Sparkle contradicted the moment **Check for Updates…** appeared in the menu. The claim is what changed, not the updater: a self-distributed app outside the App Store either ships an updater or ships builds that go stale forever, and Sotto holds Accessibility and Input Monitoring, so a stale build is a worse outcome than a weekly request.

**Verdict: Sparkle stays, automatic checks default on, weekly, disableable in Settings (§8.4).**

| Property | Decision | Why |
|---|---|---|
| Schedule | Weekly, on by default | Off by default means never in practice, on a process that can read every keystroke |
| Payload out | App version only | See profiling, below |
| Payload in | The appcast, then the signed archive if the user accepts | |
| User control | Settings toggle, plus the menu item, which works either way | |
| Failure | Silent. A failed update check is not an error the user needs (§14.3) | It reports nothing about the work the user is doing |

**System profiling is off, explicitly.** `SUEnableSystemProfiling` stays `NO` and is written into `Info.plist` as a stated value rather than left to Sparkle's default. Enabled, it appends CPU type, core count, RAM, OS version, model identifier, and preferred language to the appcast URL as query parameters — a machine fingerprint attached to the only request Sotto sends. Leaving it at the default would be correct today and silently wrong if a future Sparkle changed the default.

**EdDSA signature verification is mandatory**, and the appcast is HTTPS-only. An updater that runs arbitrary downloaded code is a worse security hole than the one it patches.

**What this does not open the door to.** No telemetry, no crash reporting, no analytics, no remote config, and no checking whether the bundled model list has changed (§7.4). Each of those fails principle 1's consent test for the same reason: the user never asks for it, and never would.

---

## 11. Feature index (40)

**Dictation (13)** — 1. Hold Right Cmd push-to-talk · 2. Double-tap Right Cmd latched, single tap stops · 3. Local STT on ANE · 4. VAD chunking with `chunkFloor` and a 15 s ceiling · 5. Sub-15 s recordings transcribed whole · 6. Waveform HUD, always on, no transcript layer · 7. Batch insert only · 8. AX → clipboard-paste insertion · 9. No focused field → clipboard with HUD confirmation · 10. Cleanup at end with pause markers, raw retained · 11. Custom vocabulary · 12. Single-undo · 13. Escape aborts and disarms

**Overlay (12)** — 14. Double-tap Option · 15. Deferred-commit draft, target resolved at send · 16. Draft persists across close/reopen · 17. Selection attaches as a chip · 18. Per-chip dismiss · 19. Tagged `selection` blocks with fence escaping · 20. Attachments serialize before text · 21. Selection + Right Cmd → question flow · 22. Chat picker below the bar; draft retargets with everything · 23. Session continuity, configurable, resets on send · 24. Image via paste or drag-then-summon with a distinct drop affordance · 25. Click-through → screenshot mode, glow excluded from capture

**Chat (5)** — 26. Embedded MLX + OpenAI-compat adapters · 27. MCP client on the 2026-07-28 revision · 28. Markdown-folder storage · 29. Vision-only capability gating · 40. In-app model download from a curated list or a pasted `repo_id`, with the memory estimate shown first

**App (10)** — 30. One bundled search MCP, off by default · 31. Menu bar `NSMenu` with profile/model/device/MCP submenus · 32. Main window with Chat/Audio switcher, sidebar, scoped search · 33. Transcribe File import with overlap stitching · 34. Playback with click-to-seek · 35. `Cmd+,` · 36. Per-profile STT + per-model chat settings with live memory estimates · 37. Retention and pinning, auto-pin on import · 38. Idle pause-length calibration · 39. Appearance inherited wholesale from System Settings; layered app icon

---

## 12. Open issues

| # | Issue | Why it is open |
|---|---|---|
| 1 | **MCP Swift SDK lags the protocol** | `modelcontextprotocol/swift-sdk` 0.12.1 (May 2026) implements 2025-11-25. The 2026-07-28 revision removes the handshake and sessions and adds MRTR — none of it is in the SDK, and Swift is not a Tier 1 SDK, so the update is not on a published schedule. Three options: wait, fork, or write the client directly against the spec. The stateless design makes the third cheaper than it would have been a year ago |
| 2 | **SwiftUI / AppKit split** | Liquid Glass is SwiftUI-first (`glassEffect`); AppKit's `NSGlassEffectView` is thinner. §10.2 already assumes a hand-built segmented pill, a SwiftUI idiom. If floating surfaces go SwiftUI inside `NSPanel`s while the main window stays AppKit, every §14.2 role needs both a `Color` and an `NSColor` form |
| 3 | **Focus changes mid-transcription** | The user starts dictating into a text field, then clicks elsewhere before transcription finishes. Does the text go to the field that was focused at gesture start, or to the clipboard? Routing to the original target risks writing into a window the user has left; falling back to the clipboard is safe but surprising when the field is still right there |
| 4 | **Cleanup reasoning: toggle, and default** | Should the cleanup model's reasoning be switchable in settings, and is it on or off by default? Reasoning may help punctuation on ambiguous prosody; it also multiplies latency on a step that sits between speaking and seeing text |
| 5 | **Bare compose bar growth** | The full panel grows then caps and scrolls (§5.8). Whether a standalone bar with no conversation above it should behave the same, or cap sooner, is undecided — a bar that grows to 180 pt with nothing above it may read as broken rather than accommodating |

### Deferred — decided in principle, not built

These are not open questions. They are settled as *allowed* and settled as *not now*, recorded so a later version does not have to re-argue whether they belong.

| Item | Standing |
|---|---|
| **Optional cloud model fallback** | Permitted by principle 1, because it cannot happen without the user pasting a key — an act at least as explicit as enabling an MCP. Not in v1. When it is built it inherits the same rule: the user provides the credential, the user can see when a turn went to it, and there is no silent failover from a local model that is merely slow. Nothing in the harness (§7.1) should assume the model is local, which is already true per principle 6 |

### Resolved

| Issue | Resolution |
|---|---|
| Live-streaming insertion × cleanup | Streaming cut from v1; the interaction no longer exists |
| Live transcript in the HUD | Cut. The HUD is the waveform and two completion messages |
| Whole-buffer re-transcription threshold | 15 s, bounded by FluidAudio's internal chunker rather than chosen |
| Chunking below the floor | Not done at all — whole-file pass |
| Cleanup context pressure on dictation | Not a problem: ~700 words ≈ ~1,000 tokens. Chunked cleanup is for imports |
| Punctuation quality | Cleanup owns it, fed by VAD pause markers |
| Number of bundled MCP servers | One, web search, Tavily |
| Which insertion strategies survive | AX, then clipboard paste; clipboard-only when no field is focused |
| Human typing | Separate project, unrelated, connects as a third-party MCP |
| AI text detection | Deleted from the document |
| Permission count | Three at first run; Screen Recording on first screenshot |
| Hardware-based feature gating | None. Estimates and amber warnings only |
| Send button in the compose bar | Present — the bar reads as unfinished without it |
| Image drop onto the overlay | Not possible directly; paste, or drag-then-summon with a distinct affordance |
| Highlighted block provenance | Fenced `selection` block; CommonMark's longer-fence rule is the escape |
| Attachment vs text order | Attachments first |
| Escape during push-to-talk | Aborts and disarms; releasing Cmd afterwards does nothing |
| Selection + Right Cmd in latched vs hold | Both route to chat |
| "Select text, dictate a replacement" | Not a feature; delete then dictate |
| Cleanup agent settings scope | Fully owned by the profile |
| Screenshot mode vs continuity timer | Timer resets on send only |
| Timestamp fidelity | Parakeet timestamps, zero correction (§9.3) |
| Long-import coherence | Overlapping chunks, LCS alignment, LLM escalation on mismatch |
| Uncommitted draft on overlay close | Persists; restored on next open |
| Transcribe File placement | Main window's Audio mode |
| Deployment target vs Liquid Glass | macOS 26 floor |
| Theming | Cut. Appearance inherited from System Settings (§14.2) |
| Reserved states vs a user-chosen accent | Moot — reserved states deleted (§14.3) |
| Where errors surface | Per-surface, routed by which pipeline failed. No global error token (§14.3) |
| Marking network-touching features | Not marked. Opt-in and off-by-default carry principle 1 (§1) |
| Disabled treatment | System disabled state for controls, full-screen scrim for the screenshot gesture (§14.7) |
| Menu bar icon states | Idle / not idle. macOS's own mic indicator carries the recording tell (§14.8) |
| When the token sheet gets filled in | Per feature, on demand. Slice 0 ships the template only (§14) |
| Zero-outbound guarantee vs. the Sparkle updater | Guarantee replaced by a consent rule: every connection is user-initiated or user-enabled. Automatic checks on, weekly, disableable (§1, §10.6) |
| Whether Sotto downloads models | Yes. A user-started download is the clearest case the consent rule has (§7.4) |
| Optional cloud fallback | Allowed in principle, deferred out of v1. See §12's Deferred table |
| Overlay appearance in Light mode | Follows the system, as Spotlight does |
| Model selector in the compose bar | Not present; the menu bar owns model choice |

---

## 13. Suggested build order

1. **Skeleton** — menu bar app, activation policy switching, settings window, `Cmd+,`
2. **Event tap** — dedicated thread, Right Cmd state machine, Option double-tap, Escape disarm, synthetic-event filtering
3. **Dictation MVP** — Parakeet + Silero, whole-file transcription, AX → clipboard insertion
4. **Chunking** — `chunkFloor`, the 15 s ceiling, discard-and-retranscribe, then the accuracy comparison against FluidAudio's chunker
5. **History** — Opus storage, transcripts, timestamps, main window with Chat/Audio switcher, click-to-seek
6. **Chat** — MLX embedded, overlay, tagged selection blocks, markdown storage
7. **Profiles** — STT profile system, cleanup agent with pause markers, multilingual
8. **MCP client** — against the 2026-07-28 revision (§12 #1 decides how)
9. **Bundled search MCP**
10. **Vision gating, screenshot mode, image attachment**
11. **Transcribe File** — reuses the pipeline once profiles land
12. **Idle calibration job**

---

## 14. Design system

Slice 0 of `sotto-build-order.md`. The deliverable is `sotto-tokens.md`.

**Slice 0 delivers the template, not the values.** Through v0.17 this section required a filled-in token sheet before anything else was built. That is now reversed: slice 0 produces the structure, the resolution rules, and the provenance columns, and every token is authored the first time a feature actually needs it.

**Why.** A sheet written up front is a sheet written without a consumer. Every value in it would be a guess defended by nothing, and §14.2's tier 2 — the list that must stay short — is exactly where guesses accumulate. Filling the sheet lazily means each authored value arrives attached to the thing that demanded it and the reason no system color served. The rejected alternative is the conventional one: enumerate a full type ramp, spacing scale, and radius set in slice 0. It was cut because the majority of those values would be dead on arrival, and a dead token is indistinguishable from a live one six months later.

**What this costs, and the guard against it.** The risk is that the first real feature invents values under pressure and everything after it anchors to those. The guard is that the template carries the *rules* even where it carries no values — derive from `NSFont.preferredFont(forTextStyle:)`, use a published system metric where one exists, nest radii concentrically — so a token added in a hurry is still constrained. Every authored row records what demanded it and what system value was ruled out first.

**Verdict: the template is the slice-0 gate. The values are not.**

The target is Apple-native and self-effacing: squircles, Liquid Glass, minimal, generous blank space, uniform across every surface. Reference points are Spotlight and Control Center, not the AI-app category — Gemini's overlay and Claude's compose bar were both examined and rejected (§14.1, §5.8).

Per principle 5, **the system decides everything it already has an opinion about.** Sotto authors only what macOS leaves open. Every value Sotto owns can drift from the system over time, so the fewer the better.

### 14.1 Material and geometry

**Corners are continuous, never circular.** `.rect(cornerRadius:style:.continuous)`, `layer.cornerCurve = .continuous`, or `ConcentricRectangle` where a surface should match the display's own corner. A circular arc jumps from zero to maximum curvature at a point, and that seam is most of what makes a rounded rectangle read as Material Design rather than Apple.

**Nested corners are concentric.** A chip inside the compose bar takes the bar's radius minus the inset.

**Two system materials, deliberately different.** Both are real system materials, not configurations of one.

| Surface | Material | Reference | Why |
|---|---|---|---|
| Overlay | Floating-panel glass | Spotlight | Holds long text, so it takes the denser material |
| HUD | Control Center–style glass | Control Center | Transient and mostly waveform; letting the wallpaper through keeps it part of the desktop rather than an interruption |

**Both follow system light/dark.** An overlay that stayed dark would be the one Sotto surface visibly ignoring a system setting. Accepted cost: a long draft in light glass over a bright busy desktop. If that proves bad, the fix is the denser end of the light material, not a return to always-dark.

**The user's Clear/Tinted choice is inherited for free** — using the real material means the System Settings selection applies with no preference to read and no branch to write.

**What Liquid Glass provides, and therefore must not be hand-rolled:** adaptive tint sampled from content behind the surface, a specular highlight along the lit edge, and refraction at the rim. Blur plus a flat fill is not this material. This is the single reason the deployment target is macOS 26.

**Intrusiveness is a set of values, not a layout.** The drivers Sotto still controls: width relative to content, height and internal padding, presence and weight of a full-perimeter stroke, shadow lift, vertical position, and element density. Those are tokens (`overlay.width.ratio`, `overlay.stroke.opacity`), not implicit properties of a mockup.

### 14.2 Token architecture

**Tokens are semantic system colors behind named roles** — not a theme struct, not authored hexes. Roles are the only thing components read: `surface.*`, `text.*`, `border.*`, `accent.*`, `material.*`. Each resolves in strict order of preference:

| Tier | Resolves to | Example |
|---|---|---|
| **1. Inherited** | An AppKit/SwiftUI semantic color or material. Light/dark, accent, and high-contrast adaptation come free | `accent.primary` → `NSColor.controlAccentColor`; `text.secondary` → `.secondaryLabelColor`; `border.hairline` → `.separatorColor` |
| **2. Authored** | A value Sotto owns because no system color fits. Must still adapt to light/dark, unless it sits on a surface Sotto draws itself | The waveform's idle bar treatment; the §14.7 scrim |

**There is no third tier.** v0.17 had one — fixed, user-immutable reserved states — holding exactly two tokens, `state.error` and `state.network`. Both are deleted (§14.3), so the tier is empty and the `state.*` namespace goes with it. Two tiers is the whole architecture: the system decides, or Sotto writes it down and says why.

**Tier 2 is the one to police.** The failure mode is authoring a value `.tertiaryLabelColor` already handles, which then silently stops matching the system on the next macOS release. Tier 2 must be an explicit, short, enumerated list, and under the lazy rule above it starts empty.

Inherited concretely: appearance mode, Liquid Glass variant, accent color including wallpaper-derived "This Mac", text highlight, window-background wallpaper tint, sidebar icon size, and — via a layered app icon — Default/Dark/Clear/Tinted renderings.

Handoff rule: name the role (`surface.raised`), never the hex, and where the role is tier 1 name the system API in the same breath.

### 14.3 Color roles and error routing

**Color is the system accent on neutral system surfaces.** `NSColor.controlAccentColor` on the caret, waveform, focus rings, and attachment chips. Surfaces take no Sotto-specific tint.

**Sotto has no owned visual element in its chrome.** Inheriting the accent killed the caret-as-signature idea — the caret is accent-colored in every app, so it distinguishes nothing. Invisibility is the intent. Identity lives in the menu bar icon and the app icon, nowhere else.

Still rejected: a leading brand mark in the compose bar, and a saturated send button — the loudest thing in Gemini's bar and the first thing that makes it feel intrusive. §5.8 restores the button, not its volume.

**The waveform is the one element with no system precedent**, so it is the only place needing original visual design rather than a mapping — and because it uses the system accent, it must hold up in every accent the user can pick.

**Recording has no reserved color or token.** The waveform HUD is the transient dictation indicator; its presence means capture is live. There is no visual distinction between push-to-talk and latched. The menu bar icon is the persistent indicator, and it reports something broader than recording (§14.8).

#### Errors have no token

**There is no global error state.** `state.error` existed through v0.17 and is deleted. It listed its own scope as "Appears in: Anywhere," which is the tell — a token that appears anywhere describes nothing about where to look, and it collided with §4.5's deliberately closed HUD vocabulary. One treatment stretched across a failed AX write, a model that will not load, and a tool call that returned garbage would have to be generic enough to be useless at all three.

**Each error routes to the surface that owns the work that failed** — not to the surface the user happens to be looking at. The routing follows the pipeline, so it is decidable at the point the error is thrown rather than at display time:

| Failure | Surfaces in | Why |
|---|---|---|
| Transcription fails | HUD (§4.5) | The HUD is already on screen for the duration of every dictation |
| Audio or cleanup model fails to load | HUD | Same pipeline, same surface, whether or not the user is mid-dictation |
| Cleanup fails mid-pass | HUD | It is a dictation step; the raw transcript is what the user gets |
| AX write rejected | HUD | Already the surface for the clipboard-fallback message |
| Chat model fails to load | Chat (overlay or main window) | The chat is the only place a chat model matters |
| Generation fails, tool call fails | Chat | In the conversation, attached to the turn that failed |
| File transcription fails | Main window, Audio mode | Transcribe File is only reachable from the window, so the window exists by definition. The message waits there whether or not the window is frontmost |

**Nothing is a notification and nothing is modal.** Sotto has no Notifications permission (§2.4) and does not acquire one for this. An error that fires with no surface on screen is not a case that exists: every failure above belongs to a pipeline the user started from a surface, and that surface is where it waits.

**Wording is per-error and lives with the feature, not here.** A central error vocabulary is the same mistake as a central error token one layer up.

### 14.4 Type

SF Pro and SF Mono. Roles are named, not sized ad hoc: `title`, `body`, `caption`, `transcript`, `code`. `transcript` is the one role that is not UI chrome — long-form reading text in the audio workspace, tuned for that rather than inherited from `body`.

**Default to deriving from `NSFont.preferredFont(forTextStyle:)`**, which tracks accessibility text size at runtime. A fixed point size is allowed per role but needs a stated reason; the burden of proof sits with fixing.

### 14.5 Spacing and radii

One spacing scale, one small radius set, no deviation. Radii for at least three tiers: control, card, floating surface. Floating surfaces take the larger radii macOS 26 chrome uses. Where macOS publishes or implies a standard metric, use it rather than picking a number.

### 14.6 Motion

Durations and easing are tokens. Consumers: HUD appear and fade, the waveform, the "Copied to clipboard" morph (§4.5), the "Attach image" affordance (§5.5), the segmented pill's selection transition (§10.2), the screenshot border glow (§5.6), the HUD's morph into an error message (§4.5), and the §14.7 scrim's appearance and dismissal. Match macOS's standard duration or curve for the equivalent transition rather than inventing one.

Per §14's lazy rule, none of these durations is authored until the feature consuming it is built. The list is the set of consumers to expect, not a set of tokens that already exist.

Every motion token needs a Reduce Motion fallback, and one is load-bearing rather than cosmetic: the HUD's fallback cannot be "no feedback," because the HUD appearing is what confirms the gesture registered.

### 14.7 Gated and disabled treatment

**Two patterns, split by whether there is a control to disable.** Unavailability has to be legible, and the shape of the answer depends entirely on whether the user is aiming at something visible.

**Controls take the system disabled state, with the reason in the tooltip.** A disabled `NSMenuItem` or `NSButton` already reads as disabled everywhere else on the machine; authoring a per-role disabled color would be a tier-2 value duplicating something AppKit does correctly. This covers image attachment in the `+` menu (§7.2) and every case like it.

**Gestures take a full-screen scrim.** Screenshot mode is entered by dragging on the overlay background (§5.6) — there is no control to gray out, so a disabled control communicates nothing and the gesture would simply die silently. Silent failure is worse than a loud message: the user repeats the gesture, concludes the app is broken, and never learns the cause. So the flow runs as far as it normally would and then stops:

```
drag on background, vision == false
  -> overlay hides, exactly as in §5.6
  -> full-screen scrim, message centered
  -> click or Escape -> scrim dismisses, overlay returns with the draft intact
```

Message form: **"Screenshot is disabled due to _<reason>_"**, naming the current model. Dismissal is click anywhere or Escape, which takes priority over §10.4's stack while the scrim is up.

**No Screen Recording permission is involved.** The scrim is a Sotto-drawn borderless window covering the display; nothing is captured, so §2.4's Screen Recording prompt does not fire. Prompting for a capture permission in order to refuse a capture feature would be the worst possible order of operations, and this avoids it by construction. The scrim window takes `sharingType = .none` for the same reason §5.6's glow does.

**The scrim is the one place Sotto authors a fixed color pair**, and it is a deliberate tier-2 entry: the fill is a dark translucent wash and the text is white on top of it. Because Sotto draws the wash itself, the text sits on a known dark background in both appearance modes — so this is one value, not a light/dark branch. It is the only full-bleed surface in the app and the only one that is not glass.

**Scope: this is the vision gate and nothing else.** Per principle 3 there is no other feature to gate. If a second gesture-triggered gate ever appears, it reuses this treatment; if a second *control* gate appears, it takes the system disabled state. No third pattern.

### 14.8 Menu bar icon and app icon

**Menu bar icon: two states, idle and not idle.** It reports that Sotto is awake, not that Sotto is recording. Not idle covers:

- recording, either gesture, including latched
- the overlay open
- the main window open
- a response generating
- a file transcription running
- cleanup running
- a model loading

**Why not idle/recording.** A recording-specific state would make the icon a microphone tell, and macOS 26 already provides one — the system shows its own indicator whenever any app holds the microphone, in the same menu bar, without Sotto's help. Duplicating it would be Sotto asserting something the system asserts better, which is principle 5 backwards. What the system does *not* report is whether Sotto is doing anything at all, so that is the state worth owning.

**The cost, accepted:** a filled icon no longer means "you are still latched." Latched mode is the one state a user can forget they are in, and through v0.17 the icon was its persistent tell. It now shares the filled state with an open chat window. This is acceptable because the mic indicator macOS draws is the tell that actually matters — forgetting you are latched is a privacy concern before it is a usability one, and the system covers the privacy half unconditionally.

Both states are template images, so menu bar tint adaptation is automatic and the icon inherits Reduce Transparency and high-contrast handling for free. The idle-to-not-idle difference is stroke-to-fill on a single capsule, which survives at 18 pt where a two-capsule mark does not.

**App icon: layered, so the system renders it.** A layered icon (Icon Composer) gets Default, Dark, Clear, and Tinted for free. This constrains the design: it must survive being stripped of color and read as a silhouette. Decide the layer breakdown in slice 0.

### 14.9 What a design tool cannot show

Claude Design and any HTML mock output the same approximation: circular corners, blur instead of refraction, no adaptive tint, no specular edge, no system semantic colors. **Judge proportion there** — width, height, radius magnitude, spacing, element order, how much air the placeholder gets. **Do not judge material or exact color there.** Corner style, glass type, and every tier-1 role travel to Claude Code as named APIs and will look better in Swift than in any mockup.
