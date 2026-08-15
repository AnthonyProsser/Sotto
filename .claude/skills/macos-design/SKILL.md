---
name: macos-design
description: Design and build native macOS 26 interfaces in Swift — Liquid Glass, continuous corners, semantic colors, NSPanel floating surfaces, menu bar apps. Use when writing or reviewing any Swift that puts pixels on screen, when a surface "looks off" or "looks like a web app", when converting a mockup or screenshot into Swift, when choosing a material, radius, spacing, font, or color, and before adding any hardcoded numeric or hex value to a view. Covers what Claude reliably gets wrong about Apple design and how to correct it.
---

# Designing in Swift for macOS 26

**The failure this skill exists to prevent:** Swift that compiles, runs, and looks like a web app rendered on a Mac. It is not a syntax problem. It is that the model reaches for a *value* where macOS supplies an *API*, and stacks decoration where Apple picks one thing and stops.

**Read `references/failure-modes.md` before writing a view.** Ten concrete failures with the correction beside each. That file is the skill; this one is the routing.

---

## The one rule everything else follows from

**The system decides everything it already has an opinion about. You author only what macOS leaves open.**

Every hardcoded value in a view is a claim that macOS has no opinion here. That claim is almost always false, and it fails silently and late — the value stops matching the platform at the next OS release, and nothing in the build breaks to tell you.

So the order of preference is strict, and it is not a style preference:

| | | Example |
|---|---|---|
| **1. Use the system's** | A semantic color, real material, text style, published metric, or standard control | `.secondaryLabelColor`, `.glassEffect()`, `NSFont.preferredFont(forTextStyle: .body)` |
| **2. Derive from the system's** | A value computed from a system value, so it tracks | `radius - inset` for a nested corner; `preferredFont(...).pointSize * 1.4` for line height |
| **3. Author it, and say why** | Nothing in 1 or 2 fits. Name the closest system value and what it got wrong | The waveform's idle bar treatment — no system precedent exists |

**"Author it" requires naming the rejected system value.** "Nothing fits" is not a reason; it is the absence of a search. If you cannot name the system API you ruled out, you did not look.

---

## Before you write the view

Three questions, in order. Each one can end the task.

**1. Does macOS already draw this?** `NSMenu`, `NSAlert`, `NSSavePanel`/`NSOpenPanel`, the toolbar, sheets, popovers, disabled control states, the settings window chrome, Dynamic Type, the focus ring. Every hour spent designing one of these produces something worse than the default *and* something that stops matching the OS. Use the standard control.

**2. What is this surface's system reference?** Every macOS surface has one. A floating input panel is Spotlight. A transient status readout is Control Center. A settings window is System Settings. Name the reference before designing, because it decides the material, the radius tier, the density, and the amount of air — four decisions for the price of one, all of them already correct.

**3. What is the smallest thing that could work?** Whitespace is a feature. A surface with one element and a lot of air reads as Apple; the same surface with a border, a shadow, a gradient, and a tint reads as Bootstrap. Apple picks **one** treatment per surface and stops.

---

## Material and geometry — the two things that make it look native

### Corners are `.continuous`, never circular

A circular arc jumps from zero curvature to maximum at a single point. That seam is most of what makes a rounded rectangle read as Material Design rather than Apple, and it is visible at every radius above about 8 pt.

```swift
// SwiftUI
.clipShape(.rect(cornerRadius: 16, style: .continuous))
RoundedRectangle(cornerRadius: 16, style: .continuous)
ConcentricRectangle()          // matches the display's own corner

// AppKit
layer.cornerCurve = .continuous
layer.cornerRadius = 16
```

**Banned:** `.cornerRadius(16)` — deprecated, and circular. `RoundedRectangle(cornerRadius:)` without `style:` — defaults to circular.

**Nested corners are concentric.** A chip inset 8 pt inside a bar of radius 16 takes radius 8, not 16 and not 12. Compute it: `outer - inset`. Two independently-chosen radii on nested surfaces is one of the most legible tells of a non-native UI.

### Real materials, never a hand-rolled blur

Liquid Glass provides three things a blur cannot: **adaptive tint** sampled from the content behind the surface, a **specular highlight** along the lit edge, and **refraction** at the rim. Blur plus a translucent fill is not this material and does not become it with more layers.

```swift
// SwiftUI
.glassEffect()                                  // regular variant, capsule shape
.glassEffect(in: .rect(cornerRadius: 16))
.glassEffect(.regular.tint(.orange).interactive())
GlassEffectContainer(spacing: 40) { ... }       // required when >1 glass view

// AppKit — thinner surface, see references/liquid-glass-api.md
NSGlassEffectView            // contentView, cornerRadius, style, tintColor
NSGlassEffectContainerView
```

**Banned as a substitute:** `NSVisualEffectView` with a custom overlay, `.ultraThinMaterial` + a border + a shadow, any `.blur(radius:)` behind a fill. These were the macOS 14/15 approximation. On macOS 26 they are just worse.

**Full API surface, verified against Apple's docs: `references/liquid-glass-api.md`.** Read it rather than recalling — most of these APIs postdate common training data, and the adjacent-but-wrong name (`glassBackgroundEffect`, `NSGlassView`, `.glassMaterial`) compiles nowhere.

**Windows, sidebars, toolbars, and traffic lights: `references/window-chrome.md`**, verified against the installed SDK headers. Read it before building a full-height sidebar or touching a toolbar — this is the area where wrong code compiles, runs, and silently does nothing, so there is no error message to lead you back.

**When an API name does not compile, check the headers before authoring a replacement.** A missing name is evidence about *that name*, not about the system:

```bash
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers
grep -rn "TrackingSeparator" "$SDK"/*.h
```

This is faster than a web search, it matches the SDK you are actually compiling against, and it is the difference between using `.sidebarTrackingSeparator` and minting your own identifier to replace it.

---

## Color, type, spacing

**Color is semantic, or it is the accent.** `NSColor.labelColor`, `.secondaryLabelColor`, `.tertiaryLabelColor`, `.separatorColor`, `.controlBackgroundColor`, `.controlAccentColor`. These adapt to light/dark, to the user's accent, to Increase Contrast, and to Reduce Transparency for free. A hex literal adapts to nothing.

**`controlAccentColor` is the accent. Never a hex.** A blue read off a mockup is the system accent drawn in a tool that has no access to it. Writing `#0A84FF` into Swift hardcodes one user's preference for everyone.

**Type derives from text styles.** `NSFont.preferredFont(forTextStyle:)` / `.font(.body)`. These track the accessibility text size at runtime. A fixed point size is allowed but needs a stated reason in a comment — the burden of proof sits with fixing, not with deriving.

**Spacing: use the system metric where one exists**, and one scale where none does. Do not invent a second scale for one surface.

---

## Look at what you built — the loop exists, so use it

**Screen Recording and Accessibility are granted on this machine** (verified 2026-08-15 by building, launching, and screenshotting a real window). You can see your own output. This corrects an earlier claim, in this skill and in a prior session, that `screencapture` was unavailable — it was, then it wasn't, and a stale "I can't see it" is now an excuse rather than a limit.

**Never describe a rendered result you have not looked at.** The failure this prevents happened verbatim: a full-height sidebar was reported as "rebuilt and running — the sidebar now goes top to bottom," with exact pixel claims, entirely from view-hierarchy dumps and frame math. Asked directly whether it had looked, the honest answer was *"I have not seen it. I've been verifying structurally, not visually."* Geometry instrumentation is real verification **of geometry**. It says nothing about appearance, and the two must never be reported as one.

The loop:

```bash
# 1. Build — bare xcodebuild fails; xcode-select points at CommandLineTools
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...

# 2. Locate the window
osascript -e 'tell application "System Events" to tell process "Sotto" \
  to get {position, size} of window 1'

# 3. Capture it, then Read the PNG
screencapture -x -o -R"x,y,w,h" /tmp/shot.png
```

`-x` suppresses the shutter sound; `-o` drops the window shadow. Drive the UI the same way — `click menu bar item "File" of menu bar 1` works.

**Two traps that produce confidently wrong screenshots:**

- `screencapture` grabs the **active Space only.** A fullscreen app on another Space is not what you get — activate the target first.
- System Events matches processes **by name.** A stale build of the same app left running from another worktree will silently answer your queries. `pgrep -lf` and kill duplicates before trusting a result.

**What still goes back to Anthony:** taste. You can now confirm the sidebar is full-height; you still cannot decide whether the radius reads too square at real size or whether the glass holds against his wallpaper. Look first, then hand over the judgment calls with the doubt named.

**Judge proportion from a mockup; judge material only in Swift.** Any HTML or PDF mock gets four things wrong every time, so never chase them in the mock: corners render as circular arcs, blur is not refraction, there is no adaptive tint, there is no specular edge. Width, height, radius magnitude, spacing, and element order are real in a mockup. Nothing about the material is.

---

## Before you say it's done

Run `references/design-review.md`. Five dimensions, each with an observable check — not "does it look good," which you cannot assess, but "is there a hex literal in this file," which you can.

---

## Part B — Sotto's own rules

**On this project the rules above are not the whole constraint.** Sotto's `CLAUDE.md` and `docs/sotto-spec.md` §14 add project-specific law that overrides general macOS practice. Read `CLAUDE.md` §2 and §2.1 before authoring any value.

The three that most often get violated by generic Swift design advice:

**1. Tokens are lazy, and components name roles, not values.** A token is authored the *first time a feature needs it*, never before. Do not generate a `DesignTokens.swift` with a full color palette, type ramp, and 8 pt spacing scale — that is the conventional move and it is explicitly rejected in spec §14, because a value written before it has a consumer is a guess indistinguishable from a decision six months later. Components read `surface.raised`; the token layer maps that to `.controlBackgroundColor`. Adding a row is a four-part claim: role, first consumer, system value ruled out and why, slice.

**2. There is no theme layer and no Appearance setting.** v0.13 specified a mode picker, theme picker, tint toggle, and glass-opacity slider; v0.14 deleted all of it. Appearance is inherited wholesale from System Settings. Do not reintroduce it as a "small" preference, and do not write a theme struct — the indirection exists so the inherited-vs-authored boundary stays auditable in one file, not so it can be swapped.

**3. Tier 2 is policed, and exactly three entries are pre-approved:** the waveform idle bar (slice 3), `scrim.fill`/`scrim.text` (slice 13), and overlay intrusiveness values (slice 9). A fourth is a signal to look harder at tier 1 — not a reason to write the row. If you believe one is genuinely needed, make the four-part claim out loud and let Anthony rule, then log it in `DECISIONS.md`.

**Numbers that are already decided live in `docs/sotto-tokens.md` §6**, not in `Design.pdf`. Go there before concluding nothing has been decided — §6 holds every measurement locked in the PDF, with its ratio and its slice, until the owning slice converts it into a row.

**`docs/` is read-only.** Decisions that contradict the spec go in `DECISIONS.md` and get said out loud in the reply. Never amend the spec copy.

**Verdict: on this project, "what does macOS do?" is the first question and "what does §14 say?" is the second. If a general Swift-design instinct disagrees with either, it loses.**
