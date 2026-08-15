# Ten failure modes, with the correction

Each of these is something a language model does reliably when asked to design in Swift. They are not random errors — each one is a *reasonable habit from a different platform* applied where it does not hold. The habit is why the model does it confidently, and the confidence is why it survives review.

---

## 1. Reaching for a value where macOS supplies an API

**The tell:** a numeric or hex literal in a view body.

```swift
// Wrong
Text(label)
    .font(.system(size: 13))
    .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.44))
    .padding(.horizontal, 12)

// Right
Text(label)
    .font(.callout)                    // tracks accessibility text size
    .foregroundStyle(.secondary)       // adapts to light/dark, Increase Contrast
    .padding(.horizontal, Spacing.m)   // one scale, named
```

**Why the habit exists:** on the web there is no semantic layer, so every value is authored. On Apple platforms roughly 80% of the values a designer would author already exist as APIs that adapt to four user settings you will otherwise ignore.

**The test:** for every literal, name the system API you rejected. If you cannot, you did not look.

**It applies to identifiers too, not just to colors and metrics.** A real instance: `.trackingSeparator` did not compile, so the fix applied was to mint one — `NSToolbarItem.Identifier("SottoTrackingSeparator")` — and hand-configure a tracking separator against the split view. The system already ships `.sidebarTrackingSeparator`, which discovers and tracks the sidebar divider on its own. The compiler error was real; the conclusion drawn from it ("there is no system identifier") was not, and nothing about the working code would ever have revealed the mistake. **A name that does not exist is evidence about that name, not about the system.** Check the SDK headers before authoring a replacement — see `window-chrome.md`.

---

## 2. Hand-rolling the material

**The tell:** `.ultraThinMaterial`, `NSVisualEffectView`, or `.blur(radius:)` used to mean "glass" on macOS 26.

```swift
// Wrong — the macOS 14/15 approximation, now strictly worse
ZStack {
    RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
    RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15))
    content
}
.shadow(radius: 20)

// Right
content.glassEffect(in: .rect(cornerRadius: 16))
```

**Why the habit exists:** the approximation was correct for years and dominates training data. It is also *seductive* — it looks close in a screenshot, and the gap only shows in motion and against changing content.

**What you lose by approximating:** adaptive tint sampled from behind the surface, the specular highlight on the lit edge, refraction at the rim, and the user's Clear/Tinted choice from System Settings. None of those can be added back with more layers.

---

## 3. Circular corners

**The tell:** `.cornerRadius(16)` or `RoundedRectangle(cornerRadius: 16)` with no `style:`.

```swift
// Wrong — deprecated, and circular
.cornerRadius(16)
RoundedRectangle(cornerRadius: 16)

// Right
.clipShape(.rect(cornerRadius: 16, style: .continuous))
RoundedRectangle(cornerRadius: 16, style: .continuous)
```

A circular arc goes from zero curvature to maximum at one point. The eye reads that discontinuity as a seam even when it cannot name it, and it is the single highest-yield correction in this file: one parameter, applied everywhere, and the surface stops looking like Android.

---

## 4. Nested radii chosen independently

**The tell:** a bar at radius 16 containing a chip at radius 12, both picked because they "look right."

```swift
// Wrong
bar.clipShape(.rect(cornerRadius: 16, style: .continuous))
chip.clipShape(.rect(cornerRadius: 12, style: .continuous))   // inset is 8

// Right — concentric
let inset: CGFloat = 8
bar.clipShape(.rect(cornerRadius: 16, style: .continuous))
chip.clipShape(.rect(cornerRadius: 16 - inset, style: .continuous))
```

Concentric corners share a center. Non-concentric ones produce a visibly uneven gap around the curve while the straight edges stay parallel — subtle individually, and the thing that makes a whole surface feel slightly wrong with no identifiable cause.

---

## 5. Stacking decoration

**The tell:** a surface carrying material *and* a stroke *and* a shadow *and* a gradient *and* a tint.

Apple picks one and stops. A floating panel gets glass and a shadow; it does not also get a 1 pt white border at 30%. A card gets a background fill; it does not also get a shadow. Each layer you add is legible on its own, and the sum reads as effort, which is the opposite of the target.

**The correction is subtractive.** Remove one treatment at a time until something is genuinely lost. Whatever you removed last was the only one earning its place.

---

## 6. Web layout instincts

**The tell:** a centered hero, a symmetric three-column feature grid, a gradient header, a card with a colored left border, an emoji used as an icon.

Native macOS layout is left-aligned, information-dense at the top, and content-first — there is no "above the fold" because there is no scroll-to-convince. A window opens showing the thing the user came for.

**Icons are SF Symbols**, which give you weight matching, optical alignment with adjacent text, hierarchical and palette rendering, and localization. An emoji gives you a color image that ignores every one of those and renders differently on every OS version.

---

## 7. Redesigning what macOS already draws

**The tell:** a custom menu, a custom toolbar, a hand-drawn disabled state, a custom file picker, a bespoke settings-window chrome.

Use `NSMenu`, `NSToolbar`, `NSAlert`, `NSOpenPanel`, and the standard disabled state. A disabled `NSButton` reads as disabled everywhere else on the machine; a hand-authored gray does not, and it stops matching at the next OS release. Put the *reason* in the tooltip — that is the part macOS leaves to you and the part that is usually missing.

---

## 8. Ignoring the four user settings

Dark mode, accent color, Increase Contrast, Reduce Transparency, Reduce Motion. Semantic colors and real materials handle the first four for free — which is most of the argument for them.

**Reduce Motion is the one that needs thought**, because the correct fallback is rarely "no animation." If the animation was carrying information — that the gesture registered, that audio is arriving, that work is in progress — removing it removes the information. The fallback is a coarser version of the same signal, not its absence.

---

## 9. Fixed sizes that break under real conditions

**The tell:** a frame width chosen so the English string fits.

German runs 30–40% longer. Accessibility text sizes scale past any fixed height. The correction is to let the surface size to its content and constrain the *ratio* rather than the absolute — and where a size genuinely must be fixed, say in a comment which condition it was verified against.

---

## 10. Reporting structural verification as visual verification

**The tell:** "Rebuilt and running — the sidebar now goes top to bottom," written after reading frame dumps, never a screenshot.

That is verbatim from a past session. Asked directly whether it had looked, the answer was *"I have not seen it. I've been verifying structurally, not visually… The sidebar-flatness fix in particular was reasoning, not observation."* The instrumentation was real and it caught a genuine double-counted 32 pt band. It still could not see the thing it was describing.

**These are two different claims and only one of them was tested:**

| Claim | Verified by |
|---|---|
| The frame is 260 × 800 at the window's top-left | View-hierarchy dump. Real. |
| It looks right | A screenshot. Nothing else. |

**Screen Recording and Accessibility are granted on this machine** — verified 2026-08-15 by building, launching, and screenshotting a real window. So the honest fallback is no longer "I can't see it": you can, and not looking is now a choice. The loop is in `SKILL.md`, with its two traps — `screencapture` grabs the active Space only, and System Events matches processes by name, so a stale build from another worktree will answer for yours.

**Look at it. Then say which claims came from the screenshot and which came from the code.**

Taste still goes back to Anthony — whether the radius reads too square at real size, whether the glass holds against his wallpaper. Name the doubt specifically. "Done" is not an answer, and neither is a description of something you never rendered.
