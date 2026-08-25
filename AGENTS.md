# Sotto — instructions for Claude Code

Menu-bar macOS app: system-wide dictation plus an overlay chat, both entirely on-device. Swift / AppKit, macOS 26 floor, Apple silicon only. Author: Anthony Prosser. Open source intent.

**This file is the always-on layer, and it is deliberately short.** What it holds applies to every session and every kind of work in this repo. Everything that applies to *one* kind of work — drawing, the event tap, transcription, models and network, working a slice — lives in `.claude/rules/`, and **§0.1 says which file to open when.**

Open the rule file your work needs. Do not read them all, and do not move their content back here. A rule this file states unconditionally gets read on every task including the ones it has nothing to do with; that is the cost, and it is why the bar for living here is *applies everywhere*, not *important*.

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

**The only files you write in this repo without asking:** Swift sources, project files, `DECISIONS.md`, this file, and `.claude/rules/*`. Everything under `docs/` is read-only.

**That last sentence is enforced, not just asserted.** `.claude/settings.json` denies `Edit` and `Write` on `docs/**`, so a refusal there is the rule working rather than a broken tool — do not route around it, and do not ask for it to be lifted. Reading is unaffected. The one sanctioned write into `docs/` is Anthony's `cp` re-sync in `docs/README.md`, which is a shell command and therefore untouched by the deny. The prose above stays because the deny cannot explain *why*, and §0's reasoning is what stops the workaround.

---

## 0.1 Before you build — read first, ask second, build third

**When Anthony names a feature to build, the first move is never code and never the build-order slice on its own. It is a search.** Three layers, in this order.

### 1. The rule file for the kind of work

| About to | Open |
|---|---|
| Put pixels on screen — a view, a material, a radius, a mockup conversion, **any numeric or hex literal in a view** | `.claude/rules/design.md`, **all 351 lines of it.** Authoring or changing what is drawn is the case it exists for, and its fast path (§1 → §3 → §9) is a starting order, not a licence to stop there |
| Edit view code **without changing what is drawn** — a rename, a binding, an `isHidden` fix | `design.md`'s §14 grep, and whichever sections its own index sends you to. A non-visual edit does not earn the full read; **`CLAUDE.md` §0.4 still applies** — if the result looks different, you were wrong about it being non-visual |
| Touch the event tap, a gesture, a hotkey, Escape, the activation policy, or writing text into another app | `.claude/rules/input-and-insertion.md` |
| Touch capture, chunking, transcription, word timings, seek, or the HUD's content | `.claude/rules/audio-and-transcription.md` |
| Load a model, estimate memory, add an outbound connection, or touch MCP or the updater | `.claude/rules/models-and-network.md` |
| Start a slice, or land work in more than one | `.claude/rules/slices.md` |
| Touch anything in §2's list of open questions | `.claude/rules/open-questions.md` — **and ask, do not decide** |

Work that spans two areas opens both. **Beyond two, the slice is the router, not this table** — open `rules/slices.md`, find the owning slice, and add domain rules only as the work actually reaches them; a feature touching four areas does not open four files up front. Work that fits none of them proceeds on this file alone — and if that keeps happening in one area, that area wants a rule file (§0.2).

### 2. The project documents, for the feature itself

**Find every mention before you start.** A feature is almost never described in one place, and these each hold a different part of it:

| Where | What it holds |
|---|---|
| `docs/sotto-spec.md` | The behaviour and, more importantly, the reasoning — what was rejected and why |
| `docs/sotto-build-order.md` | Which slice owns it, what it depends on, and the **Done when** line that defines finished |
| `docs/sotto-tokens.md` | Any locked measurement, usually in §6 before its slice converts it to a row |
| `DECISIONS.md` | Anything already overturned. **Read this before the spec, not after** — it is newer, and a `No` in its last column means the spec copy is wrong about that thing right now |
| `docs/Design.pdf` | What the surface looks like at real size, and how it sits against the rest of the screen. Its numbers are already in `sotto-tokens.md` §6 — go there for those |
| `docs/sotto-chat-response-concept.svg` | The anatomy of a chat turn, and nothing else. Not locked, not measured, canonical nowhere |

**That list is where to start, not a guarantee of completeness.** Grep the repo for every name the feature travels under — surface, gesture, setting, token role, spec section. The overlay is also "the compose bar" and "decision 04"; dictation is also "push-to-talk" and "§4.1." A feature found in one place is a feature half-read.

### 3. Then ask

**Put every contradiction between what Anthony said and what you found to him, before writing anything. Do not resolve it silently in either direction.** A spoken instruction is compressed: it carries the change he is thinking about, not the three decisions elsewhere that depended on the old shape. Acting on it unasked is how a decision gets made by accident — the spec's reasoning discarded without anyone noticing, including him. Deferring to the spec instead is the opposite failure, already ruled out by §0's corollary.

**The default answer is that his new instruction wins**, and that is not a reason to skip the question. It exists to catch the constraint he had forgotten the old text was carrying. Expect most to end in "yes, the new one," and ask anyway.

**Ask well:** name the contradiction, cite the section and the file, say which way you would go and why. All of them together, once, before starting — not one per hour as you hit them.

**Three tiers, because "ask when unsure" turns into asking about everything.** Sort what you found before you interrupt:

1. **The documents decide it** → follow them. No question, no report.
2. **Nothing decides it, and the choice is implementation-local** — a name, a file split, an order of operations, anything invisible in the built app → **decide it yourself** using the nearest existing convention, and note it in one clause. Silence from the documents is permission, not a blocker.
3. **A contradiction, one of §2's eight, or a choice a user would notice** — behaviour, wording, a surface, a number that ships → **ask.** These are the ones where a wrong guess looks settled.

**Report the search only when it changed something.** A contradiction found, a decision taken under tier 2, a document that turned out stale — those go in the reply. A search that confirmed what you already intended to do does not; do the work instead of narrating the reading.

---

## 0.2 Standing instructions — write them down, yourself, in the right file

**If Anthony says it twice, or says "always," "from now on," "make sure you," or "remember to," it is a standing instruction and it gets written down.** Add it in the session it was said, and say that you did.

A session ends and takes its context with it. An instruction given three times across three sessions was never written down once — the repetition is the symptom, and Anthony should not have to be the persistence layer for his own project.

**Which file:**

- **Applies to every kind of work here** → this file. That is a high bar; most instructions fail it.
- **Applies to one kind of work** → the matching `.claude/rules/` file, and nothing else changes here. If §0.1's table would not route a reader to it, add the routing row; do not smuggle the rule into this file instead.
- **No rule file fits and one area keeps accumulating** → add a rule file, add its row to §0.1's table, say you did.

**Not the same as `DECISIONS.md`.** These files hold how to work and what the constraints are. `DECISIONS.md` holds decisions that contradict, extend, or resolve the spec. **A rule about how you behave is never a `DECISIONS.md` entry; a change to what Sotto does is never a rule here.**

**Keep it true.** When something any of these files asserts stops being true — a status, a path, a rule superseded — fix it in the same session it changed. §0.1 sends future sessions here to research; a confident false statement is worse than a missing one.

---

## 0.3 Least code, reused — Anthony asked for this by name

**"I want the least amount of code possible to make the same amount of work. So basically as efficient as possible, and reuse code — do not build helper functions over and over again."** Said on 2026-08-15, with the explicit instruction that it be recorded.

- **Before writing a helper, search for one.** The failure is not a bad helper; it is the third private `func padded(_:)` in the third file, each subtly different, none of them wrong enough to notice.
- **A new file needs a reason.** So does a new type. Sotto is one app, not a framework, and the indirection budget is small.
- **Delete on the way past.** Code that a change made dead goes in the same commit as the change.
- **This does not license clever.** Fewest lines is not the goal — fewest *concepts* is. One well-named function used in four places beats a dense one-liner nobody can modify.

**One stated exception:** the token layer's indirection, because §14.2's inherited-vs-authored boundary has to stay auditable in one file (`rules/design.md` §9). A stated exception with a reason is the only kind that counts.

---

## 0.4 Say it when the look changes

**When a refactor changes how something looks, say so — even when appearance was not the point of the change.** You can screenshot your own output; do it before and after any restructure that touches view code, and report any difference you did not intend.

This is here rather than in `rules/design.md` because the case that produced it was *not* design work — it was a split-view restructure that flattened a sidebar gradient Anthony liked, and nobody opened a design file that session. The full account, and how to spot the cause, is `rules/design.md` §8.3.

---

## 0.5 Change what was asked for, and nothing adjacent

**Touch the code the request needs. Leave the rest alone, including the parts that are wrong.** The failure is never one big unasked rewrite; it is the rename done in passing, the reformat that came free with the editor, the third file "tidied while I was in there." Each is defensible alone. Together they produce a diff where the one line that changed behaviour is indistinguishable from forty that did not, and the review that would have caught the bug does not happen.

**Match the file you are in, not the style you would choose.** Naming, comment density, and structure are set by the surrounding code. A file written in one idiom and edited in another is worse than a file written badly and consistently.

**This does not contradict §0.3's "delete on the way past" — read the boundary carefully.** Code that *your change* made dead belongs in your commit, because leaving it is how the codebase accumulates orphans nobody dares remove. Code that was already dead before you arrived is a separate change and gets proposed, not performed. The test is whether your edit is what killed it.

**When you see something genuinely wrong outside your scope, say so and keep going.** One sentence in the reply beats a fix nobody asked for. Anthony decides what gets opened next; that is not a formality, because in this repo an "obvious" fix is routinely a decision the spec already argued about (§0.1).

---

## 0.6 State what would prove it worked, before writing it

**A vague task is not a task yet. Settle what would prove it worked before writing it, then go and check.** For a slice, `docs/sotto-build-order.md` supplies the line — its **Done when** clause is the criterion and it is not optional. For anything else, decide one yourself. **Keep it to yourself unless it changes the scope**, or the task was loose enough that Anthony might have meant a different bar; §0.1's reporting rule holds here too. The criterion exists to steer the work, not to be announced before it.

**Verification is running the thing. It is not re-reading your own diff.** Reasoning about whether code works is the same activity that produced the defect, so it cannot be the thing that catches it. Build it, launch it, screenshot it (`rules/design.md` §8), or write the test. Slices **2, 4, 5, and 7** have no design surface and therefore no screenshot loop — they still need a stated observation or a test, and "it compiles" is neither.

**Assume the first attempt is wrong and leave room to find out.** The expensive failure mode is a long confident linear run that was mistaken at step two and never checked until step nine. Short loop, real output, adjust. This is the same instinct as §0.1's read-before-build, applied to the end of the work instead of the start.

**One rejection worth keeping, in one line:** proposals to collapse `.claude/rules/*` back into this file have been made and refused twice, for the reason at the top of this file.

---

## 1. Where the project is — not stated here, on purpose

**Slice 1 is in progress. For anything more specific than that, read `DECISIONS.md` newest-first and `git log`.** Between them they carry what has actually been settled and built; this file carried a summary of it for one day and was wrong about three things by the second — it claimed no feature Swift existed after `Sotto/Design/Token.swift` was committed, and it listed an open issue that a decision had already closed.

**So the rule is: no status lines here, ever again.** Not a slice number, not a file inventory, not a "next up." A status line in the always-on layer is read as authority, updated by whoever remembers, and wrong the moment someone commits without opening this file. `DECISIONS.md` is append-only and dated, which is why it survives what this section could not.

**Claude Code creates and maintains `Sotto.xcodeproj` from this repo.** An earlier rule reserved that for Anthony so the project file would be "exactly what Xcode wrote" — that assumed a reader who could tell the difference, which is not the case. Its settings live in the project file; do not restate them here either.

---

## 2. Rules with no home but this one

Five things that hold no matter what you are touching.

**Platform floor: macOS 26, Apple silicon only, Swift / AppKit.** The floor is genuine — macOS 14 and 15 cannot run Sotto, because Liquid Glass, continuous corners, and concentric radii come from real system APIs rather than `NSVisualEffectView` approximations. It also fixes which SF Symbols and materials exist, so it is upstream of every decision in spec §14.

**Principle 1 is a consent rule, not a count.** Every outbound connection is either something the user just did or something the user switched on. Three exist: a model download, an enabled MCP server, the weekly update check. **That test is what permanently rules out telemetry, crash reporting, analytics, and remote config** — not a list, but the fact that nobody asks for them, so they can never pass. Anything that would connect without the user having done something or turned something on does not get built. Mechanics in `rules/models-and-network.md` §2.

**Nothing is a notification and nothing is modal.** Sotto has no Notifications permission and does not acquire one. An error firing with no surface on screen is not a case that exists — every failure belongs to a pipeline the user started from a surface, and that surface is where it waits. Routing table in `rules/design.md` §10.

**Predict, don't gate.** Hardware never gates a feature; it produces an estimate and an amber row. The one exception is model capability, and it gates on the model, not the machine. Detail in `rules/models-and-network.md` §1.

**Seven things are undecided, and inventing an answer to one produces something that looks settled and is not.** Ask. The names are here rather than behind the pointer because the failure is answering a question you did not know existed — a pointer only helps a reader who already suspects. Reasoning in `rules/open-questions.md`; which slice hits which in `rules/slices.md` §4.

> Gaps: **1** the in-app chat's shape, three-way · **2** the overlay and HUD anchor numbers, value or rule · **3** the send button's volume.
> Issues: **1** MCP Swift SDK vs. protocol version · **3** focus change mid-transcription · **4** cleanup reasoning toggle and default · **5** bare compose bar growth.
> Numbers track spec §12 and never get renumbered. **Issue 2 (the SwiftUI / AppKit split) is closed** — every view is SwiftUI; AppKit holds the delegate, the status item, and the `NSWindow`/`NSPanel` hosts. See `DECISIONS.md`, 2026-08-15.

---

## 3. Do not resurrect

Each of these was in the spec and was cut. **A model trained on older context will try to bring each of them back, usually as a helpful suggestion.** The names are here so the tripwire fires without opening a file; every reason is one click away, and the reason is why it stays cut.

| Cut | Reason lives in |
|---|---|
| Live transcript layer in the HUD · live-streaming insertion · sentence-following playback highlight · Binoculars AI-detection | `rules/audio-and-transcription.md` §4 |
| `state.recording` / `state.latched` · `state.error` / `state.network` and the whole `state.*` namespace · tier 3 · the theme struct and the Appearance tab · network badge on MCP features · model selector in the compose bar · HUD waveform on/off | `rules/design.md` §12 |
| CGEvent Unicode insertion strategy | `rules/input-and-insertion.md` §2 |
| Three bundled search MCPs (SearXNG, DuckDuckGo, BYO-key) | `rules/models-and-network.md` §3 |

Also gone: the Out-of-scope section, insert-mode in profiles, and the zero-outbound guarantee — replaced by the consent rule in §2, not weakened into a longer list.

---

## 4. Quick reference

| | |
|---|---|
| Gestures | Hold or double-tap **Right Cmd** → dictate (routes to chat if text is selected). Double-tap **Option** → overlay |
| STT | Apple `SpeechAnalyzer` / `SpeechTranscriber`, **the only v1 backend**; `DictationTranscriber` past its 30 locales. Runs on the ANE, **shared with the LLM** |
| LLM | Apple `SystemLanguageModel` by default; `mlx-swift` embedded; OpenAI-compatible adapter for Ollama `:11434`, `llama-server`, LM Studio |
| VAD | `SpeechDetector`, preinstalled |
| Reference machine | MacBook Neo, 8 GB unified memory — the development target, not a runtime floor |
| Memory estimate | `weights + KV + ~15 % overhead`; amber past ~60 % of physical RAM; always advisory |
| Permissions | Accessibility, Input Monitoring, Microphone at first run; **Screen Recording deferred to the first screenshot**. No Notifications, ever |
| Storage | Chats as one folder each with `chat.md` + `attachments/`; audio as Opus @ 24 kbps (~0.18 MB/min vs WAV's ~1.9) |
| Retention | Audio: ring of 8 by default. Chats: unlimited. Both configurable, both with a pin flag. Imports auto-pinned |

---

## 5. Voice, for anything you write in these files

Anthony's documents are reasons-first: they name the rejected option and say why it lost, and they end sections with a verdict. Match it. Dense, no padding, no cheerleading. When you disagree with a decision, say so with the reason and let him rule — **a silent workaround in code is the one failure mode this whole structure is built to prevent.**
