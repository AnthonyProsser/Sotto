# Sotto — Token sheet

**Status:** Template. Slice 0 deliverable, per `sotto-spec.md` §14.
**Companion to:** §14.1–§14.9. This file holds values; §14 holds the argument for them.
**Rule:** A token is written here the first time a feature needs it. Not before.

---

## 0. How this sheet works

**This file starts empty and stays as short as the app allows.** §14 reversed the conventional order: slice 0 ships the structure and the rules, not a filled-in type ramp and spacing scale. A value authored before it has a consumer is a guess defended by nothing, and it is indistinguishable from a real decision six months later.

**Resolution order is strict. Every token tries tier 1 first.**

| Tier | Resolves to | Where it goes |
|---|---|---|
| **1. Inherited** | An AppKit/SwiftUI semantic color, material, font, or metric | §1 |
| **2. Authored** | A value Sotto owns because no system value fits | §2 |

There is no tier 3. Reserved states were deleted in v0.18 (§14.2, §14.3).

**Adding a row is a four-part claim, and all four are required:**

1. The **role name**, semantic and never descriptive. `surface.raised`, not `gray12`.
2. The **first consumer** — the component and slice that demanded it. A row with no consumer does not belong in this file yet.
3. For tier 2 only: **what system value was ruled out and why.** "None fits" is not an answer. Name the closest one — `.tertiaryLabelColor`, `NSFont.preferredFont(forTextStyle: .caption1)`, the standard `NSButton` disabled treatment — and say what it got wrong.
4. The **slice** it was added in, so this file's growth can be read against the build order.

**Tier 2 is the list to police.** Its failure mode is authoring something the system already handles, which then silently stops matching macOS on the next release. Every row here is a small permanent maintenance debt. The correct size of §2 is as close to zero as the app permits.

**Handoff rule (§14.2):** components name the role, never the value. Where the role is tier 1, name the system API in the same breath — `surface.raised` → `.controlBackgroundColor`.

**Slice numbers in this file follow `sotto-build-order.md` v0.18 — sixteen slices, 0 through 15.** They were rewritten on 2026-08-13; the numbers this file carried before that date were the old fourteen-slice map and were wrong for the overlay, the scrim, the segmented pill, and model download. If a slice number here disagrees with the build order, the build order wins.

---

## 1. Inherited (tier 1)

**Empty.** No feature has been built.

| Role | Resolves to | First consumer | Slice |
|---|---|---|---|
| — | — | — | — |

**Expected sources when rows arrive**, so the first ones do not get invented:

- Color → `NSColor` / SwiftUI `Color` semantic colors. `.labelColor`, `.secondaryLabelColor`, `.tertiaryLabelColor`, `.separatorColor`, `.controlAccentColor`, `.controlBackgroundColor`, `.selectedContentBackgroundColor`
- Material → real system materials, never a hand-rolled blur (§14.1). Floating-panel glass for the overlay, Control Center–style glass for the HUD
- Type → `NSFont.preferredFont(forTextStyle:)`, which tracks accessibility text size at runtime (§14.4)
- Motion → the system's standard duration and curve for the equivalent transition (§14.6)
- Metrics → whatever macOS publishes or implies. Do not pick a number where the system states one (§14.5)

---

## 2. Authored (tier 2)

**Empty.** No feature has been built.

| Role | Value | First consumer | System value ruled out | Why it failed | Slice |
|---|---|---|---|---|---|
| — | — | — | — | — | — |

**Known future entries**, named here so they are not a surprise and not a precedent for others:

| Expected role | Why it will be tier 2 | Slice |
|---|---|---|
| Waveform bar geometry and resting treatment | The waveform has no system precedent — §14.3 calls it the one element needing original visual design rather than a mapping. **Values are decided** and held in §6.2 until slice 3 converts them | 3 |
| `scrim.fill`, `scrim.text` | §14.7's full-screen scrim is the only full-bleed, non-glass surface in the app. Because Sotto draws the wash itself, the text sits on a known dark background in both appearance modes, so this is one fixed pair rather than a light/dark branch | 13 |
| Overlay intrusiveness values | §14.1: width relative to content, internal padding, stroke weight, shadow lift, vertical position, element density. macOS has no opinion on these because no system surface is shaped like the overlay. **Values are decided** and held in §6.1 | 9 |
| Chat wash ramp | The gradual blur-to-white behind the in-app chat (§6.4). No system material does a variable-radius blur ramped across a span; this is Sotto-drawn. Provisional — see the §6.4 caveat about where this decision lives in the spec | 10 |

Everything else should be tier 1. If a proposed tier 2 row is not on this list, that is a signal to look harder at tier 1 before writing it.

**The accent is never a tier 2 entry.** Every accent value in `designs/Design.pdf` — including the send button's `#0A84FF` — is macOS system blue used as a **stand-in for `NSColor.controlAccentColor`**, not an authored color. The PDF states this outright: the accent only ever fills bars and glyphs, never a surface. Anyone reading a hex out of the mockup and writing it here has made exactly the tier-2 mistake this section exists to prevent.

---

## 3. Type

**No ramp is enumerated.** Roles are named; sizes arrive with consumers (§14.4).

| Role | Derivation | Used for | Slice |
|---|---|---|---|
| `title` | — | — | — |
| `body` | — | — | — |
| `caption` | — | — | — |
| `transcript` | — | Long-form reading text in the audio workspace | — |
| `code` | — | SF Mono | — |

**Default is `NSFont.preferredFont(forTextStyle:)`.** A fixed point size is allowed per role but needs a stated reason in the row; the burden of proof sits with fixing, not with deriving.

`transcript` is the one role that is not UI chrome. It is tuned for reading, not inherited from `body`.

**Three sizes are fixed by Design.pdf and will need their reason stated when they convert:** the HUD completion string at 13 pt, the compose bar placeholder at 15 pt, and the in-app composer placeholder at 15 pt. The HUD's 13 pt is the one with a real argument behind it — it is **the same font and the same size in every locale**, and the surface grows rather than the type shrinking (§6.2).

---

## 4. Spacing and radii

**One spacing scale, one small radius set, no deviation** (§14.5). Neither is enumerated yet.

**Radius tiers — three, named, values pending:**

| Tier | Applies to | Value | Slice |
|---|---|---|---|
| `radius.control` | Buttons, chips, fields | — | — |
| `radius.card` | Grouped content in the main window | — | — |
| `radius.surface` | Floating surfaces — overlay, HUD, scrim | — | — |

**Rules that hold regardless of value:**

- Corners are `.continuous`, never a circular arc (§14.1). `ConcentricRectangle` where a surface should match the display's own corner
- Nested corners are concentric: a chip inside the compose bar takes the bar's radius minus the inset
- Floating surfaces take the larger radii macOS 26 chrome uses
- Where macOS publishes or implies a standard metric, use it rather than picking a number

**Four radii are decided and held in §6**, and they do not agree with each other in a way that suggests a single `radius.surface` value: overlay bar 16 pt, HUD 12 pt, in-app composer 18 pt, menu bar glyph 3.6 pt. Read as ratios they are closer — 0.308, 0.333, and 0.222 of their own heights respectively. **Whether `radius.surface` is one number or a ratio of surface height is an open call**, and slice 9 is where it has to be made, because that is the first slice holding two floating surfaces at once. Design.pdf notes that every radius it quotes is a continuous corner curve and that CSS's circular arc makes a 16 pt corner read tighter than it should — so build with the platform shape, not the number.

---

## 5. Motion

**No durations are authored.** §14.6 lists the consumers to expect; the tokens arrive with them.

| Consumer | Spec | Duration | Curve | Reduce Motion fallback | Slice |
|---|---|---|---|---|---|
| HUD appear / fade | §4.5 | — | — | **Not "no feedback"** — the HUD appearing is what confirms the gesture registered | 3 |
| Waveform | §4.5 | 60 Hz sample, live input | Compression `v^0.5` | **Decided:** 8 Hz sample, 125 ms hold, no interpolation, heights snapped to 3.5 / 8 / 13 / 18 / 23 / 28 pt | 3 |
| HUD width change | §4.5 | **220 ms** | **ease-out** | Animates from the centre so the HUD stays optically centred throughout | 3 |
| "Copied to clipboard" morph | §4.5 | — | — | — | 3 |
| HUD morph to error message | §4.5 | — | — | — | 3 |
| "Attach image" affordance | §5.5 | — | — | Must not resemble the clipboard morph in shape, position, or motion | 9 |
| Segmented pill selection | §10.2 | — | — | — | 6 |
| Screenshot border glow | §5.6 | — | — | — | 13 |
| Scrim appear / dismiss | §14.7 | — | — | — | 13 |
| Model download progress | §7.4 | — | — | Determinate progress must stay legible without animation | 8 |

**Every motion token needs a Reduce Motion fallback, and the HUD's is load-bearing rather than cosmetic.** Match macOS's standard duration or curve for the equivalent transition rather than inventing one.

**The waveform's Reduce Motion answer is the one that was hard, and it is now settled.** A frozen waveform cannot confirm audio is arriving, which is the whole job; turning it off leaves no feedback at all, which is worse. The answer is neither — it is the same waveform sampled coarsely: 8 Hz, held 125 ms, no interpolation, snapped to six discrete heights. Liveness survives because the bars still change; the continuous animation does not.

**Design.pdf warns that its own motion is fake.** Each bar in the mockup runs an independent CSS keyframe, so the waveform there is decorative rather than driven. In the build the twelve heights come from live input at 60 Hz with the compression curve above, and the resting state is real noise floor. Timing and easing come out of that, not out of the mockup's loops.

---

## 6. Decided upstream, not yet tokens

**These are settled measurements from `designs/Design.pdf` — four decisions, locked 2026-08-11 — held here until their slice converts them into rows above.** They are in this file so they are not lost and not re-argued, and out of §1–§5 so the sheet's emptiness stays honest.

Every value is given as the PDF gives it: **points and a ratio**. If the absolute numbers turn out to be off, the ratios survive and the design rescales instead of being redone.

**Assumed platform metrics, and they are assumptions:** 1512 × 982 pt screen, 24 pt menu bar, 18 × 18 pt template canvas, 84 pt Dock. Every ratio expressed against screen dimensions inherits those assumptions.

### 6.1 Overlay bar — decision 01

Variant 1b, utility weight, three-quarter Spotlight, bottom-anchored. Converts in **slice 9**.

| Measurement | Points | Ratio |
|---|---|---|
| Bar size | 600 × 52 | 0.397 screen width × 0.053 screen height |
| Radius | 16 | 0.308 bar height |
| Horizontal padding | 14 | 0.269 H |
| Controls | 26 | 0.500 H |
| Gap | 12 | 0.231 H |
| Placeholder type | 15 | 0.288 H |
| Stroke | 0.5 @ 9 % light / 12 % dark | 0.010 H |
| Shadow | 0 10 28 @ 20 % light / 42 % dark | — |
| Bottom edge above screen bottom | 118 | 0.120 screen height = 2.27 bar heights |
| Dock occupies | 84 | 0.086 screen height |
| **Clearance, bar to Dock** | **34** | **0.035 screen height = 0.654 bar height** |

**The stroke ceiling is a hard limit, and it is not the stroke value.** A full-perimeter stroke crossing roughly **1 pt at 15 % opacity** is the point where the bar stops reading as a system affordance and starts reading as an app window. The shipping value is 0.5 pt at 9 % / 12 % — well under. Stay under it.

**The anchor moved, and only the anchor.** From top edge at 26 % of screen height to bottom edge at 12 %. Nothing else about the bar changed. The bar now sits at the bottom and the HUD stays at the top, so the two surfaces never occupy the same region and the composed state is resolved.

**Reading the anchor as a rule.** 118 pt decomposes exactly into the 84 pt Dock plus 34 pt of clearance, and the PDF quotes the clearance separately with its own ratio — which is the shape of an invariant, not of a coincidence. **The likely correct token is "clears the Dock's current height by 34 pt (0.654 bar heights)," not the constant 118.** Two cases the decomposition does not cover and slice 9 must decide: a Dock positioned left or right, where there is no bottom occlusion at all, and an auto-hidden Dock, where the occlusion is zero until it is not. Neither is answered here.

### 6.2 Waveform and HUD — decision 02

Variant 5c, twelve bars, symmetric, compressed. Converts in **slice 3**.

**Waveform:**

| Measurement | Points | Ratio |
|---|---|---|
| Bar count | 12 | — |
| Bar width | 3.5, r 1.75, fully round caps | — |
| Gap | 4.5 | — |
| Total width | 91.5 | 0.60 of HUD width, centred |
| Peak height | 28 | 0.78 HUD height |
| Resting height | 3.5–6.7, uneven and drifting, **never looping** | — |
| Amplitude mapping | Compressed, `v^0.5` | — |
| Symmetry | About the centre line, not grown from a baseline | — |

**HUD surface:**

| Measurement | Points | Ratio |
|---|---|---|
| Height | 36, fixed | — |
| Radius | 12 | 0.333 H |
| Stroke | 0.5 @ 9 % black | 0.014 H |
| Shadow | 0 6 18 @ 16 % | — |
| Anchor | Top edge at 8 % of screen height, centred | — |
| Width padding | 16 each side | 0.444 H each, 0.889 H total |
| Width floor | 152 | 4.22 H |
| Width cap | 320 | 8.89 H = 0.212 screen width |

Light-mode glass values as drawn — **a starting tint, not a recipe** (see §6.5): fill 62 % white, blur 34 pt, saturate 180 %, inner top highlight 0.5 pt @ 85 % white.

**Width follows the string, and the string never shrinks.** The completion string no longer sets the width. Width is whichever is wider: the string plus its padding, or the 152 pt floor the waveform needs. **Same font, same 13 pt size in every locale — the HUD grows instead.** Measured:

| Locale | String | HUD width | vs. floor |
|---|---|---|---|
| en | 119 pt | 151 → floored to 152 | 1.00 × |
| de | 181 pt | 213 | 1.40 × |
| fr | 177 pt | 209 | 1.38 × |
| es | 166 pt | 198 | 1.30 × |
| nl | 160 pt | 192 | 1.26 × |
| ja | 192 pt | 224 | 1.47 × |

Single line is an invariant. Nothing reaches the 320 pt cap; a locale that would exceed it is a string-length bug to fix in translation, not a wrapping mode to build. A two-line glass pill for a confirmation on screen for about a second is a lot of layout for a flash, and a wrap path that fires almost never is a path that will be broken the first time it does.

**Nothing in the HUD has a background, border, hover state, or padding that could read as a hit target.** This is §4.5's no-controls rule expressed as a drawing constraint: a latched session ends with the gesture or with Escape, and the HUD must not imply otherwise.

### 6.3 Icons — decision 03

Variant 5h, one capsule, outline to fill. Converts in **slice 1**.

| Measurement | Points | Ratio |
|---|---|---|
| Canvas | 18 × 18 | 1.000 |
| Glyph | 15.6 × 7.2, r 3.6 | 0.867 × 0.400, r 0.200 |
| Aspect | 2.17 : 1 | — |
| Idle stroke | 1.5 — **floor, do not go thinner** | 0.083 |
| Interior | 4.2 | 0.233 |
| Active fill | Solid, ink 112 pt² of 324 pt² | 0.347 |

Pure black-on-transparent template image, both states. Template means the system handles menu bar tint, Reduce Transparency, and high contrast for free.

**One capsule, not two — the question raised in `claude-design-followup-2.md` is closed.** The app icon is two capsules forming an S; the menu bar icon is not a shrunken version of it. The single capsule keeps a story of its own: outline-to-fill reads as the bar going live, which is a better idea at 18 pt than a wordmark nobody can resolve.

**The two states are idle and not idle, not idle and recording** (§14.8). The drawing is unchanged by that redefinition; what it reports is not.

### 6.4 In-app chat — decision 04

No panel edge, gradual blur to white, glass composer only. Converts in **slice 10**.

| Element | Measurement |
|---|---|
| Wash | 560 pt wide, full height, no border, no shadow |
| Wash construction | Six blur passes at 1 / 2 / 4 / 8 / 16 / 30 pt, each masked in over its own 20–28 % band so blur accumulates instead of stepping; white ramp 0 % → 100 % across the same span, opaque at 90 % |
| Composer | 390 × 81 pt, radius 18 pt |
| Composer line 1 | Placeholder 15 pt |
| Composer line 2 | Controls 26 pt — plus glyph 19 pt at 42 % ink with no container, send 26 pt circle at the system accent |
| Chat picker | **None** |
| Glass | Fill 55 % white, blur 34 pt, saturate 180 %, stroke 0.5 pt @ 9 % black, inner top highlight 0.5 pt @ 85 % white, shadow 0 10 28 @ 10 % |

**Why there is no chat picker here.** Inside the app the note is the subject, so the target is not in question. The composer keeps the overlay bar's two controls in the same corners at the same 26 pt, which is what makes the two surfaces read as one product.

**The wash is six passes only because a browser cannot do better.** Natively this is **one variable-radius blur**, and any faint banding visible in the mockup will not exist. Do not port the six-pass construction into Swift.

> **This decision has no home in the spec yet.** §5.8 describes a bounded floating panel — 600 pt bar, growth to 180 pt, cap at the lesser of 720 pt and 70 % of usable height. Decision 04 describes an edge-anchored full-height wash with no panel edge and no picker. They may be the same surface in two states, or two surfaces; the spec does not say, because the spec predates this decision. **Slice 9 or 10 has to reconcile them, and the reconciliation belongs in §5, not in this file.**

### 6.5 App icon

Two capsules forming an S, lower occluding upper, layered for Icon Composer so the system renders Default / Dark / Clear / Tinted. Locked, handled outside Claude Design. The layer breakdown is still undecided; it is an asset decision, not a token, and does not gate this sheet.

### 6.6 What the mockups approximate

Design.pdf closes by naming what its own renderings get wrong. These are the same four failures as §14.9, stated with specifics, plus one:

- **Corners.** Every radius quoted is a continuous corner curve — the same construction the system uses for windows and app icons. CSS `border-radius` is a circular arc, which bulges at the tangent and makes a 16 pt corner read tighter than it should. **Build with the platform shape, not the radius value.**
- **Material.** The bar and the HUD are one system material: it refracts and displaces what is behind it at the edges, brightens specularly along the top, and adapts its tint to the wallpaper underneath. The mockup is a flat white fill over a backdrop blur, which has none of that. **Read every percentage above as a starting tint, not a recipe.**
- **Motion.** Decorative CSS keyframes, not driven by input. See §5.
- **Backdrop.** The chat wash is six discrete passes in the mockup and one variable-radius blur natively. See §6.4.
- **Content.** Body copy is grey bars, the accent is macOS system blue **as a stand-in for `NSColor.controlAccentColor`**, and window chrome is drawn rather than real. Type, spacing, and control sizes are specified; the words, colours, and screenshots are not decisions.

---

## 7. Open against this sheet

Four things this file cannot close on its own.

**The send button's volume.** §14.3 rejects "a saturated send button — the loudest thing in Gemini's bar and the first thing that makes it feel intrusive," and §5.8 restores the button but explicitly "not its volume." Decisions 01 and 04 both draw it as a **filled 26 pt accent circle**, which is the most saturated element in either surface. Either the drawn treatment is what §14.3 was warning against, or §14.3's objection was to something else — size, or position, or an accent-on-accent surface. **Slice 9 decides, and whichever way it goes, one of the two documents needs amending.**

**`radius.surface` as a number or a ratio.** See §4. Slice 9.

**The two anchors.** The overlay's 118 pt decomposes into a Dock-clearance rule (§6.1) and probably should. The HUD's 8 % of screen height does not decompose — it was derived against an assumed 982 pt screen and a 24 pt menu bar, and a notched MacBook Pro menu bar is taller than 24 pt. **Neither is a constant.** Decide per anchor whether it becomes a fixed value or a rule, and record which.

**Where decision 04 lives.** See §6.4. Not a token question.

---

## 8. Change log

| Date | Change |
|---|---|
| 2026-08-13 | Created. Template only — §1 and §2 intentionally empty per §14's lazy rule |
| 2026-08-13 | Slice numbers corrected against the rewritten sixteen-slice `sotto-build-order.md`: overlay 7 → 9, scrim 11 → 13, model download 6 → 8, segmented pill 1 → 6, screenshot glow 11 → 13. The old numbers were the fourteen-slice map |
| 2026-08-13 | §6 rebuilt from `designs/Design.pdf` (locked 2026-08-11). All four decisions recorded in full with points and ratios. Adds the waveform specification — twelve bars, symmetric, `v^0.5` compression, the 8 Hz quantised Reduce Motion fallback — which until now existed only as a subordinate clause in `claude-design-followup-2.md` and was in no canonical file |
| 2026-08-13 | Menu bar icon closed at one capsule, not two (§6.3) |
| 2026-08-13 | Decision 04, in-app chat, recorded for the first time — with the caveat that it has no home in §5 yet |
| 2026-08-13 | §7 added: four open items this sheet surfaces but cannot close, including the send button's volume against §14.3 |
