# Sotto — instructions for Claude Code

Menu-bar macOS app: system-wide dictation plus an overlay chat, both entirely on-device. Swift / AppKit, macOS 26 floor, Apple silicon only. Author: Anthony Prosser. Open source intent.

---

## 0. The read-only rule — read this before touching anything

**`/Users/anthonyprosser/Documents/Sotto` is the source of truth.** The spec, the build order, and the token sheet live there. What sits in `docs/` here is a **synced read-only copy**.

**Never edit anything under `docs/`.** Not to fix a typo. Not to record a decision. Not to tick a checkbox or mark a slice done. Not "while you're in there." There is no exception, because the value of the copy is that it is provably identical to the original — the moment it diverges, nobody can tell which file is real.

Decisions get made during build sessions. That is normal and expected; a spec that survives contact with Swift unchanged was not a spec, it was a wish. When one happens:

1. **Append it to `DECISIONS.md`** in this directory, using the template at the top of that file.
2. **Say so in your reply.** "This contradicts §4.2, I've logged it in DECISIONS.md" — out loud, in the message, not silently in a file the user may not open.
3. **Do not amend the spec copy**, and do not assume the decision has been recorded anywhere authoritative. `DECISIONS.md` is a queue, not a record.

Anthony folds `DECISIONS.md` entries back into the real spec in `Documents/Sotto`, then re-syncs `docs/`. Until he does, **the copies are out of date**, and you should say so whenever a decision from the current session contradicts them. A stale copy that everyone knows is stale is fine; a stale copy that reads as current is how a build goes wrong three slices later.

**Corollary, stated plainly: if `docs/sotto-spec.md` and something Anthony said in this session disagree, Anthony wins.** The spec is a snapshot of his reasoning, not an authority over it. **But he wins on the record, not by default** — §0.1 governs how you get there. Put the contradiction to him first, then follow what he said, then log it in `DECISIONS.md` so the snapshot catches up.

**The only files you write in this repo without asking:** Swift sources, project files, `DECISIONS.md`. Everything under `docs/` is read-only.

---

## 0.1 Before building a feature — read first, ask second, build third

**When Anthony names a feature to build, the first move is never code and never the build-order slice on its own. It is a search.**

**Find every mention before you start.** A feature is almost never described in one place, and the four documents each hold a different part of it:

| Where | What it holds |
|---|---|
| `docs/sotto-spec.md` | The behaviour and, more importantly, the reasoning — what was rejected and why |
| `docs/sotto-build-order.md` | Which slice owns it, what it depends on, and the **Done when** line that defines finished |
| `docs/sotto-tokens.md` | Any locked measurement, usually in §6 before its slice converts it to a row |
| `DECISIONS.md` | Anything already overturned. **Read this before the spec, not after** — it is newer, and a `No` in its last column means the spec copy is wrong about that thing right now |

Search under **every name the feature travels under** — the surface, the gesture, the setting, the token role, the spec section. These documents cross-reference heavily, and a feature found in one place is a feature half-read. The overlay is also "the compose bar" and "decision 04"; dictation is also "the gesture," "push-to-talk," and "§4.1."

**Then compare what Anthony said against what you found, and surface the differences before writing anything.**

**Ask. Do not resolve it silently in either direction.** A spoken instruction is compressed: it carries the change he is thinking about, not the three decisions elsewhere that depended on the old shape. Acting on it without asking is how a decision gets made by accident — the spec's reasoning is discarded without anyone noticing it was discarded, including him. Deferring to the spec instead is the opposite failure and is already ruled out by §0's corollary.

**The default answer is that Anthony's new instruction wins.** It usually is the update. **That is not a reason to skip the question.** The question is cheap, and it exists to catch the case where he had forgotten a constraint that the old text was carrying — not to challenge him. Expect most of these to end in "yes, the new one," and ask anyway.

**A good question names the contradiction, cites the section, states which way you would go and why, and asks him to confirm.** One question with a recommendation, not a survey of options. If several contradictions surface, ask them together, once, before starting — not one per hour as you hit them.

**If nothing contradicts, say what you found and get on with it.** This is a rule about contradictions, not a requirement to turn every feature into an interview. Silence from the documents is an answer; it means the decision is yours to make and note.

**Then log per §0 and build.**

---

## 1. Where the project actually is

- **Slice 0 (design system) is substantially complete.** `sotto-tokens.md` exists as a template, and ten measurements are locked in `Design.pdf` (held in `Documents/Sotto/designs/`, not copied here).
- **The Xcode project exists** — created 2026-08-15 from the AppKit (XIB) template: Swift Testing, no SwiftData, deployment target 26.5, bundle identifier `com.anthonyprosser.Sotto`. It lives in this repo alongside `docs/`, and **Claude Code creates and maintains it from here.** An earlier rule reserved that for Anthony so the project file would be "exactly what Xcode wrote" — that assumed a reader who could tell the difference, which is not the case.
- **No feature Swift has been written yet.** What exists is template scaffolding: `AppDelegate.swift`, `MainMenu.xib`, and two empty test targets.
- **Slice 1 (Shell) is next.**

Two items are still open inside slice 0 — see §7, Known gaps. Neither blocks slice 1.

---

## 2. The token sheet, and the rule most likely to be broken

`docs/sotto-tokens.md` is a **template, not a document**. Slice 0 ships the structure, the resolution rules, and the provenance columns. It ships **no values**, and §1 and §2 of that file are intentionally empty.

**A token is authored the first time a feature needs it, and never before.** A value written before it has a consumer is a guess defended by nothing, and six months later it is indistinguishable from a real decision. The conventional alternative — enumerate a full type ramp, spacing scale, and radius set up front — was explicitly rejected, because most of those values would be dead on arrival and a dead token looks exactly like a live one.

**Adding a row is a four-part claim. All four are required:**

1. **Role name** — semantic, never descriptive. `surface.raised`, not `gray12`.
2. **First consumer** — the component and slice that demanded it. No consumer, no row.
3. **What system value was ruled out, and why it failed** (tier 2 only). "None fits" is not an answer. Name the closest one — `.tertiaryLabelColor`, `NSFont.preferredFont(forTextStyle: .caption1)`, the standard `NSButton` disabled treatment — and say what it got wrong.
4. **The slice** it was added in, so the sheet's growth reads against the build order.

**Two tiers, no third.**

| Tier | Resolves to |
|---|---|
| 1. Inherited | An AppKit/SwiftUI semantic color, material, font, or metric. Light/dark, accent, and high-contrast adaptation come free |
| 2. Authored | A value Sotto owns because no system value fits |

**There is no tier 3.** It existed through v0.17, held exactly two tokens — `state.error` and `state.network` — and both were deleted in v0.18. The `state.*` namespace went with them. Do not reintroduce the namespace under any name.

**Tier 2 is the list to police.** Its failure mode is authoring something `.tertiaryLabelColor` already handles, which then silently stops matching macOS on the next release. Every tier-2 row is permanent maintenance debt. The correct size of that section is as close to zero as the app permits.

**Exactly three tier-2 entries are pre-approved:**

| Entry | Slice | Why it earns tier 2 |
|---|---|---|
| Waveform idle bar treatment | 3 | The waveform is the one element with no system precedent (§14.3) |
| `scrim.fill` / `scrim.text` | 13 | The scrim is the app's only full-bleed, non-glass surface; Sotto draws the wash, so the text sits on a known dark background in both appearance modes — one fixed pair, not a light/dark branch (§14.7) |
| Overlay intrusiveness values | 9 | Width ratio, internal padding, stroke weight, shadow lift, vertical position, density. macOS has no opinion because no system surface is shaped like the overlay (§14.1) |

**A proposed tier-2 row that is not one of those three is a signal to look harder at tier 1** — not a reason to write the row and move on. If you believe a fourth is genuinely needed, say so, make the four-part claim out loud, and let Anthony rule on it. Then log it in `DECISIONS.md`.

**Handoff rule: components name the role, never the value.** `surface.raised`, not `#2A2A2E`. Where the role is tier 1, name the system API in the same breath — `surface.raised` → `.controlBackgroundColor`. Do this **even when the row does not exist yet**; naming a role with no value is exactly how the lazy rule stays workable.

> **The token sheet's §6 is where decided-but-unbuilt values live.** `sotto-tokens.md` §1 and §2 are deliberately empty; §6 holds every measurement locked in `designs/Design.pdf` until its slice converts it into a row. If you need a number for a surface you are building, look in §6 before concluding nothing has been decided. Its slice numbers are current as of 2026-08-13 and match this build order.

---

## 3. Hard constraints

Each of these is a rule with a reason attached. The reason is load-bearing: a rule without one gets rationalised away at 2am.

**Event tap runs on a dedicated thread, never the main runloop (§2.5).** Hard requirement, not an optimization. If a tap callback blocks the main thread the menu bar goes unresponsive, which breaks quit-as-panic (§10.5) — and quitting is the only reliable shutdown path, because event taps are per-process and die with the process. A wedged tap must never take the UI down with it.

**Synthetic events are tagged and filtered (§2.6).** Sotto posts Cmd+C (selection fallback) and Cmd+V (clipboard paste). Both must be tagged or the app's own hotkey detector fires on its own output:

```swift
let src = CGEventSource(stateID: .privateState)
event.setIntegerValueField(.eventSourceUserData, value: MAGIC)
event.post(tap: .cgAnnotatedSessionEventTap)
```

Post to `.cgAnnotatedSessionEventTap`, **not** the HID tap — that is what delivers reliably to the frontmost app.

**The tap observes modifier keycodes only** — 54/55 for Right/Left Cmd, 58/61 for Option. Carbon's `RegisterEventHotKey` cannot distinguish left from right, which is why there is a tap at all. No key content is read, buffered, or stored, and the code should make that obvious to someone auditing it.

**Right Command is never consumed (§4.1).** It stays a live modifier, so Right-Cmd+C keeps copying.

**Insertion is two strategies, in order (§3): Accessibility, then clipboard paste.** AX writes to `AXValue`/`AXSelectedText` on the focused element — atomic and most robust. Paste is the fallback, second because save-and-restore of `NSPasteboard` is lossy: promised/lazy data cannot be captured, and anything that copies during the window clobbers the restore. **The CGEvent Unicode strategy is deleted.** It existed to serve the human-typing MCP, which is now a separate unrelated project that cannot post keystrokes under Sotto's Accessibility grant anyway.

**No focused field → clipboard and stop (§3).** Never paste into whatever happens to be frontmost. The HUD's waveform morphs into "Copied to clipboard" and fades — that confirmation is the entire reason this path is safe.

**Corners are `.continuous`, never circular (§14.1).** `.rect(cornerRadius:style:.continuous)`, `layer.cornerCurve = .continuous`, or `ConcentricRectangle` where a surface should match the display's own corner. A circular arc jumps from zero to maximum curvature at a point, and that seam is most of what makes a rounded rectangle read as Material Design rather than Apple. **Nested corners are concentric** — a chip inside the compose bar takes the bar's radius minus the inset.

**Real system materials, never a hand-rolled blur (§14.1).** Liquid Glass provides adaptive tint sampled from content behind the surface, a specular highlight along the lit edge, and refraction at the rim. Blur plus a flat fill is not this material. This is the single reason the deployment target is macOS 26. Two deliberately different materials: floating-panel glass for the overlay (Spotlight), Control Center–style glass for the HUD. Both follow system light/dark.

**`maxChunk` = 240,000 samples ≈ 15 s at 16 kHz (§4.2).** Staying under it is a **requirement**, not a target. It is FluidAudio's internal `ChunkProcessor` threshold: cross it and seam handling is handed to FluidAudio, which is exactly what this design refuses. Measured word loss at FluidAudio seams is ~0.17 % — one span in 589 words, ~15 spans per hour. Sotto's overlap-and-reconcile design (§10.3) exists to catch that class of drop, and deferring to the library forfeits it. This is also why the old 30 s whole-buffer rule is gone. `chunkFloor` is 8 s, tunable, always < 15 s.

**A recording that ends under 15 s is always transcribed whole (§4.2).** Any pause found between `chunkFloor` and 15 s starts speculative work that gets discarded if the utterance turns out short. That waste is deliberate — the alternative is waiting 15 s before starting any transcription on long dictation, which is the case that actually needs the head start.

**Word timings: `startTime` only (§9.3).** `endTime` is never read. This sidesteps the FluidAudio #381 bug class and is independently validated by the measurement: word starts hit a floor (all error early, bounded at about −320 ms, 100 % within ±500 ms), while sentence *ends* smear to +1075 ms at long pauses. Parse `buildWordTimings(from:)` and store; do not build an aligner.

**Click-to-seek ships at zero offset (§9.3).** `TDT_EMISSION_DELAY_FRAMES=0` would shift timestamps ~80 ms later for free and is **deliberately unused** — that knob corrects emission delay against CTC peaks, and repurposing it conflates two concerns that will diverge. Early is pre-roll, not error: landing half a second before the clicked word gives the beat of lead-in an audio editor adds on purpose. Keep a config hook; ship at zero.

**Predict, don't gate (principle 3).** Memory pressure produces an **estimate and an amber row, never a disabled control**. Rows turn amber past ~60 % of physical RAM and stay selectable; loading past that is the user's call. **Hardware never gates a feature.** The one exception is model *capability*: **vision is the only gate, and it gates on the model, not the machine** (§7.2). A text-only model cannot see an image — that is a fact about the model, not a judgment about the user's hardware.

**No global error token and no central error vocabulary (§14.3).** `state.error` listed its own scope as "Appears in: Anywhere," which is the tell — a token that appears anywhere describes nothing about where to look. Errors route to the surface that owns the work that failed, decidable at throw time rather than display time:

| Failure | Surfaces in |
|---|---|
| Transcription fails; audio or cleanup model fails to load; cleanup fails mid-pass; AX write rejected | HUD (§4.5) |
| Chat model load, generation, or tool call fails | Chat — overlay or main window |
| File transcription fails | Main window, Audio pane |
| Model download fails | The model list where the download started (§7.4) |

**Nothing is a notification and nothing is modal.** Sotto has no Notifications permission and does not acquire one. An error firing with no surface on screen is not a case that exists — every failure belongs to a pipeline the user started from a surface, and that surface is where it waits. Wording is per-error and lives with the feature.

**Two disabled patterns only, and no third (§14.7).** Controls take the **system disabled state with the reason in the tooltip** — a disabled `NSMenuItem` reads as disabled everywhere else on the machine, and authoring a per-role disabled color would be a tier-2 value duplicating something AppKit does correctly. The screenshot **gesture** takes a **full-screen scrim**, because there is no control to gray out and the gesture would otherwise die silently: the user repeats it, concludes the app is broken, and never learns why. If a second gesture gate ever appears it reuses the scrim; a second control gate takes the system disabled state.

**`Cmd+,` for settings, never `Cmd+.` (§8.3).** `Cmd+.` is the historical macOS cancel binding; registering it globally would break cancel everywhere else on the machine.

**The overlay must never flip the activation policy (§10.2).** The main window opening flips to `.regular` and back to `.accessory` on close, and that transition steals focus — usually desired there, never for the overlay. Build the guard in slice 1, before there is an overlay to forget it in.

**Principle 1 is a consent rule, not a count.** Every outbound connection is either something the user just did or something the user switched on. Three exist: a model download the user started (§7.4), an MCP server the user enabled (§6, disabled out of the box), and the update check (§10.6, default on, weekly, one toggle). Earlier versions claimed zero outbound connections, then a closed list of two; both were the wrong shape, because the constraint was never about how many. **That test is what permanently rules out telemetry, crash reporting, analytics, and remote config** — not a list, but the fact that nobody asks for them, so they can never pass. Anything that would connect without the user having done something or turned something on does not get built. `SUEnableSystemProfiling` is written into `Info.plist` as an explicit `NO`, not left to Sparkle's default — enabled it appends CPU type, core count, RAM, OS version, model identifier, and preferred language to the appcast URL, a machine fingerprint on the only request Sotto sends. EdDSA verification is mandatory and the appcast is HTTPS-only.

**Platform floor: macOS 26, Apple silicon only, Swift / AppKit.** The floor is genuine — macOS 14 and 15 cannot run Sotto, because Liquid Glass, continuous corners, and concentric radii come from real system APIs rather than `NSVisualEffectView` approximations. It also fixes which SF Symbols and materials exist, so it is upstream of every decision in §14.

---

## 4. Do not resurrect

These were in the spec and were cut. A model trained on older context will try to bring each of them back, usually as a helpful suggestion. Each cut has a reason; the reason is why it stays cut.

| Deleted | Why it was cut |
|---|---|
| **Live transcript layer in the HUD** | Deleted, not defaulted off. It would show raw text that cleanup then rewrites, so what the user read would not be what got inserted — and it would force per-chunk results to surface before §4.2's whole-buffer pass could correct them. The HUD is a waveform plus two completion messages plus an error morph. That is the entire vocabulary |
| **Live-streaming insertion** | Cut from v1 entirely. It was specified as available-when-cleanup-is-off, which made the interaction between two settings load-bearing for a feature nobody had used. Cleanup stays optional and ships; streaming does not. Dictation always dumps at the end |
| **`state.recording` / `state.latched`** | The requirement dissolved. The user's hand carries the push-to-talk vs. latched distinction — you know whether your finger is on the key. What was missing was confirmation that capture is live at all, and the mandatory waveform does that alone |
| **`state.error` / `state.network`** | Deleted in v0.18, which emptied tier 3 and removed the `state.*` namespace. See §14.3 — errors route per-surface |
| **The theme struct and the Appearance tab** | v0.13 specified a mode picker, theme picker, tinted-surfaces toggle, and glass-opacity slider; v0.14 deleted all of it. Appearance is inherited wholesale from System Settings (§8.5). Cost accepted: users who want Sotto to look different from their system cannot. Benefit: the entire theme layer disappears. Do not reintroduce it as a "small" preference |
| **Network badge on MCP-enabled features** | Specified through v0.17, cut. Opt-in and off-by-default carry principle 1 on their own; a marker seen on every launch after a choice made once is decoration, and it competes for the same peripheral attention the HUD needs. Do not reintroduce it as a settings-pane flourish either |
| **Three bundled search MCPs** | SearXNG, DuckDuckGo, and a bring-your-own-key slot shipped in v0.16 — three surfaces for one capability, and the DuckDuckGo HTML scrape was the one that would break first. **One now: Tavily**, disabled by default. Exa was the closest call and lost on cost predictability at volume |
| **Sentence-following playback highlight** | Cut. Seeking is navigation; a following highlight is decoration. The real uses — spot-checking a suspicious transcript, finding the one thing someone said in an hour-long import — are both "take me to that moment." Independently validated by the `endTime` smear finding (§9.3) |
| **Model selector in the compose bar** | The menu bar owns model choice (§10.1). Duplicating it spends the bar's most valuable property, its emptiness |
| **CGEvent Unicode insertion strategy** | Deleted with the human-typing MCP, which is now a separate unrelated project. As an out-of-process MCP it cannot post keystrokes under Sotto's Accessibility grant, so there was nothing left for the strategy to serve |

Also gone and not coming back: Binoculars AI-detection, the Out-of-scope section, HUD waveform on/off (the waveform is mandatory), insert-mode in profiles, and the zero-outbound guarantee (replaced by the consent rule, not weakened into a longer list).

---

## 5. The four threads that cross slices

Four things are built in pieces and go wrong if each slice treats them as local.

**The idle / not-idle signal (§14.8).** Defined in **slice 1**; fed by slices **3, 7, 9, 10, 11, 14**. Not idle covers: recording (either gesture, including latched), overlay open, main window open, a response generating, a file transcription running, cleanup running, a model loading. Define it once as a single observable with a documented contributor list, or seven later slices each quietly add a second source of truth. The icon reports that Sotto is **awake**, not that Sotto is recording — macOS 26 already draws its own mic indicator in the same menu bar, and duplicating it would be Sotto asserting something the system asserts better.

**The Escape priority stack (§10.4).** Exactly one action fires, resolved top-down:

1. Abort in-flight gesture → discard audio, insert nothing, **and disarm the gesture** — slice **2**
2. Cancel transcription in progress — slice **3**
3. Stop chat generation — slice **9**
4. Close overlay — slice **9**

Slice **13**'s scrim preempts all four while it is up. The global monitor installs **only while app UI is live** — Escape is never swallowed system-wide.

**Error routing (§14.3).** No central error type, no central vocabulary. Each failure names its own surface at the point it is thrown: audio-side → HUD, chat-side → chat, file transcription → main window Audio pane, model download → model list. Surfaces are designed in the slice that owns them — slice **6** designs the file-transcription failure slot even though nothing produces one until slice **14**. Nothing is a notification and nothing is modal.

**The token sheet's growth (§14.2).** One row at a time, each a four-part claim (role, first consumer, system value ruled out, slice). Starts empty in slice **1** with whatever the menu and settings window actually consume. Tier 2 is the list to police; three entries are pre-approved — waveform idle bar (slice **3**), the scrim pair (slice **13**), overlay intrusiveness (slice **9**). Anything else proposed for tier 2 is a signal to look harder at tier 1.

---

## 6. How to work a slice

**`docs/sotto-build-order.md` is the operational plan.** Sixteen slices, 0 through 15. It **supersedes spec §13**, which is a twelve-line sketch kept for orientation; where they disagree, the build order wins, and it carries the mapping at the end.

Each slice names its spec sections in a **Spec:** line. Read those sections before writing code for that slice — the build order states what to build, the spec states why, and the why is what tells you which shortcuts are fatal.

Ordering rule throughout: nothing depends on something built later, and every slice ends at a state that can actually be used. Four slices have no design surface at all — **2, 4, 5, and 7** — and go straight to code.

Working rhythm: design the slice in Claude Design, screenshot it, hand it over, build it in Swift, use it, move on. When designs arrive, expect them to be wrong about material in four specific ways — corners render as circular arcs, blur is not refraction, there is no adaptive tint, there is no specular edge. **Judge proportion from a mockup; judge material only in Swift (§14.9).**

**Current position: slice 0 substantially complete, Xcode project scaffolded and building, no feature Swift written, slice 1 (Shell) is next.**

Slice 1 builds: `.accessory` at launch, the §10.1 `NSMenu` with stubbed submenus, the settings window on `Cmd+,`, the activation-policy flip with the overlay guard, both menu bar icon states, the idle/not-idle observable, and the token layer as a thin mapping — **no theme struct**, but the indirection must exist so the inherited-vs-authored boundary stays auditable in one file.

---

## 7. Known gaps — do not invent answers to these

Three things are genuinely undecided. If a slice needs one, **ask Anthony**. Inventing an answer here produces something that looks settled and is not.

**1. Decision 04 — the in-app chat — has no home in the spec.** `designs/Design.pdf` locks an edge-anchored, full-height wash with no panel edge, no chat picker, and a 390 x 81 pt glass composer (`sotto-tokens.md` §6.4). Spec §5.8 describes something different: a bounded floating panel, 600 pt bar, growth to 180 pt, cap at the lesser of 720 pt and 70% of usable height. They may be one surface in two states or two surfaces; **the spec does not say, because it predates the decision.** Slice 9 or 10 has to reconcile them, and the reconciliation belongs in §5 rather than in the token sheet. Do not pick one and build it.

**2. The two anchor numbers are still not constants, but the overlay's now decomposes.** Design.pdf quotes the overlay's **118 pt** bottom offset alongside an **84 pt Dock** and a **34 pt clearance**, each with its own ratio — 118 = 84 + 34, which is the shape of an invariant rather than a coincidence. The likely token is therefore *"clears the Dock's current height by 34 pt (0.654 bar heights),"* not the constant. **Two cases that decomposition does not cover:** a Dock positioned left or right, where there is no bottom occlusion at all, and an auto-hidden Dock, where occlusion is zero until it is not. The HUD's **8%** top position does not decompose — it came from an assumed 1512 x 982 screen with a 24 pt menu bar, and a notched MacBook Pro menu bar is taller than 24 pt. Decide per anchor whether it is a fixed value or a rule, and record which.

**3. The send button's volume contradicts §14.3.** §14.3 rejects "a saturated send button — the loudest thing in Gemini's bar and the first thing that makes it feel intrusive," and §5.8 restores the button but explicitly "not its volume." Design.pdf decisions 01 and 04 both draw it as a **filled 26 pt accent circle**, the most saturated element in either surface. Either the drawn treatment is what §14.3 warned against, or §14.3's objection was to size or position rather than fill. **Slice 9 decides, and whichever way it goes, one of the two documents needs amending.** Do not resolve this by picking the drawing over the spec because the drawing is more recent.

A further slice-0 item is open but gates nothing: the **app icon layer breakdown** for Icon Composer. The mark is locked — two capsules forming an S, lower occluding upper. The layer split is an asset decision, not a token.

---

## 8. Open issues (spec §12)

Five, all live:

1. **MCP Swift SDK lags the protocol.** `modelcontextprotocol/swift-sdk` 0.12.1 (May 2026) implements 2025-11-25; Sotto targets 2026-07-28, which removes the handshake and sessions and adds Multi Round-Trip Requests. Wait, fork, or write the client directly against the spec. Decide before writing a line of slice 12.
2. **SwiftUI / AppKit split.** Liquid Glass is SwiftUI-first (`glassEffect`); AppKit's `NSGlassEffectView` is thinner. If floating surfaces go SwiftUI inside `NSPanel`s while the main window stays AppKit, every §14.2 role needs both a `Color` and an `NSColor` form.
3. **Focus changes mid-transcription.** User dictates into a field, then clicks away before transcription finishes. Original target, or clipboard? Routing to the original risks writing into a window the user has left; the clipboard is safe but surprising when the field is still right there.
4. **Cleanup reasoning: toggle, and default.** May help punctuation on ambiguous prosody; multiplies latency on the step between speaking and seeing text. §8.1 currently defaults it open. Lands in slice 11.
5. **Bare compose bar growth.** The full panel grows, then caps and scrolls. Whether a standalone bar with no conversation above it does the same or caps sooner is undecided — a bar that grows to 180 pt with nothing above it may read as broken rather than accommodating. Decide in slice 9's design pass, not in code.

**Deferred, decided in principle, not built:** an **optional cloud model fallback**. Permitted by principle 1, because it cannot happen without the user pasting a key — an act at least as explicit as enabling an MCP. **Not in v1.** Recorded so a later version does not re-argue whether it is allowed. When built it inherits the rule: the user provides the credential, the user can see when a turn went to it, and there is no silent failover from a local model that is merely slow. Nothing in the harness should assume the model is local, which principle 6 already requires.

---

## 9. Quick reference

| | |
|---|---|
| Gestures | Hold or double-tap **Right Cmd** → dictate (routes to chat if text is selected). Double-tap **Option** → overlay |
| STT | Parakeet TDT v3 on the ANE (does not contend with the LLM on GPU); Whisper large-v3-turbo alternate |
| LLM | `mlx-swift` embedded; OpenAI-compatible adapter for Ollama `:11434`, `llama-server`, LM Studio |
| VAD | Silero, 32 ms frames |
| Reference machine | MacBook Neo, 8 GB unified memory — the development target, not a runtime floor |
| Memory estimate | `weights + KV + ~15 % overhead`; amber past ~60 % of physical RAM; always advisory |
| Permissions | Accessibility, Input Monitoring, Microphone at first run; **Screen Recording deferred to the first screenshot**. No Notifications, ever |
| Storage | Chats as one folder each with `chat.md` + `attachments/`; audio as Opus @ 24 kbps (~0.18 MB/min vs WAV's ~1.9) |
| Retention | Audio: ring of 8 by default. Chats: unlimited. Both configurable, both with a pin flag. Imports auto-pinned |

**Voice for anything you write here.** Anthony's documents are reasons-first: they name the rejected option and say why it lost, and they end sections with a verdict. Match it. Dense, no padding, no cheerleading. When you disagree with a decision, say so with the reason and let him rule — a silent workaround in code is the one failure mode this whole document is built to prevent.
