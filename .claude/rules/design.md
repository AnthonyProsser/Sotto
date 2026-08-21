# Design — open before changing anything drawn

Open before writing/reviewing view code, converting a mockup to Swift, or adding a numeric or hex literal to a view. `CLAUDE.md` §0.1 routes here; do not duplicate this guidance elsewhere.

This file combines general macOS practice and Sotto-specific rules. Keep one file: if it becomes too long, cut duplication rather than splitting it. Its purpose is to prevent a compiling Swift UI that reads as a web app on a Mac.

**Fast path:** §1 → §3 → §9. If you read only one section, read §3.

| Need | Section |
|---|---|
| Core rule | §1 |
| Preflight | §2 |
| Common failures | §3 |
| Geometry and material | §4–6 |
| Windows and sidebars | §7 |
| Screenshot loop | §8 |
| Tokens | §9 |
| Errors, design files, cuts, open questions | §10–13 |
| Completion review | §14 |

## 1. System first

**Use what macOS decides; author only what it leaves open.** A literal claims there is no system answer. That is usually false and will age badly.

| Order | Use | Examples |
|---|---|---|
| 1 | System API | semantic color, material, text style, metric, standard control |
| 2 | Derived system value | `outerRadius - inset`, text-style size × multiplier |
| 3 | Authored value | Only when 1–2 fail; name the closest rejected system API and why |

**"Nothing fits" is not evidence — if you cannot name the rejected API, search first.** That burden is on material, colour, type, corner geometry, controls, and any measurement the spec, `sotto-tokens.md` §6, or a `DECISIONS.md` row has already fixed. Those are where a literal means a system API was missed, and where being wrong is expensive.

**It is not on an ordinary layout dimension** — a column width, a pane inset, a row height, spacing between two things macOS has no opinion about. There is no system metric for those and the search returns nothing; pick the value, write it as a local constant in the view that draws it, and move on (§9, `CLAUDE.md` §0.7). If one is load-bearing and you cannot choose it, ship your best guess and say so in one line — a pane nobody can read is worse than a width Anthony changes in one edit.

## 2. View preflight

1. **Does macOS already draw it?** Use `NSMenu`, `NSAlert`, panels, toolbars, sheets, popovers, settings chrome, focus rings, Dynamic Type, and disabled states.
2. **What is the system reference?** Name one (for example, Spotlight for a floating input or Control Center for transient status). It sets material, radius, density, and whitespace.
3. **What is the smallest workable surface?** Whitespace is a feature. Pick one treatment; a border + shadow + gradient + tint is Bootstrap, not macOS.

## 3. Failure modes and corrections

| Failure | Tell | Correction |
|---|---|---|
| Value instead of API | numeric/hex literal in a view | Name and use the system API, or document why it fails |
| Fake glass | `NSVisualEffectView`, material, or blur used as glass | `.glassEffect()` / `NSGlassEffectView` (§4, §6) |
| Circular corners | `.cornerRadius` or `RoundedRectangle` without `style:` | Continuous corners (§4.1) |
| Arbitrary nested radii | inner and outer radii chosen separately | `outer - inset` or `ConcentricRectangle` |
| Decoration stack | material + stroke + shadow + gradient + tint | Remove treatments until one earns its place |
| Web layout | hero/grid/gradient header/emoji icon | left-aligned, content-first, SF Symbols |
| Redrawing system UI | custom menu, picker, disabled state, toolbar, settings chrome | standard controls; put the reason in a tooltip |
| Ignoring settings | authored colors/material/motion | semantic APIs handle Dark Mode, accent, contrast, transparency; preserve information in Reduce Motion (waveform: 8 Hz, not off) |
| English-sized frame | fixed width/height for one string | size to content; constrain ratios; document any fixed size and tested condition |
| Calling structure appearance | frame dump reported as visual confirmation | screenshot for appearance; report structural and visual verification separately |

The identifier version of the first failure is especially costly: a name that fails to compile proves only that *name* is wrong. Check SDK headers before minting a replacement. `.sidebarTrackingSeparator` exists; `.trackingSeparator` does not (§7).

## 4. Geometry and material

### 4.1 Continuous, concentric corners

Circular corners are forbidden. They visibly read as non-native.

```swift
// SwiftUI
.clipShape(.rect(cornerRadius: 16, style: .continuous))
RoundedRectangle(cornerRadius: 16, style: .continuous)
ConcentricRectangle()

// AppKit
layer.cornerCurve = .continuous
layer.cornerRadius = 16
```

Do not use `.cornerRadius(_)` or `RoundedRectangle(cornerRadius:)` without `style:`.

**`style: .continuous` only does something while the radius is under half the smaller dimension.** At `r = h/2` the continuous corner and the circular arc are the same curve — measured 2026-08-18, identical edge profiles — because no straight edge remains for the superellipse to blend into. A capsule written as `.rect(cornerRadius: h/2, style: .continuous)` passes §14's grep and still ships a circular arc. If a surface should read as a squircle, its radius has to be strictly less than half its height. For nested surfaces use `outerRadius - inset`; use `ConcentricRectangle` when matching an enclosing/display corner.

### 4.2 Real glass, not blur

Liquid Glass supplies adaptive backdrop tint, specular edge, rim refraction, and the user's Clear/Tinted choice. A blur plus fill supplies none. Use:

```swift
content.glassEffect(in: .rect(cornerRadius: 16, style: .continuous))
```

Never substitute `.ultraThinMaterial`, `NSVisualEffectView` plus overlays, or `.blur(radius:)`. Sotto uses floating-panel glass for the overlay and Control Center–style glass for the HUD. A surface normally gets one treatment; more than two of material/stroke/shadow/gradient/tint is a finding.

### 4.3 Disabled states

Only two patterns exist:

- Controls use the system disabled state and a tooltip explaining why.
- A blocked screenshot gesture uses the full-screen scrim. Reuse it for any future gesture gate.

## 5. Color, type, spacing

- Use semantic colors: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `separatorColor`, `controlBackgroundColor`, `controlAccentColor`.
- Accent is `controlAccentColor`, never a mockup hex (`#0A84FF` is merely system-blue stand-in).
- Derive type from `.body` or `NSFont.preferredFont(forTextStyle:)`. A fixed size needs an inline reason.
- Use a system metric where available; otherwise use one named spacing scale. Do not add a second scale for one surface.

## 6. Liquid Glass: verified API surface

Re-verified 2026-08-19 against the **installed SDK's** `SwiftUICore.swiftinterface`, not documentation — the declarations below are the ones the compiler sees. Note that the glass API lives in **SwiftUICore**, not SwiftUI, so grepping `SwiftUI.swiftinterface` for `glassEffect` returns nothing and does *not* mean the API is absent. These do **not** exist: `glassBackgroundEffect`, `NSGlassView`, `.glassMaterial`, `.liquidGlass()`, `NSLiquidGlassView`, `GlassContainer`.

`Glass` has exactly five members — `.regular`, `.clear`, `.identity`, `.tint(Color?)`, `.interactive(Bool = true)`. There is no `.prominent`, and no `.thick`/`.thin` scale.

### 6.1 Applying glass

There is one overload, and both parameters default:

```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
```

`DefaultGlassEffectShape` is a concrete `Shape`, **not** `Capsule` — pass the shape explicitly whenever the corner matters.

```swift
.glassEffect(in: .rect(cornerRadius: 16, style: .continuous))
.glassEffect(.regular.tint(.orange).interactive())
```

Pass the shape to `in:` rather than clipping afterwards. A later `.clipShape` cuts the specular edge and the rim refraction the glass drew outside the path.

Apply glass after modifiers whose appearance it should capture.

### 6.2 Containers

`GlassEffectContainer(spacing: CGFloat? = nil, content:)`. Multiple glass views require one; it optimizes rendering and enables blending/morphing, and `spacing` controls morph distance. It is also what makes a *single* surface's size change read as the shape flowing rather than a redraw.

`GlassEffectTransition` has exactly `.matchedGeometry`, `.materialize`, `.identity`.

### 6.3 Morphing and unions

`glassEffectID(_:in:)` and `glassEffectTransition(_:)` affect only animated/hierarchy transitions; they do nothing at rest. Use `glassEffectUnion(id:namespace:)` when dynamic or separated views should read as one glass shape.

### 6.4 Button styles

Three exist and no more: `.glass`, `.glass(_ glass: Glass)`, `.glassProminent`. **`prominentGlass()`, `clearGlass()`, and `prominentClearGlass()` do not exist** — they were listed here until 2026-08-19 and no such symbols are in the SDK. For a clear or tinted button use `.buttonStyle(.glass(.clear))` / `.glass(.regular.tint(…))`.

### 6.5 Shapes and background extension

`ConcentricRectangle`, `.rect(corners:isUniform:)`, and `cornerConfiguration` cover shape configuration. Apply `backgroundExtensionEffect()` to the image, then add overlays, so only the image extends under a sidebar/inspector.

### 6.6 AppKit

AppKit's surface is narrower than SwiftUI's, which is why issue 2 was closed the way it was (2026-08-15): **every view is SwiftUI, so glass is always the SwiftUI API above and this table applies only to the `NSWindow`/`NSPanel` hosts.** Each §14.2 role therefore has one `Color` form and no `NSColor` twin.

| API | Use |
|---|---|
| `NSGlassEffectView` | glass view: `contentView`, `cornerRadius`, `style`, `tintColor` |
| `NSGlassEffectContainerView` | container for multiple glass views |
| `NSBackgroundExtensionView` | AppKit equivalent of background extension |
| `NSButton.BezelStyle.glass` | standard glass button |

Set both `cornerRadius` and `cornerCurve = .continuous`.

### 6.7 What real glass provides

Adaptive backdrop tint, specular edge, and rim refraction — none come from blur plus a fill.

**Glass flips its own appearance, and its content's, from the luminance of what is behind it — not from the system's light/dark setting.** Measured 2026-08-19: one `HUDView` with no `colorScheme` override, in a window whose `effectiveAppearance` was `NSAppearanceNameDarkAqua`, rendered light glass with black text over a light backdrop and dark glass with white text over a dark one, in the same frame. Three consequences:

- **A glass surface has no light variant and no dark variant to choose between.** Rendering "the light version" and "the dark version" of one for review is drawing the same view twice against different backdrops.
- `.primary` and the other semantic label colors resolve against the *glass*, not the window, so they stay legible with no branch of your own.
- **An explicit `.environment(\.colorScheme, _)` overrides that and pins the content**, while the surface goes on tinting and refracting from the backdrop — verified 2026-08-19 against a backdrop × override matrix. **Sotto's HUD pins deliberately** (`HUDPanel`, `DECISIONS.md` 2026-08-19): left adaptive, the labels invert mid-dictation when the user scrolls something dark under a HUD that is already on screen. Pin at appearance, never re-pin during one showing. Anywhere else, do not add the branch.
- It is why the Appearance tab stays cut (§12). There is no per-appearance asset for a settings control to pick.

**Clear and Tinted are not system appearances.** There is no `NSAppearanceName` for either; `Glass` has `.regular`/`.clear` and `NSGlassEffectView` has the matching two-case `style`, both app-set, and `tint` is a `Color` the app supplies. The Default/Dark/Clear/Tinted quartet is the **icon and widget** appearance set, which the system generates from the Icon Composer document (§6.9) and which does not extend to in-app surfaces. A global `NSGlassDiffusionSetting` default does exist; a per-process override of it produced zero pixel change, which does not prove it is inert — the argument domain may simply not be where it is read. Do not build on it either way.

### 6.8 Windows and controls

macOS 26 has rounder window chrome, larger controls, standard split-view resizing, and interactive glass controls. Use those controls rather than recreating their behavior.

### 6.9 App icons

Build app icons in Icon Composer from simple overlapping semi-transparent layers. Do not bake masks, blur, shadows, or highlights; the system applies them and generates Default/Dark/Clear/Tinted. Keep the silhouette readable without color and centered within the rounded-rectangle mask. Sotto's icon is **done and in the repo** at `Sotto/Sotto.icon` — two capsules forming an S, lower occluding upper, one layer each (`1-grey-top`, `2-grey-bottom`), shadow and translucency declared as group properties. Do not add an `.appiconset` beside it; the Icon Composer document is what generates the four appearances.

## 7. Window chrome

The facts in this section were checked against installed AppKit headers. For uncovered names, search the SDK first:

```bash
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers
grep -rn "TrackingSeparator" "$SDK"/*.h
```

### 7.1 Full-height sidebar

Safari/Finder/Mail/Notes use a sidebar behind the traffic lights with toolbar content to the divider's right. It is standard system behavior:

```swift
NSToolbarItem.Identifier.sidebarTrackingSeparator
NSToolbarItem.Identifier.inspectorTrackingSeparator
```

For the sidebar case, put the system `.sidebarTrackingSeparator` in the toolbar. Do not mint an identifier or configure the divider yourself. It requires `.fullSizeContentView`; without it, it silently does nothing. Use `NSTrackingSeparatorToolbarItem(identifier:splitView:dividerIndex:)` only for genuine non-sidebar/second separators; the split view must share the window by toolbar display time and be vertical.

### 7.2 Sidebar toggle

`toggleSidebar(_:)` works only when the first split item has `.sidebar` behavior:

```swift
let sidebarItem = NSSplitViewItem(sidebarWithViewController: vc)
```

A plain `NSSplitViewItem` produces a valid-looking, inert button. The standard toggle's validation is free; override only for a non-first sidebar and explain why.

### 7.3 Traffic lights and toolbar band

- `.fullSizeContentView` extends content under the titlebar.
- `titlebarAppearsTransparent` plus hidden title removes the visible band.
- A single toolbar item redraws the band. Removing the toolbar may be necessary; SwiftUI may need `.toolbar(removing: .sidebarToggle)`.
- Derive, never hardcode: `NSWindow.frameRect(forContentRect:styleMask:)` for titlebar geometry and `standardWindowButton(_:)?.frame` for control positions.

### 7.4 Chrome checklist

Full-size content where needed; `sidebarWithViewController`; system tracking separator; derived geometry; click-test the toggle; screenshot open and collapsed sidebar.

## 8. Screenshot loop

**Never claim appearance without having read a screenshot.** Dumps, insets, and `window.toolbar == nil` verify structure, not appearance.

### 8.1 Environment facts

Confirmed 2026-08-15: Screen Recording and Accessibility are granted; a 300 × 140 pt capture distinguishes continuous from circular corners; `xcode-select` points to CommandLineTools, so every build needs `DEVELOPER_DIR`; DerivedData is per-worktree and must be derived; the current app launches with no visible window, which is expected before slice 1.

### 8.2 The loop

```bash
# Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Sotto -configuration Debug -destination 'platform=macOS' build

# Find product; never hardcode DerivedData
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Sotto -showBuildSettings | grep BUILT_PRODUCTS_DIR

# Get and capture the app window only
osascript -e 'tell application "System Events" to tell process "Sotto" \
  to get {position, size} of window 1'
screencapture -x -o -R"x,y,w,h" /tmp/shot.png
```

Capture the window rect only: full-screen capture can expose unrelated desktop content. `screencapture` captures the active Space; activate Sotto first. System Events identifies by process name, so run `pgrep -lf` and stop stale builds before trusting it. A missing window is an expected case here, not a failed capture.

### 8.3 Judgment and visual changes

Taste still goes to Anthony: verify the facts, then name uncertainties such as radius at real size or glass against his wallpaper. HTML/PDF mockups can judge proportion, spacing, and order—not continuous corners, real material, adaptive tint, specular edge, or motion. Screenshot before/after any view-code restructure; explicitly report unintended visual change (`CLAUDE.md` §0.4).

## 9. Tokens

`docs/sotto-tokens.md` is a read-only template. Its §§1–2 are intentionally empty; a token appears only with its first consumer. Do not generate a full type/spacing/radius system or a `DesignTokens.swift` up front.

Each row makes four claims:

1. Semantic role, not a description (`surface.raised`, not `gray12`).
2. First consumer and slice.
3. For tier 2, closest rejected system value and why it fails.
4. Slice added.

| Tier | Resolves to |
|---|---|
| 1. Inherited | system semantic color, material, font, or metric |
| 2. Authored | Sotto value required because no system value fits |

There is no tier 3 or `state.*` namespace. Tier 2 is permanent debt and should approach zero. Pre-approved: waveform idle treatment (slice 3); `scrim.fill`/`scrim.text` (slice 13); overlay intrusiveness values — width ratio, padding, stroke, shadow, position, density (slice 9).

**A value earns a row when it is part of the design language** — shared by more than one consumer, locked by the spec or a `DECISIONS.md` row, or materially load-bearing for consistency later. **A trivial one-consumer number that is one edit to change stays a local constant**, including when it is authored and including when it is visible; a row buys indirection and a maintenance claim, not consistency. Tokenising a pane inset because it ships is the failure this paragraph exists to stop.

**A fourth tier-2 row that is part of the design language goes to Anthony with its four claims and a `DECISIONS.md` entry. A trivial constant does not go to him at all, because it is not a row.**

Components name roles wherever a row exists: `surface.raised` → `.controlBackgroundColor`. **Where no row is earned, write the system value directly** — a tier-1 row aliasing `.body` for a single consumer is indirection over an alias (`CLAUDE.md` §0.3). No theme struct, Appearance setting, or system-appearance override. §6 of the token sheet holds locked-but-unbuilt `Design.pdf` measures; look there before inventing a number. The token layer is `CLAUDE.md` §0.3's explicit exception **for authored values**, because it keeps the inherited/authored boundary auditable.

## 10. Error location

No global error token, central error vocabulary, notification, or modal. Errors stay on the surface that owns the failed work.

| Failure | Surface |
|---|---|
| Transcription, audio model load, cleanup failing **mid-pass**, AX write | HUD (§4.5) |
| Cleanup or chat model **unavailable** — `SystemLanguageModel.availability != .available` | Settings, the pane that owns it: Dictation for cleanup, Chat for chat. Model picker with a banner naming the reason |
| Chat model load, generation, tool call | Chat: overlay or main window |
| File transcription | Main window, Audio pane |
| Model download | Originating model list (§7.4) |

**Unavailable is not a failure, and that is why it moved** (2026-08-19, `DECISIONS.md`). A model that fails mid-pass is a runtime event inside work the user just started, so it belongs on the surface that started it. Apple's on-device model cannot fail to load — it is enabled on the machine or it is not, the state is knowable before the gesture fires, and the remedy is in System Settings. A HUD morph repeating "cleanup unavailable" on every single dictation is a notification in all but name, which `CLAUDE.md` §2 rules out. **Slice 3 therefore designs the error morph with no model-unavailable string in it.**

Feature-owned slices design the surface and wording; slice 6 owns the file-transcription slot despite failure production arriving in slice 14.

## 11. Design files

`docs/` is read-only under `CLAUDE.md` §0. `Design.pdf` and `sotto-chat-response-concept.svg` are not interchangeable.

| File | Use for | Never use for |
|---|---|---|
| `Design.pdf` | real-size composition and proportion | measurements; use token-sheet §6 |
| Chat SVG | chat-turn anatomy | measurements or decision 04 shape |

### 11.1 `Design.pdf`

**No longer locked as of 2026-08-18** — Anthony unlocked every §6 value; see `DECISIONS.md`. Drawn 2026-08-11, transcribed to token-sheet §6 on 2026-08-13, and now a starting point rather than a constraint. §1's resolution order and the tier-2 burden still apply, and every change still gets logged. Decisions: overlay bar (slice 9, §6.1), waveform/HUD (slice 3, §6.2), icons (slice 1, §6.3), in-app chat (slice 10, §6.4), and mockup limitations (all slices, §6.6). Page 5 is the standing warning: percentages are starting tints, not recipes; mockups approximate corners, material, motion, backdrop, and content. Its screen ratios assume 1512 × 982, 24 pt menu bar, and 84 pt Dock—gap 2 is whether anchors are values or rules.

### 11.2 Chat SVG

It is an undated, unlocked sketch, not to scale: its 378 × 70/radius 22 composer conflicts with decision 04's 390 × 81/radius 18. Read it once before slices 9/10 for the only drawn turn anatomy: small speaker labels; user selection as a left-accent-rule, faint-fill quote above the instruction; no assistant bubble; reply set directly on the surface with semibold answer and lighter reasoning. It informs, but cannot settle, gaps 1 or 3; put those to Anthony.

## 12. Do not resurrect

| Cut | Rule |
|---|---|
| `state.recording` / `state.latched` | Hand state communicates mode; waveform confirms capture |
| `state.error` / `state.network` | Deleted with tier 3; errors route per §10 |
| Theme struct / Appearance tab | Inherit System Settings wholesale |
| MCP network badge | Opt-in/off-by-default is sufficient; marker is decoration |
| Compose-bar model selector | Menu bar owns model choice |
| HUD waveform toggle | Waveform is mandatory |

## 13. Open questions

**Four are open on the design side — gaps 1, 2, 3 and issue 5. Read `.claude/rules/open-questions.md` before slices 9, 10, or 13, and ask rather than settle.** Issue 2 is closed: all SwiftUI, one `Color` per role (§6.6).

**That duty is to those four by name, and does not generalise.** An undecided number that is not one of them is not an open question — it is `CLAUDE.md` §0.7's small local choice, and §1 and §9 say what to do with it.

## 14. Before declaring design work done

**Run the grep. Then scale the rest to the surface.** What follows is written for a small floating surface where every pixel is product-defining; run it whole against an ordinary window and it costs rounds re-proving what the system already guarantees.

| Surface | Run |
|---|---|
| A floating surface, or any locked measurement | §14.1–14.6 in full |
| A window, pane, or list built from standard controls | §14.1, §14.2, §14.5, plus **one** screenshot each of the default state and the empty or error state |
| A view-code edit that changes nothing drawn | The grep and §14.5 |

**§14.3's bright-and-dark desktops and §14.4's German and largest-text checks are for surfaces that float over arbitrary content or size to a single string.** A standard window inherits both. **One screenshot per state, read once** — re-capturing a state to re-confirm an appearance you already read is not verification, it is the loop `CLAUDE.md` §0.6 tells you to close.

Run this grep first:

```bash
rg -n '\\.cornerRadius\\(|Color\\(red:|Color\\(hex:|NSColor\\(red:|#[0-9A-Fa-f]{6}|\\.ultraThinMaterial|\\.thinMaterial|\\.regularMaterial|NSVisualEffectView|\\.blur\\(radius:|\\.font\\(\\.system\\(size:|UIScreen|GeometryReader' --glob '*.swift'
```

Every hit is a violation or carries a one-line comment naming the rejected system API and why. Typical replacements: continuous corners; semantic colors; Glass; text styles; `containerRelativeFrame`/alignment guides instead of `GeometryReader`.

### 14.1 System deference

- [ ] Standard interactions use standard controls; no theme/appearance layer.
- [ ] Every remaining grep hit names the rejected system API and why.

**Judgment:** does macOS already draw any of this better?

### 14.2 Geometry

- [ ] All corners are continuous; nested corners are concentric.
- [ ] Floating surfaces use macOS 26 radii; multiple glass views use a container.

**Judgment:** inspect the radius at actual size, not an enlarged mockup.

### 14.3 Material and restraint

- [ ] Real glass, applied after captured appearance modifiers; standard glass buttons.
- [ ] More than two surface treatments is justified or removed.

**Judgment:** check bright and dark desktops; this cannot be verified from code.

### 14.4 Adaptation

- [ ] Semantic colors, system accent, text styles, and localized/content-sized frames.
- [ ] Motion has an informative Reduce Motion fallback.

**Judgment:** check German and the largest accessibility text size.

### 14.5 Honesty of the report

- [ ] Read screenshots of the correct process; capture only window rect; click interactive controls.
- [ ] Separate structural, visual, and unverified claims in the report.
- [ ] Name roles and four-part claims for any authored value.
- [ ] Log and report every spec contradiction in `DECISIONS.md`; report unintended visual changes.
- [ ] Build with explicit `DEVELOPER_DIR`.

### 14.6 Handing judgment over

For taste handoff, name the object and doubt—not “please check it”: for example, glass against a bright desktop, concentric chip radius at actual size, German wrapping, or whether a shadow is now redundant.

**Verdict:** ask “what does macOS do?” first and “what does spec §14 say?” second. A generic Swift-design instinct loses to either.
