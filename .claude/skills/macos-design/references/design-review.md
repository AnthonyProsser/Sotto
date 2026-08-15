# Design review — five dimensions

**Run this before saying a surface is done.** Each dimension has a mechanical pass, a visual pass, and a judgment pass.

- **Mechanical** — greps and header checks. Run these yourself.
- **Visual** — screenshot it and look. Screen Recording is granted; the loop is in `SKILL.md`. Not optional, and not substitutable with a frame dump.
- **Judgment** — taste. Hand to Anthony with the specific doubt named.

**The failure this ordering exists to prevent** is reporting a mechanical pass as if it were a visual one. They answer different questions.

---

## Pass 0 — the grep

Run first. It catches most of the file in one command.

```bash
rg -n '\.cornerRadius\(|Color\(red:|Color\(hex:|NSColor\(red:|#[0-9A-Fa-f]{6}|\.ultraThinMaterial|\.thinMaterial|\.regularMaterial|NSVisualEffectView|\.blur\(radius:|\.font\(\.system\(size:|UIScreen|GeometryReader' \
  --glob '*.swift'
```

Every hit is either a violation or a decision that needs a comment naming the system value it rejected. There is no third category.

| Hit | Almost always means |
|---|---|
| `.cornerRadius(` | Circular corner. Deprecated. → `.clipShape(.rect(cornerRadius:style:.continuous))` |
| `Color(red:` / hex literal | A semantic color was not looked for → `.secondaryLabelColor` et al. |
| `.ultraThinMaterial` / `NSVisualEffectView` | Hand-rolled glass → `.glassEffect()` / `NSGlassEffectView` |
| `.blur(radius:` | Approximating refraction. It cannot. |
| `.font(.system(size:` | A text style was not looked for → `.callout`, `.body`, `preferredFont(forTextStyle:)` |
| `GeometryReader` | Usually replaceable with `containerRelativeFrame` or an alignment guide |

---

## 1. System deference

**Mechanical:**
- [ ] Pass 0 is clean, or every remaining hit carries a comment naming the rejected system API and why it failed
- [ ] Every standard interaction uses the standard control — `NSMenu`, `NSAlert`, `NSOpenPanel`, `NSToolbar`, the system disabled state
- [ ] No theme struct, no appearance preference, no color-scheme branch that a semantic color would handle

**Judgment (hand over):** is there anything here macOS draws better than we do?

---

## 2. Geometry

**Mechanical:**
- [ ] Every corner is `.continuous` — `style: .continuous` in SwiftUI, `cornerCurve = .continuous` in AppKit
- [ ] Every nested corner is computed as `outer - inset`, or uses `ConcentricRectangle`. No two independently chosen radii on nested surfaces
- [ ] Floating surfaces take the larger macOS 26 chrome radii, not macOS 15 values
- [ ] More than one glass view → they are inside a `GlassEffectContainer` / `NSGlassEffectContainerView`

**Judgment:** does the radius read right at *actual size*? An enlarged mockup lies in both directions — a mark that reads as a logo at 200% can be a knot of ink at 18 pt.

---

## 3. Material and restraint

**Mechanical:**
- [ ] Glass is `.glassEffect()` / `NSGlassEffectView`, never a blur-plus-fill stack
- [ ] Count the treatments on each surface: material, stroke, shadow, gradient, tint. **More than two is a finding.** Name which one you would remove
- [ ] `.glassEffect()` is applied *after* the appearance modifiers it should capture
- [ ] Buttons use `.buttonStyle(.glass)` / `.glassProminent` rather than custom glass

**Judgment:** against a bright busy desktop and a dark one — does it hold? This is the check that cannot be done from code at all.

---

## 4. Adaptation

**Mechanical:**
- [ ] Colors are semantic, so dark mode, accent, and Increase Contrast come free. No `colorScheme` branch that a semantic color would have handled
- [ ] Accent is `controlAccentColor`, never a hex
- [ ] Type derives from a text style, or a fixed size carries a stated reason
- [ ] Every animation has a Reduce Motion fallback, and the fallback is **not "nothing"** where the motion was carrying information
- [ ] No frame sized to fit the English string. Localized strings run 30–40% longer

**Judgment:** run it in German and at the largest accessibility text size.

---

## 5. Honesty of the report

**Mechanical:**
- [ ] **Every claim about appearance is backed by a screenshot you actually rendered and read.** Frame dumps, safe-area insets, and `window.toolbar == nil` verify *geometry*; they are not evidence about how anything looks
- [ ] The screenshot is of the right process — `pgrep -lf` first, because a stale build from another worktree answers to the same name
- [ ] Interactive elements were clicked, not assumed. A sidebar toggle wired to `toggleSidebar(_:)` with no `.sidebar`-behavior item validates, looks right, and does nothing
- [ ] Anything not verified is named as not verified, specifically
- [ ] Roles are named, not values — `surface.raised` → `.controlBackgroundColor`, in the same breath
- [ ] Any new authored value carries its four-part claim: role, first consumer, system value ruled out and why, slice
- [ ] Any decision contradicting the spec is in `DECISIONS.md` **and** said out loud in the reply
- [ ] Build verified with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...`

**The failure this dimension exists to catch:** reporting a surface as finished when what was verified is that it compiles. Those are different claims and only one of them was tested.

---

## Handing the judgment passes over

Not "please check it looks OK." Name the specific thing and the specific doubt:

> Built, compiles, mechanical passes clean. Three things I could not verify and one I am unsure about:
>
> - **Material against a bright desktop** — §14.1 accepts this cost, but this is the first surface where it is real
> - **Radius at actual size** — the chip is at 8 to stay concentric with the bar's 16; it may read too square
> - **German** — the bar sizes to content, but I have not seen it wrap
> - **Unsure:** the shadow may be redundant now that the glass carries an edge. I left it in; removing it is one line.
