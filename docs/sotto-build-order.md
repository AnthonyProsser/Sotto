# Sotto — Build Order

Companion to `sotto-spec.md` **v0.18** and `sotto-tokens.md`. Sequenced for a design-first, one-feature-at-a-time workflow: design the slice in Claude Design, screenshot it, hand it to Claude Code, build it in Swift, use it, move on.

**This document supersedes §13.** Spec §13 is a twelve-line sketch kept for orientation; where the two disagree, this file wins. The mapping is at the end.

Every slice is marked with whether it has a design surface. **Four of the sixteen have none** — slices 2, 4, 5, and 7. Those go straight to Claude Code; spending a design cycle on a VAD chunker or a headless harness buys nothing.

Ordering rule throughout: nothing depends on something built later, and every slice ends at a state you can actually use.

---

## What changed from the v0.14 build order

The previous version of this file was written against spec v0.14 and is stale in ways that would produce wrong code, not just wrong emphasis. The material breaks:

| Was | Now | § |
|---|---|---|
| Slice 0 delivers a filled-in token sheet | Slice 0 delivers a **template**; values are authored the first time a feature needs one | §14 |
| Three reserved states, tier 3 | **Deleted.** `state.*` namespace is gone; two tiers only | §14.2, §14.3 |
| One global error treatment | **Errors route to the surface that owns the work.** No central token, no central vocabulary | §14.3 |
| Insertion is AX → CGEvent Unicode → clipboard | **Two strategies**, AX → clipboard paste. Unicode deleted with the human-typing MCP | §3 |
| Two-tier reconciliation, 30 s whole-buffer re-pass | **15 s ceiling**, `chunkFloor` at 8 s, discard-and-retranscribe under 15 s | §4.2 |
| HUD has an off-by-default live transcript layer | **No live transcript.** Waveform, two completion messages, and the error morph | §4.5 |
| Menu bar icon is idle / recording | **Idle / not idle.** macOS's own mic indicator carries the recording tell | §14.8 |
| Three bundled search MCPs | **One. Tavily.** | §6.2 |
| Sotto never downloads models | **Sotto downloads models** — curated list plus pasted `repo_id`, estimate shown first | §7.4 |
| Zero outbound connections | **Consent rule**, not a count. Sparkle ships, weekly, default on | §1, §10.6 |
| Permissions asked in a first-run wall | **Just-in-time.** Three at first run, Screen Recording at first screenshot | §2.4 |
| No send button in the compose bar | **Send button present**, and it must not be the loudest thing there | §5.8 |

Structural changes to the sequence itself:

- **Dictation splits into two slices.** Core (whole-buffer) then chunking. §4.2 grew a floor, a ceiling, a discard rule, and a measurement task; it is no longer a paragraph inside another slice. The split is honest because §4.2 states outright that chunked results drive nothing visible — a recording under 15 s is transcribed whole either way, so slice 3 is a correct subset rather than a stub.
- **Model acquisition becomes its own slice.** §7.4 is new in v0.18 and is a real surface: curated list, paste field, size and memory estimate before the download, background jobs, resume, integrity check. It cannot live inside settings as a row.
- **Slice 0 is substantially done.** `sotto-tokens.md` exists as the template and `designs/Design.pdf` locked ten measurements. What remains is listed below and is small.

---

## Slice 0 — Design system template

**Design:** everything. Nothing gets built this slice.
**Status: substantially complete.** `sotto-tokens.md` is written; `designs/Design.pdf` holds the locked measurements.

Full specification is §14. Settled going in — do not spend design cycles re-deciding:

| Decision | Verdict |
|---|---|
| Deployment target | macOS 26. Real Liquid Glass, real continuous corners, real concentric radii |
| Corners | `.continuous` everywhere, never a circular arc |
| Overlay material | Floating-panel glass — Spotlight, not Control Center |
| HUD material | Control Center–style glass |
| Both materials follow system light/dark | Yes. An overlay that stayed dark would be the one surface visibly ignoring a system setting |
| Appearance source | System Settings, wholesale. No theme system, no Appearance tab |
| Color | System accent on neutral system surfaces |
| Reserved states | **Deleted.** No `state.recording`, `state.latched`, `state.error`, `state.network` |
| Error treatment | Per-surface, routed by which pipeline failed. No global token |
| Disabled treatment | Two patterns: system disabled state for controls, full-screen scrim for the screenshot gesture |
| Menu bar icon | Idle / not idle, single capsule, outline → fill |
| Brand identity in chrome | None. Identity is the menu bar icon and app icon only |
| Compose bar | Add-context `+`, message field, chat picker, send. No model selector, no mic by default |
| Overlay position | Bottom-anchored. HUD stays at the top; the two surfaces no longer share a region |

**The lazy rule is the whole point of this slice.** Through v0.17 slice 0 required a filled-in type ramp, spacing scale, and radius set before anything got built. That is reversed. A value authored before it has a consumer is a guess defended by nothing, and §14.2's tier 2 — the list that must stay short — is exactly where guesses accumulate. **The template is the gate. The values are not.**

Delivered:

- The two-tier resolution order and the four-part claim required to add a row (role name, first consumer, system value ruled out, slice).
- The three known future tier-2 entries — waveform idle bar, `scrim.fill`/`scrim.text`, overlay intrusiveness values — named so they are not a surprise and not a precedent for others.
- Named type roles with no sizes, named radius tiers with no values, the motion consumer list with no durations.
- §6 of the token sheet: ten measurements locked in Design.pdf, held out of §1–§5 so the sheet's emptiness stays honest.

Closed since this file was first written, by folding `designs/Design.pdf` (locked 2026-08-11) into `sotto-tokens.md` §6:

- **The waveform is fully specified** — 12 bars at 3.5 pt wide with 4.5 pt gaps, symmetric about the centre, `v^0.5` compression, peak 28 pt, resting 3.5–6.7 pt uneven and drifting and never looping, with an 8 Hz / 125 ms / six-height quantised Reduce Motion fallback. It had existed only as a subordinate clause in `claude-design-followup-2.md`.
- **The menu bar icon is one capsule, not two.** The app icon's two-capsule S is not shrunk down; outline-to-fill is a better story at 18 pt than a wordmark nobody can resolve.
- **The HUD's width behaviour is settled**, including the six measured locale widths. Same font, same 13 pt in every locale — the surface grows, the type does not shrink, and single line is an invariant.
- **A fourth decision surfaced that no one had recorded**: the in-app chat (§6.4 of the token sheet) — edge-anchored wash, no panel edge, no chat picker, glass composer only.

Still open in this slice:

- **The overlay anchor decomposes; the HUD anchor does not.** Design.pdf quotes 118 pt alongside an 84 pt Dock and a 34 pt clearance, each with its own ratio — 118 = 84 + 34 is the shape of an invariant, not a coincidence, so the token is probably "clears the Dock's current height by 34 pt." That still leaves a side-mounted Dock, where there is no bottom occlusion, and an auto-hidden one, where occlusion is zero until it is not. The HUD's 8 % came from an assumed 1512 × 982 screen with a 24 pt menu bar and has no equivalent decomposition; a notched menu bar is taller than 24 pt. Decide per anchor whether it converts to a fixed value or a rule, and record which.
- **Decision 04 has no home in the spec.** §5.8 describes a bounded floating panel; Design.pdf draws a full-height edge wash with no picker. They may be one surface in two states or two surfaces. **The reconciliation belongs in §5, not in the token sheet**, and slice 9 or 10 has to make it.
- **The send button's volume contradicts §14.3.** §14.3 rejects a saturated send button and §5.8 restores the button "not its volume," but both PDF decisions draw a filled 26 pt accent circle — the loudest element in either surface. Either the drawing is what §14.3 warned against or the objection was to size and position rather than fill. One of the two documents needs amending; do not settle it by treating the drawing as authoritative because it is more recent.
- **App icon layer breakdown.** Two capsules forming an S, lower occluding upper, locked as a mark. The Icon Composer layer split is undecided. It is an asset decision, not a token, and does not gate anything.

**Build:** nothing.

**Done when:** the token sheet is a structure you can paste into Claude Code once and reference forever. **A shorter sheet is a better sheet** — and note that §1 and §2 are still empty, which is the point: every value above lives in §6 precisely because no feature has consumed it yet.

**Watch out:** Claude Design outputs HTML, so it renders circular corners, blur instead of refraction, no adaptive tint, no specular edge, and no real system semantic colors. Judge proportion there — widths, heights, radius magnitude, spacing, element order. Do not judge material or exact color there (§14.9).

---

## Slice 1 — Shell

**Design:** minimal. The `NSMenu` in §10.1 is a system menu — you write the structure, macOS draws it. The settings window is a standard toolbar-tab window. Sketch the settings tab list and nothing else. The menu bar icon is already drawn and measured.

**Build:**

- `setActivationPolicy(.accessory)` at launch
- `NSMenu` with the §10.1 structure, submenus stubbed
- Settings window, `Cmd+,` — not `Cmd+.`, which is the historical macOS cancel binding and would break cancel everywhere else (§8.3)
- Activation policy flip on main window open/close (§10.2), with a placeholder main window. **The overlay must never trigger the flip** — build the guard now, before there is an overlay to forget it in
- Menu bar icon, both states: 18 × 18 pt template, single capsule 15.6 × 7.2 pt at r 3.6, idle at a 1.5 pt stroke (hard floor), not idle solid filled
- **The activity signal the icon reads.** §14.8's "not idle" covers recording, overlay open, main window open, a response generating, a file transcription running, cleanup running, and a model loading. That is a single app-wide flag that seven later slices each have to raise. Define it here as one observable with a documented list of contributors, or every slice from 3 onward quietly adds a second source of truth
- Slice 0's roles as a token layer (§14.2): a thin mapping, not a runtime system. **No theme struct** — v0.13 required one and v0.14 cut it. The indirection still has to exist: components read `surface.raised`, never `NSColor.controlBackgroundColor` directly, so the inherited-vs-authored boundary stays auditable in one file
- The token file starts **empty** and gains its first rows here — whatever the menu and settings window actually consume, and nothing else

**Done when:** it lives in your menu bar, opens an empty settings window, flips the Dock icon correctly, and quits cleanly. The icon goes solid when the settings window is open and hollow when it closes.

**Spec:** §10.1, §10.2, §8.3, §14.2, §14.8

---

## Slice 2 — Gestures

**Design:** none.

**Build:**

- `CGEventTap` on a **dedicated thread** (§2.5 — hard requirement, not an optimization). If a tap callback blocks the main thread the menu bar goes unresponsive, which breaks quit-as-panic (§10.5), which is the only reliable shutdown path
- Right Cmd state machine: capture begins on keydown and is classified retroactively, 250 ms hold timer, 300 ms second-tap window, chord abort
- Right Cmd is **never consumed** — Right-Cmd+C keeps copying
- Option double-tap
- **Escape disarms the gesture, not just the buffer** (§4.1). Releasing the key afterwards does nothing: no transcription, no insertion, no HUD. The user should never have to think about how to let go after cancelling
- Synthetic event tagging and filtering (§2.6) — `.privateState` source, `MAGIC` in `.eventSourceUserData`, posted to `.cgAnnotatedSessionEventTap` rather than the HID tap
- Re-arm on `kCGEventTapDisabledByTimeout`
- Event tap observes **modifier keycodes only** — 54/55, 58/61. No key content is read, buffered, or stored, and the code should make that obvious to a reader auditing it

**Done when:** the console logs `PUSH_TO_TALK` / `LATCHED` / `ABORT` correctly, Right-Cmd+C still copies, Escape mid-hold leaves the release inert, and the menu bar stays responsive when you deliberately wedge a callback.

This is the slice most likely to need timing tuning by feel. Budget for changing 250/300 after you live with it.

**Spec:** §2.4, §2.5, §2.6, §4.1

---

## Slice 3 — Dictation core

**Design:** the HUD. Geometry is already locked; the states are not.

Locked in Design.pdf: 36 pt fixed height, intrinsic width (string + 16 pt each side, floor 152 pt, cap 320 pt), **single line always**, top edge at 8 % of screen height — with the caveat above that the 8 % is not yet a rule.

Design each state as a separate labeled frame, side by side, composited over a screenshot of a real desktop at 2x. A floating HUD designed on a blank canvas will be the wrong size.

1. Appear — gesture registered, no audio yet
2. Waveform active, loud speech
3. Waveform active, **silence** — this is the one that matters. It is on screen every time you pause mid-sentence and must read as *listening*, not as frozen, crashed, or finished
4. "Copied to clipboard" morph
5. **Error morph** — new in v0.18. The HUD owns every audio-side failure (§14.3), holds, then fades
6. Fade out

**The HUD has no controls at all.** No stop button, no close, nothing clickable, no hover target, no chrome that reads as pressable. A latched session ends with the gesture or with Escape.

**There is no live transcript layer**, and it is not a toggle. It would have shown raw text that cleanup then rewrites, so what you read would not be what got inserted.

The HUD is **Control Center–style glass**, following system light/dark. Keep it visibly different from the overlay's floating-panel glass.

**Build:**

- `AVAudioEngine` capture, device selection, default to system default. A device change mid-session must not drop an in-flight recording — hold the old device until the gesture ends, then switch (§4.8)
- Silero VAD, 32 ms frames — running here even though chunking lands in slice 4, because §4.5's waveform and §4.6's pause markers both want it
- Parakeet via FluidAudio, **whole-buffer transcription only**. Every recording in this slice is treated the way §4.2 treats a sub-15 s one
- Insertion ladder: AX write to `AXValue`/`AXSelectedText`, then clipboard paste. **Two strategies, not three**
- **No focused field → clipboard and stop.** Do not paste into whatever is frontmost. The HUD morph is what makes this path safe (§3)
- Focus detection: focused app → focused element → `AXRole` is `AXTextField`/`AXTextArea`, or `AXValue` is settable
- Selection reading from the **focused element only** (§3), with synthetic Cmd+C fallback for Electron and browsers
- Selection routing (§4.9): if text is selected, dictation routes to chat — which does not exist yet, so this slice stubs it at "log and drop." Wire the branch now so slice 9 fills a hole rather than adding one
- HUD panel, waveform from RMS off the capture buffer — no ASR involvement
- Reduce Motion fallback for the waveform. **This one is load-bearing**: the fallback cannot be "no feedback," because the HUD appearing is what confirms the gesture registered
- Escape abort, single undo unit per insertion

**Done when:** you can dictate into TextEdit, Notes, and a browser field; dictating with no field focused puts it on the clipboard and says so; and a failure says so in the HUD rather than silently. **This is the first slice where Sotto is a usable product.**

**Spec:** §3, §4.1, §4.5, §4.7, §4.8, §4.9, §14.3

---

## Slice 4 — Chunking

**Design:** none. §4.2 states outright that chunked results drive nothing visible. Chunking is a latency and memory strategy, not a display strategy.

**Build:**

- `chunkFloor` — 8 s default, tunable, always < 15 s. Below it, no boundary search runs at all
- `maxChunk` — 240,000 samples ≈ 15 s at 16 kHz, which is FluidAudio's internal `ChunkProcessor` threshold. **Staying under it is the requirement**, because a whole-buffer pass over 30 s would hand the job to FluidAudio's chunker, which is precisely what this design refuses. All seam handling is Sotto's own
- Boundaries on VAD-confirmed silence only, 200 ms of trailing audio appended to each chunk
- **Discard-and-retranscribe:** a recording that ends before 15 s cancels the in-flight chunk, throws it away, and transcribes the whole buffer in one pass. The waste is deliberate — the alternative is waiting 15 s before starting any transcription on long dictation, which is the case that actually needs the head start
- Forced cut at the largest pause in the window if `maxChunk` arrives without a qualifying pause
- Store every pause and its duration. §4.3's calibration job and §4.6's cleanup both read them, and neither exists yet

**Done when:** a four-minute latched dictation produces the same text a whole-buffer pass would, with the first chunk transcribing while you are still talking, and a nine-second dictation shows no evidence chunking exists.

**Then measure.** §4.2 flags this explicitly: the design argument for Sotto's chunker over FluidAudio's is a hypothesis until there is a number. Run both over the same corpus and record WER, dropped spans, and time-to-first-token. The measured baseline to beat is ~0.17 % word-span loss at seams — one span in 589 words, ~15 spans per hour. This shares a corpus with slice 14's stitching validation, so build the harness to serve both.

**Spec:** §4.2

---

## Slice 5 — History storage

**Design:** none. Pure data layer.

**Build:**

- Opus @ 24 kbps encode — ~0.18 MB/min against WAV's ~1.9. With "never delete" that is 1 GB per 100 hours instead of 11. Decode on demand
- Entry schema: audio, raw transcript with pause markers, cleaned slot, word timings, detected languages, profile used
- `buildWordTimings(from:)` parse and store. **`startTime` only** — click-to-seek never reads `endTime`, which sidesteps the FluidAudio #381 bug class and is independently validated by §9.3's finding that sentence ends smear to +1075 ms while starts hit a floor
- Chat folder schema (§9.1) — one folder per chat, `chat.md` with YAML frontmatter plus `attachments/`. Written but not yet read by any UI. Highlighted blocks as fenced `selection` blocks, tool calls as fenced `tool` blocks, per-turn model attribution
- Retention: ring of 8 for audio, unlimited for chats, both configurable, pin flag on each

Do this before the main window so slice 6 has real data to render instead of fixtures.

**Done when:** every dictation writes a complete entry to disk that you can inspect by hand, and the chat folder drops into Obsidian and reads correctly.

**Spec:** §9.1, §9.2

---

## Slice 6 — Audio workspace

**Design:** heavy.

- The custom segmented pill (§10.2). `NSSegmentedControl` and SwiftUI's `.segmented` both handle icon-plus-label poorly — expect two buttons in an `HStack` over a rounded container with a matched-geometry selection pill. Design both segments now even though Chat is dead until slice 10
- Sidebar recording list: title, date, duration, language badge, pin state
- Detail pane: waveform or scrubber, play/pause, transcript body, raw/cleaned toggle, copy either
- **The clicked-word seek affordance** — hover and active states matter here, it is the whole interaction
- Scoped search field. Search is scoped to the active mode; a blended list mixes two result shapes for no benefit
- Empty state
- The surface where **file-transcription failures** wait (§14.3). Nothing produces one until slice 14, but the slot is a design decision, not a slice-14 afterthought

**Build:** window, switcher, list, playback with click-to-seek, **shipping at zero seek offset** per §9.3.

The offset question is closed and worth not reopening: word-start MAE is ~290–314 ms, all error is early and bounded at about −320 ms, and 100 % of measurements land within ±500 ms. Early is pre-roll, not error — landing half a second before the clicked word gives the beat of lead-in an audio editor would add deliberately. `TDT_EMISSION_DELAY_FRAMES=0` would shift timestamps ~80 ms later for free and is deliberately unused, because that knob corrects emission delay against CTC peaks and repurposing it conflates two concerns that will diverge.

**Done when:** you can find a dictation from yesterday and jump to the moment you said a specific word.

**Spec:** §10.2, §9.3

---

## Slice 7 — Chat engine

**Design:** none. Headless.

**Build:**

- `mlx-swift` embedded, model load/unload
- OpenAI-compatible adapter with Ollama `:11434`, `llama-server`, and LM Studio autodetect
- The ~400-line harness loop: messages → model → if tool calls, execute, append, repeat
- Capability registry: `model_id → { vision, tools, max_ctx }`. MLX detects the vision tower in `config.json`; Ollama's `/api/show` returns a capabilities array
- **The memory estimator** (§2.3) as a standalone function: `weights + KV + ~15 % overhead`, with the KV formula. Three later surfaces consume it — the context slider (§7.3), the model list (§7.4), and the download screen — so it belongs here, in the module with no UI
- Context sizing math, amber threshold at ~60 % of physical RAM. **Advisory, never a gate.** Per principle 3 the app predicts and displays; the user loads what they like
- Markdown-folder persistence wired to slice 5's schema, per-turn model attribution
- Prompt-and-parse JSON tool-call fallback for models with no native structured tool format

**Done when:** a unit test sends a message and gets a streamed reply, and a second test switches models mid-conversation and the transcript records both.

Keep this in a module with **no AppKit import**. It is the largest body of logic in the app and the only way Claude Code can iterate on it without you clicking through a UI every time.

**Spec:** §2.3, §7.1, §7.2, §7.3, §9.1

---

## Slice 8 — Model acquisition

**Design:** moderate. New surface, no precedent in the app.

- The curated list: model ID, size, quantization, vision flag, and the §2.3 memory estimate per row, amber past ~60 % of RAM
- The paste field for an arbitrary `repo_id`, sitting with the list rather than replacing it
- Download progress: in the surface that started it, cancellable, resumable
- The **already-on-disk** state, since hand-placed weights keep working and are still checked first
- Failure treatment in the model list (§14.3) — never in the HUD; this is not a dictation failure

**Build:**

- Source ladder in order: already on disk → Hugging Face `repo_id` resolution for MLX weights → `ollama pull`, delegated. Sotto does not re-implement Ollama; it is already a local process
- **The estimate is shown before the download, not after.** After the download it is 4 GB of regret. This is the one place the §2.3 number can change a decision
- Downloads are background jobs with the same shape as slice 14's stitcher: resumable across launches, blocking nothing. A partially downloaded model is never selectable
- Integrity: verify size and hash against the source manifest, discard a corrupt or partial download rather than keeping it

**What this must not become:** no background re-download, no model auto-update, no "recommended for you," no phoning the list home to see if it changed. The curated list ships in the binary and changes when the app does. A model the user has is a file the user has.

**Why it is a slice and not a settings row:** §7.4 is new in v0.18 and reverses a position principle 1 previously implied. The reversal is worth remembering — requiring the user to leave the app, find a repository, and place weights by hand made nothing more private, it made the app harder to start using. A user-initiated download is the clearest case the consent rule has.

**Done when:** a clean install with no models can reach a working chat without you opening a terminal.

**Spec:** §7.4, §2.3, §14.3

---

## Slice 9 — Overlay

**Design:** heaviest slice in the project. This is where a clickable Claude Design prototype beats static frames, because everything here is state transitions.

Locked in Design.pdf: 600 × 52 pt bar, radius 16, **bottom-anchored** with the bottom edge 118 pt above the screen bottom — subject to the Dock caveat in slice 0. Stroke ceiling ~1 pt at 15 % opacity, full perimeter; past that the bar reads as an app window rather than a system affordance.

Frames or prototype covering:

- Empty compose bar — leading add-context `+`, message field, chat picker, trailing send
- Compose bar with a selection chip attached, visibly pending
- Multiple chips, each with its dismiss control
- Chat picker below the bar, collapsed and expanded
- Retarget: same draft, different target, everything carried over
- Restored draft on reopen
- Send in flight, and stop-generation
- **Growth:** field at one line (44 pt) → six lines (180 pt) → internal scroll. Chips wrap above the field and count toward intrinsic height. The `+` stays vertically centered on the first text line
- **The cap:** panel maximum is the lesser of 720 pt and 70 % of usable display height. At the cap the conversation body is the sole scroll region; chips, composer, and picker stay pinned
- **The "Attach image" drop affordance** (§5.5) — must be visually distinct from "Copied to clipboard" in shape, position, and motion. These are the only two moments Sotto puts a transient message over the desktop, and confusing "I took your image" with "I put your words somewhere else" is the exact failure to design against

**The design question to actually answer:** can the user tell, at a glance, that nothing has been committed yet? The deferred-commit model in §5.2 is the least conventional idea in the spec and the one most likely to confuse.

**The second question:** does it feel like a burden when it appears over whatever you were already doing?

**Open issue #5 lives here.** The full panel grows then caps and scrolls. Whether a *bare* bar with no conversation above it should do the same or cap sooner is undecided — a bar that grows to 180 pt with nothing above it may read as broken rather than accommodating. Decide it in this slice's design pass, not in code.

The send button is present and **must not be the loudest thing in the bar**. §14.3 still rejects a saturated send button; v0.15 cut the button entirely and the design process reversed that on composition grounds, not prominence grounds.

**Build:**

- Option double-tap invocation, borderless `NSPanel` that **does not flip the activation policy**
- Draft model: text, attachments, target resolved at send time. Nothing is committed to a chat until send
- Draft persistence across close — text, attachments, or both, preserved exactly
- Per-chip dismiss. §4.9 makes accidental attachment easy, so this is a correctness requirement
- **Attachments serialize before the text**, whatever order the UI shows
- Fenced `selection` blocks with `app=` provenance. CommonMark's longer-fence rule is the escape — no user input can break out, and nothing new is invented
- Chat picker, continuity window (5 min default, adjustable, disableable), **timer resets on send, not on activity**
- Model switched since a chat's last message → continue in the same chat with the new model; storage records model per-turn
- Dictation into the overlay fills the bar with an **ordinary message** — not automatically about an attached block
- Cmd+V image paste. **No plain drag-and-drop**, because click-and-drag on the background already means screenshot mode and that gesture cannot mean two things
- Return sends, Shift-Return breaks, and Return stays the input method's during IME composition
- Escape priority stack (§10.4). Items 1 and 2 exist from slices 3–4; this slice adds 3 and 4 and is where the stack becomes a stack

**Spec:** §5.1–5.5, §5.7, §5.8, §10.4

---

## Slice 10 — Chat in the main window

**Design:** moderate.

- Conversation rendering: user turns, model turns, streaming
- Highlighted block styling. §5.2 says the model sees plain text inside a fence, so this is purely a rendering marker over an unambiguous parse — not a heuristic
- Per-turn model attribution, shown without clutter
- Chat list sidebar, pinning
- Chat-scoped search results
- **Chat and LLM failures surface here** (§14.3) — model load failure, generation failure, tool call failure, the last attached to the turn that failed. Not in the HUD, not as a notification, not modal

**Build:** wire slice 7's engine to the Chat segment stubbed in slice 6.

**Spec:** §10.2, §5.3, §14.3

---

## Slice 11 — Profiles, cleanup, and calibration

**Design:** moderate, all inside settings.

- Profile list with add/duplicate/delete
- Profile editor: the ten fields from §8.1
- Chat model settings with inherited/overridden indicators and "Save to all models" — which writes to `defaults` and clears that key from every entry in `overrides`
- Context slider with the live memory estimate from slice 7, amber past ~60 % RAM
- The mic-in-compose-bar toggle (§5.8), sitting with the other dictation settings
- The VAD pause slider **with §4.3's calibration suggestion shown alongside it**

**No Appearance tab.** v0.13 specified one — mode picker, theme picker, tinted-surfaces toggle, glass opacity slider — and v0.14 deleted all of it. Appearance is inherited from System Settings (§8.5, §14.2). Cost: users who want Sotto to look different from the rest of their system cannot. Accepted; the entire theme layer disappears in exchange.

**Build:**

- Profile system. **All dictation settings live in profiles; STT models store nothing of their own.** Switching profiles switches all of it at once
- Cleanup pass, running **after all chunks are transcribed**, never per-chunk. Optional, per-profile. Raw transcript always retained alongside the cleaned version
- **Pause markers are handed to the model** with their durations inline. This is the single highest-leverage input cleanup gets and it costs nothing to provide — §4.2 already measured every pause, and a 700 ms gap is the strongest available evidence for a comma or a period. Cleanup does punctuation as well as wording
- Chunked cleanup for imports only, disjoint and non-overlapping, split at `argmax(pause_duration)` inside a window of 60 % of context ± 20 %. Dictation does not need it: a 5-minute latched session is ~700 words ≈ ~1,000 tokens
- Multilingual tagging. **Language detection is not an extra LLM pass** — Whisper emits language tokens per segment natively and Parakeet can be probed. The LLM is invoked for language reasoning only when cleanup is already running, or when segments disagree, which is the actual code-switching signal
- **The idle calibration job** (§4.3): runs with no active dictation, no chat generation, on AC or above a battery floor. Re-runs VAD over stored recordings at a range of pause settings and reports which value best matches human-drawn boundaries. **Output is a suggestion in settings, never a silent change.** It is cheap because slice 5 already stores the audio and slice 4 already stores every pause

**Open issue #4 lands here:** whether cleanup reasoning is switchable and what it defaults to. Reasoning may help punctuation on ambiguous prosody; it also multiplies latency on the step sitting between speaking and seeing text. §8.1 currently defaults it open.

**Spec:** §8.1, §8.2, §8.5, §4.3, §4.6, §4.7, §14.2

---

## Slice 12 — MCP

**Design:** light.

- MCP settings pane: server list, per-server enable, config fields
- Tool call and tool result rendering in the chat body — fenced `tool` blocks, matching storage
- Menu bar MCP submenu

**No network badge anywhere.** v0.17 specified one and it was cut. Opt-in and off-by-default carry principle 1 on their own; a marker seen on every launch after a choice made once is decoration, and it competes for the same peripheral attention the HUD needs. Do not reintroduce it as a settings-pane flourish either.

**Build:**

- Client written against the **2026-07-28 revision**, which is a larger break than a version bump suggests: no sessions, no `initialize` handshake, protocol version and client info in `_meta` on every request, `server/discover`, Multi Round-Trip Requests replacing server-initiated requests, `resultType` required on every result, Roots/Sampling/Logging deprecated, no SSE resumability. Results from older servers that omit `resultType` are treated as `"complete"`
- **Decide open issue #1 before writing a line.** `modelcontextprotocol/swift-sdk` 0.12.1 (May 2026) implements 2025-11-25 and none of the above. Three options: wait, fork, or write the client directly against the spec. Statelessness makes the third far cheaper than it would have been a year ago, and §7.1 already says the harness is written against the revision rather than against an SDK
- stdio transport for third-party servers, in-process loopback for the bundled one
- **One bundled server: Tavily web search, disabled by default.** Three shipped in v0.16 — SearXNG, DuckDuckGo, bring-your-own-key — which was three surfaces for one capability, and the DuckDuckGo HTML scrape was the one that would break first. Exa was the closest call and loses on cost predictability at volume
- **Extracted page text, never snippets alone.** Small models hallucinate badly from snippets. This is a requirement on any provider and it is what eliminated Brave
- Provider choice behind **one config surface**, so swapping is a key change and not a code change

**Spec:** §6.1, §6.2, §6.3, §7.1

---

## Slice 13 — Vision gating, screenshot, images

**Design:** small but distinctive.

- The screen border glow. The only genuinely aesthetic surface in the app — worth a mood pass
- Region drag: cursor, dimming, selection rectangle, dimensions readout
- Image chips in the draft
- **The two disabled patterns**, which are the reason this slice has design work at all:
  - **Controls** take the system disabled state with the reason in the tooltip. This covers image attachment in the `+` menu. Authoring a per-role disabled color would be a tier-2 value duplicating something AppKit does correctly
  - **The screenshot gesture** takes a full-screen scrim. There is no control to gray out, so a disabled control communicates nothing and the gesture dies silently — the user repeats it, concludes the app is broken, and never learns why. The flow runs as far as it normally would and then stops: overlay hides exactly as in §5.6, scrim appears with the message centered, click or Escape dismisses and the overlay returns **with the draft intact**. Message form: "Screenshot is disabled due to *<reason>*", naming the current model
- The scrim is the app's **only full-bleed, non-glass surface** and the one place Sotto authors a fixed color pair. Because Sotto draws the wash itself, the text sits on a known dark background in both appearance modes — one value, not a light/dark branch

**Build:**

- Click-through to screenshot mode, `sharingType = .none` on the glow window so it is invisible to ScreenCaptureKit and `CGWindowList`; also pass it to `SCContentFilter(display:excludingWindows:)` if driving SCK directly
- **First entry into screenshot mode is what triggers the Screen Recording prompt** (§2.4). A user who never takes a screenshot is asked for three permissions, not four
- SCK region capture, drag-then-summon image attach, paste
- Capability gating on `vision == false`. **This is the only feature Sotto gates**, and it gates on the model rather than the machine — a text-only model cannot see an image, which is a fact rather than a policy. Features stay present in the UI; the user switches models
- Scrim window also takes `sharingType = .none`. **No Screen Recording permission is involved** — prompting for a capture permission in order to refuse a capture feature would be the worst possible order of operations, and the scrim avoids it by construction
- The scrim's dismissal takes priority over §10.4's stack while it is up

**Scope discipline:** this is the vision gate and nothing else. Per principle 3 there is no other feature to gate. A second gesture-triggered gate reuses this treatment; a second control gate takes the system disabled state. **No third pattern.**

**Spec:** §5.5, §5.6, §7.2, §14.7

---

## Slice 14 — Transcribe File

**Design:** light.

- Import sheet: file, profile, stitcher model
- Background job progress in the Audio pane
- Auto-pin indicator
- Failure state in the Audio pane — reachable only from the window, so the window exists by definition and the message waits there whether or not it is frontmost

**Build:**

- AVFoundation transcode to 16 kHz mono. Accepts m4a, mp3, wav, aac, and anything else AVFoundation reads
- **Profile chosen at import**, not inherited from the menu bar — cleanup for a recorded meeting differs from cleanup for your own dictation
- Always chunked; imports exceed the 15 s ceiling immediately. Chunks still stay under `maxChunk` so FluidAudio's internal chunker never engages
- **Overlapping chunks**, one to two sentences, unlike cleanup's disjoint split. Long recordings are noisier and often multi-speaker, and a boundary sentence transcribes differently depending on what preceded it — overlap makes disagreement detectable
- Two-stage reconciliation, cheapest first: LCS alignment across the overlap resolves the large majority at zero inference cost; **LLM stitch only on mismatch**, handing both variants plus context to a larger, slower model. Running a big model over the whole transcript is not viable — an hour is ~9,000 words and a larger model cannot be co-resident at 8 GB
- Stitcher model selected at import, swapped in and out: unload chat model → stitch → reload
- Stitching runs as a **background job** with progress in the Audio pane
- Results are ordinary history entries, **auto-pinned** so a deliberately imported hour is not evicted by the 8-recording ring

**Then measure**, on slice 4's harness and corpus: confirm overlap-and-reconcile actually recovers the ~15 spans per hour FluidAudio's chunker drops. Surviving words keep correct timestamps, so this is a completeness problem, not a timing one.

Last because it reuses every pipeline and adds none.

**Spec:** §10.3

---

## Slice 15 — Onboarding, updates, distribution

**Design:** moderate.

- Permission walkthrough as a **status list with a re-check button**, not a wall. §2.4 asks at first use of the feature that needs the permission; onboarding shows state and explains, it does not demand
- What each permission is for, in plain language. You are asking for Accessibility and Input Monitoring on an app that records audio, and principle 1 needs to be **visible** here, not just true
- Screen Recording appears in the list as **not yet requested**, with the reason, since it is only asked at the first screenshot

**Build:**

- Onboarding flow, first-run detection
- **Sparkle.** Automatic checks default **on**, weekly, disableable in Settings › General (§8.4). Off by default means never in practice, on a process that can read every keystroke. **Check for Updates…** in the menu works either way
- `SUEnableSystemProfiling` written into `Info.plist` as an explicit `NO`. Enabled, it appends CPU type, core count, RAM, OS version, model identifier, and preferred language to the appcast URL — a machine fingerprint on the only request Sotto sends. Leaving it at Sparkle's default would be correct today and silently wrong if a future Sparkle changed it
- **EdDSA verification mandatory, appcast HTTPS-only.** An updater that runs arbitrary downloaded code is a worse hole than the one it patches
- A failed update check is **silent**. It reports nothing about the work the user is doing (§14.3)
- Signing and notarization, layered app icon assembled in Icon Composer

Late because you will grant permissions manually in System Settings during development. But it cannot be cut — for an open-source release it is the first thing anyone sees, and the permission set is alarming without explanation.

**Spec:** §2.4, §8.4, §10.6, §1, §14.8

---

## Mapping to spec §13

§13 is a twelve-line sketch. This document is the operational version.

| §13 | Slices here |
|---|---|
| 1. Skeleton | 1 |
| 2. Event tap | 2 |
| 3. Dictation MVP | 3 |
| 4. Chunking | 4 |
| 5. History | 5, 6 |
| 6. Chat | 7, 9, 10 |
| 7. Profiles | 11 |
| 8. MCP client | 12 |
| 9. Bundled search MCP | 12 |
| 10. Vision, screenshot, images | 13 |
| 11. Transcribe File | 14 |
| 12. Idle calibration | 11 |
| — | 0 (design system), 8 (model acquisition), 15 (onboarding and distribution) |

Three slices have no §13 line: the design system, which §13 predates; model acquisition, which is new in v0.18; and onboarding, which §13 never covered.

---

## Threads that cross slices

Four things are built in pieces and will go wrong if each slice treats them as local.

**The idle / not-idle signal** (§14.8). Defined in slice 1, fed by slices 3, 7, 9, 10, 11, and 14. One observable with a documented contributor list, or seven sources of truth.

**The Escape priority stack** (§10.4). Item 1 arrives in slice 2, item 2 in slice 3, items 3 and 4 in slice 9, and slice 13's scrim preempts all four. Exactly one action fires, resolved top-down. The global monitor installs **only while app UI is live** — Escape is never swallowed system-wide.

**Error routing** (§14.3). There is no central error type and no central vocabulary. Each failure names its own surface at the point it is thrown: audio-side to the HUD, chat-side to the chat, file transcription to the main window, model download to the model list. Nothing is a notification and nothing is modal — Sotto has no Notifications permission and does not acquire one for this.

**The token sheet.** It grows one row at a time, and every row is a four-part claim: role name, first consumer, the system value that was ruled out, and why. **Tier 2 is the list to police** — authoring something `.tertiaryLabelColor` already handles will silently stop matching macOS on the next release. Three tier-2 entries are expected and pre-approved: the waveform's idle bar treatment (slice 3), the scrim pair (slice 13), and the overlay intrusiveness values (slice 9). A proposed tier-2 row that is not one of those three is a signal to look harder at tier 1.

---

## Handing designs to Claude Code

A screenshot alone loses the things Swift needs most.

**Send values, not just pixels.** Ask Claude Design to emit spacing, sizes, and colors as text alongside the visual. A frame that looks right tells Claude Code nothing about whether that gap is 12 or 16. Ask for every value twice — as points and as a ratio — so that if the absolute numbers are off, the ratios survive and you rescale instead of redoing the round.

**One frame per state, labeled, in one image.** Claude Code cannot infer a hover state or a transition from a single static frame. Six labeled states side by side in one screenshot works better than six separate uploads.

**Judge at actual size.** The menu bar icon round produced a real finding this way: an enlarged mark that reads as a logo can be an unresolvable knot of ink at 18 pt.

**Four things HTML always gets wrong**, so name them in every handoff rather than trying to fix them in the mock: corners render as circular arcs and must become `.continuous`; blur is not refraction; there is no adaptive tint sampling content behind; there is no specular edge. Judge proportion in the design tool, judge material only in Swift (§14.9).

**Name the role, not the value.** Say `surface.raised`, not `#2A2A2E`. Where the role is tier 1, name the system API in the same breath — `surface.raised` → `.controlBackgroundColor`. **Do this even when the row does not exist yet**: naming a role that has no value is how the lazy rule stays workable, because the token arrives attached to the feature that demanded it rather than being retrofitted.

**Don't design what macOS designs for you.** `NSMenu`, standard sheets, the file picker, alerts, the toolbar, and disabled controls. Every hour spent designing those produces something worse than the default.
