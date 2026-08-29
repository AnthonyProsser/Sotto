# How to work a slice, and the four things that cross them

**Open this when starting a slice, or when the work lands in more than one.** `CLAUDE.md` §0.1 routes you here.

---

## 1. The build order is the operational plan

**`docs/sotto-build-order.md` is the plan.** Sixteen slices, 0 through 15. It **supersedes spec §13**, which is a twelve-line sketch kept for orientation; where they disagree, the build order wins, and it carries the mapping at the end.

Each slice names its spec sections in a **Spec:** line. **Read those sections before writing code for that slice** — the build order states what to build, the spec states why, and the why is what tells you which shortcuts are fatal.

Ordering rule throughout: nothing depends on something built later, and every slice ends at a state that can actually be used. Four slices have no design surface at all — **2, 4, 5, and 7** — and go straight to code.

**Working rhythm:** design the slice in Claude Design, screenshot it, hand it over, build it in Swift, use it, move on. When designs arrive, expect them to be wrong about material in four specific ways — corners render as circular arcs, blur is not refraction, there is no adaptive tint, there is no specular edge. **Judge proportion from a mockup; judge material only in Swift (§14.9).**

**The Done-when line is the ceiling as well as the criterion.** When you can do what it describes and you have watched yourself do it, the slice is finished (`CLAUDE.md` §0.6). Items the build order gives to a later slice are not yours, and an ambiguity the Done-when line does not touch is not yours to settle — leave the seam where a cross-slice thread in §3 says to leave one, and nothing more.

**A slice marked "Design: heavy" that reaches a build session with its design pass still open is a routing problem, not a licence to run the pass.** Build the core behaviour on the smallest reasonable local choices (`CLAUDE.md` §0.7), and list the material unresolved ones at the top of your reply, one line each, for Anthony to rule on. **Do not spend the session researching every visible number** — a build session that becomes a design session costs an hour and still produces choices he has to review.

---

## 2. Slice 1 — Shell

Builds: `.accessory` at launch, the §10.1 `NSMenu` with stubbed submenus, the settings window on `Cmd+,`, the activation-policy flip **with the overlay guard**, both menu bar icon states, the idle/not-idle observable, and the token layer as a thin mapping — **no theme struct**, but the indirection must exist so the inherited-vs-authored boundary stays auditable in one file.

---

## 3. The five threads that cross slices

Five things are built in pieces and go wrong if each slice treats them as local.

**The idle / not-idle signal (§14.8).** Defined in **slice 1**; fed by slices **3, 7, 9, 10, 11, 14**. Not idle covers: recording (either gesture, including latched), overlay open, main window open, a response generating, a file transcription running, cleanup running, a model loading. Define it once as a single observable with a documented contributor list, or seven later slices each quietly add a second source of truth. The icon reports that Sotto is **awake**, not that Sotto is recording — macOS 26 already draws its own mic indicator in the same menu bar, and duplicating it would be Sotto asserting something the system asserts better.

**The Escape priority stack (§10.4).** Exactly one action fires: abort in-flight gesture (slice **2**) → cancel transcription (slice **3**) → stop chat generation (slice **9**) → close overlay (slice **9**). Slice **13**'s scrim preempts all four. Full rule in `.claude/rules/input-and-insertion.md` §3.

**Error routing (§14.3).** No central error type, no central vocabulary. Each failure names its own surface at the point it is thrown. Surfaces are designed in the slice that owns them — slice **6** designs the file-transcription failure slot even though nothing produces one until slice **14**. Full table in `.claude/rules/design.md` §10.

**The cleanup model's warm-up.** The hook is set in **slice 3**, fired **at launch** from `Dictation.prepare()` (2026-08-23; it fired from the gesture until then), and consumed by **slice 11**. Apple's on-device model costs ~3.5 s on the first request after launch and ~850 ms after that (measured 2026-08-19), so an un-prewarmed cleanup puts 3.5 s into the gap between speaking and seeing text on the first dictation of every session. **Slice 3 leaves the seam even though nothing fills it yet** — otherwise slice 11 reaches back into gesture handling to add one. Prewarming is never an `Activity` contributor; full rule in `.claude/rules/audio-and-transcription.md` §3.1.

**The token sheet's growth (§14.2).** One row at a time, each a four-part claim. Starts empty in slice **1** with whatever the menu and settings window actually consume. Three tier-2 entries are pre-approved — waveform idle bar (slice **3**), the scrim pair (slice **13**), overlay intrusiveness (slice **9**). Full rule in `.claude/rules/design.md` §9.

---

## 4. Which slice hits which open question

Do not build past one of these without asking — `.claude/rules/open-questions.md`.

| Slice | Question |
|---|---|
| **9** | ~~Send button volume (gap 3); bare compose bar growth (issue 5); the chat's shape (gap 1)~~ — **all three closed 2026-08-27**, see `DECISIONS.md` |
| **3** | The **HUD's** anchor — the 8 % top offset, value or rule (gap 2). Slice 3 builds the HUD panel, so it has to be positioned here |
| **9** | The **overlay's** anchor — the 118 pt bottom offset, value or rule (gap 2) |
| **10** | ~~Decision 04's shape, three-way (gap 1)~~ — **closed 2026-08-27**: Frame 2's right-docked 560 pt column |
| **11** | Cleanup reasoning toggle and default (issue 4) |
| **12** | MCP Swift SDK vs. protocol version (issue 1) — **decide before the first line** |
| Any | ~~Focus change mid-transcription (issue 3)~~ — **closed 2026-08-27: the clipboard**, `rules/input-and-insertion.md` §6. Issue 2 closed — all SwiftUI |

---

## 5. Build-order amendments not yet folded back

**`docs/sotto-build-order.md` is read-only (`CLAUDE.md` §0), so amendments live here until Anthony folds them in.** §0.1 sends future sessions to the build order first, and it does not yet know about any of these.

**One line each: what changed, and where the reasoning is.** A reader needs to know the build order is wrong on that point and where to read why — `DECISIONS.md` owns the argument, and restating it in both files is how two documents start disagreeing. Only an amendment with no `DECISIONS.md` row carries its own reason here. **When an entry has been folded back, delete it.**

### Slice 3 — Dictation core

- **Design item 5, the error morph:** design it with **no model-unavailable string**. A cleanup model that is not available routes to Settings → Dictation, not to the HUD. See `rules/design.md` §10.
- **Build list, one addition:** leave the **prewarm seam** for the cleanup model — **fired at launch from `Dictation.prepare()`** (2026-08-23; it fired from the gesture until then), filled in slice 11. §3's fifth cross-slice thread.
- **The microphone opens on the Right Cmd key-down, not at the 250 ms threshold** (`DECISIONS.md`, 2026-08-24). `Dictation.arm()` starts capture and pre-renders the HUD at zero alpha; every way the press can fail to become a dictation routes to the **existing** `abort()`. Do not write a second discard path, and do not touch the transcriber on key-down.

### Slice 4 — Transcription pipeline

- **Apple Speech is the only backend.** No Parakeet, FluidAudio, Silero, or Whisper, and **no backend-selection seam built on spec** — a second engine stays possible in a later version behind §2.2's interface, but v1 does not carry scaffolding for one. `rules/audio-and-transcription.md` §1.0.
- **STT and the LLM share the ANE**, so the slice may not assume they are on different blocks. Mic-rate capture may overlap Foundation Models freely; that is measured, not assumed.
- **The audio chunker is skipped.** Pause collection (`SpeechDetector`) and keeping the PCM moved to slice 5. Do not resurrect `chunkFloor` / `maxChunk` / discard-and-retranscribe.

### Slice 5 — History storage

- **Obsidian is not a feature** (`DECISIONS.md`, 2026-08-19). The chat writer is `chat.md` + `attachments/` because that is the data, not because of a vault. No sample vault, no Obsidian check. The writer ships with no caller; slice 9 is the first real chat.
- **Audio entries are a folder with `audio.caf` (Opus @ 24 kbps) and pretty-printed `entry.json`.** Inspectable in any text reader. Ring of 8, pin, "never delete" at limit 0.
- **`cleaned`, `profile`, and `languages` are empty slots.** Do not invent values. Slice 11 fills them — see the Slice 11 amendment below.

### Slice 6 — Audio workspace

- **The sidebar context menu gains `Delete…` behind a confirmation, and `Reveal in Finder`** — `DECISIONS.md` 2026-08-20.
- **The transport is a waveform of the whole recording, not a scrubber; click or drag anywhere seeks** — `DECISIONS.md` 2026-08-20.
- **Raw is the default transcript side and clicking a word seeks only there; `Cleaned` stays visible and disabled until slice 11** — `DECISIONS.md` 2026-08-20.
- **Pause markers come off for display** via `AudioHistory.unmark` and stay in `entry.raw` on disk — `DECISIONS.md` 2026-08-20.
- **The search field is applied to the sidebar column, not inside a mode's list** — `DECISIONS.md` 2026-08-20.
- **`Transcribe File…` is a disabled stub with a tooltip.** Slice 14 fills it; the button exists here so the empty state has somewhere to point. No `DECISIONS.md` row.
- **`Recording.duration` is read from the CAF header, not stored.** Slice 5's `AudioEntry` schema is unchanged — a fourth slot would have to be backfilled into every existing entry to be trustworthy. No `DECISIONS.md` row.
- **The sidebar column width is unset, so `NavigationSplitView` collapses it to ~140 pt and truncates row titles to about three words.** There is no system constant. Under `CLAUDE.md` §0.7 and `rules/design.md` §1 this is a local constant, not a tier-2 token: the next session working that pane picks a width, writes it in the view, and says so in one line. **The earlier instruction to put it to Anthony is withdrawn** — it was escalated under the rules as they stood before 2026-08-21.

### Slice 9 — Overlay and chat · Slice 14 — File transcription

- **Import transcription is serialised around active chat generation.** At 60× realtime an import costs cleanup **+76 %** latency and loses **24 %** of its own throughput. Slice 14 waits on a generating response rather than competing with it; slice 9 owns the signal it waits on. Neither applies to microphone dictation, which overlaps freely.
- **Cleanup and chat each own a `LanguageModelSession`.** Sharing one throws `concurrentRequests` deterministically, and concurrency buys no throughput — the model serialises. `rules/models-and-network.md` §1.1.

### Slice 11 — Profiles, cleanup, and calibration

- **Cleanup defaults to Apple's on-device model**, with `Guardrails.permissiveContentTransformations`. Still per-profile.
- **Fix the self-correction instruction.** Measured: the model preserves "no wait, actually" instead of resolving to what the speaker settled on, which is what §4.6 asks for.
- **Fill the prewarm seam** slice 3 left; never set `Activity.Contributor.cleanup` for a prewarm.
- **Fill the three empty slots on `AudioEntry`.** Slice 5 writes `cleaned`, `profile`, and `languages` as `nil` / `[]` so the on-disk shape does not change later. Cleanup writes `cleaned`. The active profile's name writes `profile`. Detected languages write `languages` — Apple Speech does not emit Whisper-style language tokens, so decide the source here rather than assuming one. The sidecar is `Sotto/History/AudioHistory.swift`.

Full reasoning for all of these is in `rules/audio-and-transcription.md` §3.1 and `rules/models-and-network.md` §1.1.
