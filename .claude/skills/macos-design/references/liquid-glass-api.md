# Liquid Glass — the verified API surface

**Verified against Apple's developer documentation, snapshot 2026-05-30.** These APIs shipped with the 2025/2026 releases and postdate common training data, which is why the failure mode is not "forgot the API" but "confidently wrote an adjacent name that does not exist."

**Names that do not exist and will not compile:** `glassBackgroundEffect` (that is visionOS), `NSGlassView`, `.glassMaterial`, `.liquidGlass()`, `NSLiquidGlassView`, `GlassContainer`. If you are unsure, check here rather than recalling.

---

## SwiftUI

### Applying glass

```swift
.glassEffect()                                    // .regular variant, Capsule shape
.glassEffect(in: .rect(cornerRadius: 16.0))       // explicit shape
.glassEffect(.regular.tint(.orange).interactive())
```

`glassEffect(_:in:)` defaults to the `regular` variant of `Glass` and applies the effect within a `Capsule` behind the view's content.

**Apply it *after* the modifiers that affect the view's appearance.** The modifier captures the content to send to the container for rendering, so ordering is load-bearing rather than stylistic.

### Containers — required for more than one glass view

```swift
GlassEffectContainer(spacing: 40.0) {
    HStack(spacing: 40.0) {
        Image(systemName: "pencil").frame(width: 80, height: 80).glassEffect()
        Image(systemName: "eraser").frame(width: 80, height: 80).glassEffect()
    }
}
```

A container does two things: it optimizes rendering across multiple glass views, and it lets their shapes blend and morph into each other. **Multiple `.glassEffect()` views outside a container is a performance bug and a visual one** — they cannot blend.

### Morphing and unions

```swift
.glassEffectID("pencil", in: namespace)      // coordinates transitions within a container
.glassEffectTransition(_:)                   // GlassEffectTransition; default is .matchedGeometry
.glassEffectUnion(id:namespace:)             // several views contribute to one effect capsule at rest
```

`glassEffectID(_:in:)` and `glassEffectTransition(_:)` only affect their content **during view hierarchy transitions or animations** — they do nothing at rest. Morphing occurs when views are within the container's `spacing` of each other, so the container's spacing value is what tunes the morph distance.

`glassEffectUnion(id:namespace:)` is the one to reach for when views are created dynamically or live outside a single `HStack`/`VStack` and should still read as one piece of glass.

### Button styles — prefer these to custom glass

```swift
.buttonStyle(.glass)
.buttonStyle(.glassProminent)
```

Also available: `glass(_:)`, `glass()`, `prominentGlass()`, `clearGlass()`, `prominentClearGlass()`.

**Adopt the style rather than building a glass button.** It gets the interaction behaviour — the morph into menus and popovers, the pressed-state response — that a hand-built one will not.

### Shapes and corners

```swift
ConcentricRectangle()              // matches the container's / display's own corner
.rect(corners:isUniform:)
cornerConfiguration                // per-corner configuration
```

`ConcentricRectangle` is the correct choice where a surface should nest inside another rounded surface or match the display corner — it computes the concentric radius for you instead of you subtracting the inset by hand.

### Background extension

```swift
.backgroundExtensionEffect()
```

Extends content (typically an image) under an adjacent sidebar or inspector. Apply it to the image; add overlays **after** the modifier so only the image extends underneath.

---

## AppKit

AppKit's surface is deliberately thinner than SwiftUI's. This is the substance of Sotto's spec §12 open issue 2 — if floating surfaces want the full effect vocabulary, they go SwiftUI inside an `NSPanel`, and every design role then needs both a `Color` and an `NSColor` form.

### `NSGlassEffectView`

> A view that embeds its content view in a dynamic glass effect.

| Property | Meaning |
|---|---|
| `var contentView: NSView?` | The view to embed in glass |
| `var cornerRadius: CGFloat` | Curvature for all corners of the glass |
| `var style: NSGlassEffectView.Style` | The style of glass this view uses |
| `var tintColor: NSColor?` | Color the glass tints its background and effect toward |

Inherits from `NSView`.

### `NSGlassEffectContainerView`

The AppKit counterpart to `GlassEffectContainer`. Same rule: more than one glass view belongs in a container.

### `NSBackgroundExtensionView`

Holds a `contentView` that it extends to fill itself — the AppKit form of `backgroundExtensionEffect()`.

### `NSButton.BezelStyle.glass`

The glass bezel for AppKit buttons. Prefer it to a custom-drawn glass button, for the same reason as SwiftUI.

### Continuous corners in AppKit

```swift
view.wantsLayer = true
view.layer?.cornerCurve = .continuous
view.layer?.cornerRadius = 16
```

`cornerCurve` is the whole difference between native and not. Setting `cornerRadius` alone gives you a circular arc.

---

## What the material actually provides

Stated explicitly because it is the argument against every approximation:

- **Adaptive tint** sampled from the content behind the surface — changes as what is behind it changes
- **Specular highlight** along the lit edge
- **Refraction** at the rim
- **The user's Clear/Tinted choice** from System Settings, applied with no preference to read and no branch to write

Blur plus a flat fill provides none of these, and no number of additional layers produces them. This is the single reason a macOS 26 deployment target is worth its cost.

---

## Windows and controls on macOS 26

- Windows adopt **rounder corners** so controls and navigation nestle into them. This is why floating surfaces take larger radii than you would have picked in macOS 15.
- **The shape of the hardware informs the curvature of controls** — which is what `ConcentricRectangle` exists to express.
- Controls gain an **extra-large size** option, giving more room for labels and accents.
- **Use standard split views** for fluid resizing; they reflow content per size with system transitions that a custom implementation will not match.
- Sliders and toggles: **the knob transforms into Liquid Glass during interaction.** Buttons morph fluidly into menus and popovers. Getting this free is most of the argument for standard controls.

---

## App icons

Layered, composed in **Icon Composer** (ships with Xcode; also on Apple Design Resources). The system applies reflection, refraction, shadow, blur, and highlights to the layers, and derives Default, Dark, Clear, and Tinted from them.

Design constraints that follow:

- Solid, filled, **overlapping semi-transparent shapes**. Simple.
- **Do not bake in** masking, blurring, shadow, or highlights — the system applies them, and a baked-in effect double-applies.
- Split the design into foreground / middle / background layers in your design app, then export those layers.
- The system masks to a rounded rectangle on macOS. **Keep elements centered** to avoid clipping, and check against the updated grids.
- It must survive being stripped of color and still read as a silhouette, because Tinted and Clear do exactly that.
