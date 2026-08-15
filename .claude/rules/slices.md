# How to work a slice, and the four things that cross them

**Open this when starting a slice, or when the work lands in more than one.** `CLAUDE.md` §0.1 routes you here.

---

## 1. The build order is the operational plan

**`docs/sotto-build-order.md` is the plan.** Sixteen slices, 0 through 15. It **supersedes spec §13**, which is a twelve-line sketch kept for orientation; where they disagree, the build order wins, and it carries the mapping at the end.

Each slice names its spec sections in a **Spec:** line. **Read those sections before writing code for that slice** — the build order states what to build, the spec states why, and the why is what tells you which shortcuts are fatal.

Ordering rule throughout: nothing depends on something built later, and every slice ends at a state that can actually be used. Four slices have no design surface at all — **2, 4, 5, and 7** — and go straight to code.

**Working rhythm:** design the slice in Claude Design, screenshot it, hand it over, build it in Swift, use it, move on. When designs arrive, expect them to be wrong about material in four specific ways — corners render as circular arcs, blur is not refraction, there is no adaptive tint, there is no specular edge. **Judge proportion from a mockup; judge material only in Swift (§14.9).**

---

## 2. Slice 1 — Shell, the one that is next

Builds: `.accessory` at launch, the §10.1 `NSMenu` with stubbed submenus, the settings window on `Cmd+,`, the activation-policy flip **with the overlay guard**, both menu bar icon states, the idle/not-idle observable, and the token layer as a thin mapping — **no theme struct**, but the indirection must exist so the inherited-vs-authored boundary stays auditable in one file.

---

## 3. The four threads that cross slices

Four things are built in pieces and go wrong if each slice treats them as local.

**The idle / not-idle signal (§14.8).** Defined in **slice 1**; fed by slices **3, 7, 9, 10, 11, 14**. Not idle covers: recording (either gesture, including latched), overlay open, main window open, a response generating, a file transcription running, cleanup running, a model loading. Define it once as a single observable with a documented contributor list, or seven later slices each quietly add a second source of truth. The icon reports that Sotto is **awake**, not that Sotto is recording — macOS 26 already draws its own mic indicator in the same menu bar, and duplicating it would be Sotto asserting something the system asserts better.

**The Escape priority stack (§10.4).** Exactly one action fires: abort in-flight gesture (slice **2**) → cancel transcription (slice **3**) → stop chat generation (slice **9**) → close overlay (slice **9**). Slice **13**'s scrim preempts all four. Full rule in `.claude/rules/input-and-insertion.md` §3.

**Error routing (§14.3).** No central error type, no central vocabulary. Each failure names its own surface at the point it is thrown. Surfaces are designed in the slice that owns them — slice **6** designs the file-transcription failure slot even though nothing produces one until slice **14**. Full table in `.claude/rules/design.md` §10.

**The token sheet's growth (§14.2).** One row at a time, each a four-part claim. Starts empty in slice **1** with whatever the menu and settings window actually consume. Three tier-2 entries are pre-approved — waveform idle bar (slice **3**), the scrim pair (slice **13**), overlay intrusiveness (slice **9**). Full rule in `.claude/rules/design.md` §9.

---

## 4. Which slice hits which open question

Do not build past one of these without asking — `.claude/rules/open-questions.md`.

| Slice | Question |
|---|---|
| **9** | Send button volume (gap 3); bare compose bar growth (issue 5); the chat's shape if it lands here (gap 1) |
| **9 / 10** | The overlay and HUD anchor numbers — value or rule (gap 2) |
| **10** | Decision 04's shape, three-way (gap 1) |
| **11** | Cleanup reasoning toggle and default (issue 4) |
| **12** | MCP Swift SDK vs. protocol version (issue 1) — **decide before the first line** |
| Any | SwiftUI / AppKit split (issue 2); focus change mid-transcription (issue 3) |
