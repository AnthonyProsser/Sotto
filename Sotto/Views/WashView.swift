//
//  WashView.swift
//  Sotto
//
//  Slice 9. The chat panel's wash field — "Chat panel light and dark mode.pdf"
//  (2026-09-01), built as one continuous gradient per Anthony's instruction,
//  not the drawing's six stacked blur passes.
//

import AppKit
import SwiftUI

/// Right-docked wash field behind the chat panel — 500 pt wide, reaching the
/// screen's right edge and the window's bottom edge. The field hugs the
/// conversation and composer above it; the parent lays it out, this view only
/// draws.
///
/// **Uniform interior, one narrow gradient band on all four sides** (Anthony,
/// 2026-09-01): the treatment where the text sits is the same throughout — the
/// increase-toward-the-centre plateau read as a visible edge and he did not
/// like it — and the fade to nothing is confined to a band as wide as the
/// field's own edge margin, the same on every side: "let's say it's 20 pixels
/// from the bottom to the chat bar, then there's 20 point padding, all around
/// the panel of gradient until the background, which is all uniform."
///
/// **One scrim, one narrow gradient mask, one very slight blur** (Anthony,
/// 2026-09-01, across two rulings). The full-strength `.hudWindow` blur this
/// field first carried averaged whatever was behind it into gray and erased it
/// into mush — "instead of turning gray, it turns black and there's also less
/// black and also less blurry so I can see a little bit of what's behind" — so
/// it came out and the field became a single tinted scrim, dark a plain black
/// at reduced alpha, light the unchanged white wash. Later the same session he
/// put a blur back at low strength — "introduce a very slight blur to the
/// background of the panel" — so the backdrop still reads through, it is just
/// no longer sharp.
///
/// **"Slight" is a mix, not a smaller radius, because a smaller radius is not
/// on offer.** `.behindWindow` vibrancy exposes no radius control, and all ten
/// AppKit materials blur by the identical amount — measured 2026-09-01, they
/// differ in tint *and in how much backdrop they transmit* (`.hudWindow` 0.58,
/// `.sidebar`/`.toolTip` 0.19), never in radius. At full strength every one of
/// them takes body text to a flat field: local contrast inside the panel falls
/// to SD 1.1 against the backdrop's 60, which is precisely the "erased it into
/// mush" complaint. So the blur is dialled by mixing untouched backdrop back in
/// — `blurMix` is baked into the mask's alpha ceiling rather than into
/// `alphaValue`, for the reason in the next paragraph — and the sharp fraction
/// is what carries the glyph edges that make it read as text.
///
/// That mix also answers the *gray*. The window server blurs in gamma-encoded
/// sRGB, confirmed by measurement: over a 50 % black/white backdrop the panel
/// lands at 93, matching the 94.5 an sRGB-space average predicts and nowhere
/// near the 130 a linear-light one would give. Averaging bright detail in sRGB
/// is what drags it toward a muddy mid-tone, and Sotto cannot correct it inside
/// the vibrancy pass — `CALayer.backgroundFilters` composites against the app's
/// own layer tree, not the window server's, and is a no-op here. Retaining
/// unblurred backdrop restores the brightness the sRGB average removed, by a
/// different mechanism than blurring in linear light and without the Screen
/// Recording grant that owning the blur would cost.
///
/// **Glass was measured, not merely rejected on the rim.** Over pure black
/// `NSGlassEffectView` lifts the field to 27 (`.clear`) or 33 (`.regular`)
/// against the effect view's 15, and it dissolves text just as completely
/// (SD 2.2 / 0.6). It is the wrong instrument for an edgeless dark wash on all
/// three counts, before the specular rim is even argued about.
///
/// **Shaping goes through `NSVisualEffectView.maskImage`, never an ancestor
/// `layer.mask` and never `alphaValue` below 1.** Both of those force the
/// effect view offscreen, and an offscreen `.behindWindow` effect view silently
/// stops sampling the backdrop — no error, no warning, just a crisp backdrop
/// and a flat tint. Measured 2026-09-01 against a striped backdrop: with the
/// old ancestor mask the stripes were pixel-sharp inside the field, so the
/// header's "one very slight blur" described a blur that was not running.
/// `maskImage` takes the same per-pixel alpha and keeps vibrancy alive.
///
/// The mask is a rounded-rect signed-distance field, so the feather stays the
/// same width on all four sides *and around the corners* — which the older
/// separable `fx(x)·fy(y)` product could not do, since its two ramps multiply
/// in the corner quadrant and pinch there.
struct WashView: NSViewRepresentable {
    static let columnWidth: CGFloat = 500
    /// The gradient band's width on each side. Was 20, the field's own edge
    /// margin (the 2026-09-01 uniform-interior ruling, itself a cut down from
    /// the drawing's 90–118 pt plateau feather); Anthony asked the
    /// no-tint→tint change more gradual the same day — "it can continue
    /// increasing another 20 pixels into the chat panel" — so the ramp now
    /// spans 40. One edit to change.
    static let feather: CGFloat = 40
    /// Corner rounding of the wash field (Anthony, 2026-09-01, asked for
    /// rounded corners on the panel). It has to sit comfortably above
    /// `feather`, or the curve falls entirely inside the falloff and reads as
    /// the same soft rectangle it replaced — 72 against a 40 pt band is
    /// legible, anything near 40 is not. One edit to change.
    static let cornerRadius: CGFloat = 72
    /// The superellipse exponent of the corner. 2 is a circular arc, which
    /// `rules/design.md` §4.1 forbids; 4 is the squircle the system's
    /// `.continuous` corners approximate, so the falloff runs parallel to a
    /// native-looking corner rather than across one.
    static let cornerExponent: CGFloat = 4
    /// How much of the field is blurred backdrop; the rest is backdrop left
    /// alone. Applied as the mask's alpha ceiling — see the header for why the
    /// radius itself cannot move, and why `alphaValue` cannot carry this.
    /// Swept against body text 2026-09-01: 0.60 stays readable, 1.00 is the
    /// flat mush, and 0.85–0.92 is the band where the glyphs survive as shapes
    /// without resolving — "I can tell there is text there, just not what
    /// text." One edit to change.
    static let blurMix: CGFloat = 0.88
    /// Dark-mode scrim: black, not the blur's gray, and weaker than the old
    /// material-plus-tint stack (Anthony, 2026-09-01). The scrim takes the mask
    /// at full ceiling, not `blurMix` — the darkening is a ruled value and does
    /// not move when the blur is dialled. One edit to change.
    static let darkScrimAlpha: CGFloat = 0.30
    /// Light-mode wash, still the ruled 0.42 (2026-09-01). It briefly looked
    /// as though light mode needed a much stronger scrim, because over a dark
    /// backdrop the field measured 135 and put `labelColor` at 3.8:1 — but that
    /// was the inert-scrim bug above, not the value. With the scrim actually
    /// compositing, 0.42 gives 182 over a dark backdrop and 237 over a light
    /// one, so dark text clears AA either way and the ruling stands.
    /// One edit to change.
    static let lightScrimAlpha: CGFloat = 0.42

    func makeNSView(context: Context) -> FieldView {
        let view = FieldView()
        view.install()
        return view
    }

    func updateNSView(_ view: FieldView, context: Context) {
        view.resolveTint()
    }

    /// The field: one slight blur, one tinted scrim, one shared alpha mask.
    @MainActor
    final class FieldView: NSView {
        /// Under the scrim — the "very slight blur" ruling in the header.
        /// Effect view rather than glass because the field has no edge for
        /// glass to draw. Held at full `alphaValue`; see the header for why a
        /// lower one would silently switch the blur off.
        private let blur = NSVisualEffectView()
        /// **A sibling view added after `blur`, not a sublayer of this view's
        /// own layer.** As an `addSublayer` the scrim rendered *below* the
        /// effect view's backing layer and was very nearly inert — measured
        /// 2026-09-01, forcing its alpha to 1.0 moved the field only to 152
        /// where an over-composited white would give 255. AppKit owns the
        /// z-order of subview layers, so a hand-added sublayer does not
        /// reliably sit above them; subview order does.
        private let scrim = NSView()
        /// The scrim takes the same alpha image the effect view takes through
        /// `maskImage` — one generated mask, two consumers, so the tint and the
        /// blur can never disagree at an edge.
        private let scrimMask = CALayer()
        /// The size the current mask was generated for, and whether one is
        /// still being computed — both touched on main only.
        private var lastMaskSize: CGSize = .zero
        private var generatingMask = false

        func install() {
            wantsLayer = true
            layer?.masksToBounds = true

            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.translatesAutoresizingMaskIntoConstraints = false
            addSubview(blur)
            NSLayoutConstraint.activate([
                blur.topAnchor.constraint(equalTo: topAnchor),
                blur.bottomAnchor.constraint(equalTo: bottomAnchor),
                blur.leadingAnchor.constraint(equalTo: leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            scrimMask.contentsGravity = .resize
            scrim.wantsLayer = true
            scrim.layer?.mask = scrimMask
            scrim.translatesAutoresizingMaskIntoConstraints = false
            addSubview(scrim, positioned: .above, relativeTo: blur)
            NSLayoutConstraint.activate([
                scrim.topAnchor.constraint(equalTo: topAnchor),
                scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            resolveTint()
        }

        /// The tint is appearance-specific and `CALayer` will not re-resolve a
        /// dynamic colour on its own, so the appearance flip drives it.
        ///
        /// **The appearance it reads is the window's, and the window is pinned
        /// from a backdrop sample** (`OverlayPanel`, `DECISIONS.md`
        /// 2026-09-02): at the docked panel's open Sotto captures the pixels
        /// behind the column and pins the panel's appearance to their average
        /// luminance, refreshed at ~1 Hz while it is visible. That is how this
        /// view tracks the backdrop without sampling it itself —
        /// `effectiveAppearance` resolves to the pin. What has not changed is
        /// the bare bar: its glass still flips in the render server,
        /// unreadable from the app (measured 2026-09-02,
        /// `rules/design.md` §6.7), and the glass composer riding on this wash
        /// needs no branch either, because it samples the wash's own darkened
        /// or lightened field and flips with it.
        func resolveTint() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if dark {
                scrim.layer?.backgroundColor = NSColor(white: 0.0, alpha: WashView.darkScrimAlpha).cgColor
            } else {
                scrim.layer?.backgroundColor = NSColor(white: 1.0, alpha: WashView.lightScrimAlpha).cgColor
            }
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() {
            resolveTint()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrimMask.frame = scrim.bounds
            regenerateMaskIfNeeded()
            CATransaction.commit()
        }

        /// The mask is regenerated when the field's size changes — once per
        /// conversation turn or composer line-wrap, never per frame.
        ///
        /// **Cold vs warm.** With no mask yet (first layout, or the panel
        /// rebuilt after a wake) generation runs synchronously: the docked
        /// panel's first layout happens while it is hidden — it orders front at
        /// alpha 0 and reveals on its first polarity pin — so the cost lands
        /// where nobody sees it and the first visible frame already carries the
        /// feather. Afterwards generation runs on a background queue and the
        /// previous mask holds the frame — stretched by `contentsGravity
        /// .resize` — until the new one lands. The synchronous warm path was
        /// untenable: measured 659 ms for the largest size in a Debug build
        /// (2026-09-02, `WashMaskCostTests`), on the main thread, mid-typing.
        private func regenerateMaskIfNeeded() {
            let size = bounds.size
            if abs(lastMaskSize.width - size.width) < 1,
               abs(lastMaskSize.height - size.height) < 1, scrimMask.contents != nil { return }
            guard !generatingMask else { return } // the completion re-checks below
            let scale = window?.backingScaleFactor ?? 2
            let w = max(Int(size.width * scale), 1)
            let h = max(Int(size.height * scale), 1)
            // The constants are read here, on main — `WashView` is
            // main-actor-isolated through `NSViewRepresentable`, and the
            // background pass below is not.
            let feather = WashView.feather * scale
            let radius = WashView.cornerRadius * scale
            let n = WashView.cornerExponent
            let ceilings = (scrim: CGFloat(1), blur: WashView.blurMix)
            lastMaskSize = size
            generatingMask = true
            let generate = {
                WashView.FieldView.washMasks(
                    width: w, height: h, feather: feather, radius: radius,
                    exponent: n, ceilings: ceilings)
            }
            if scrimMask.contents == nil {
                let pair = generate()
                generatingMask = false
                guard let scrim = pair.scrim, let blur = pair.blur else { return }
                applyMask(scrim: scrim, blur: blur, size: size)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let pair = generate()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.generatingMask = false
                    let current = self.bounds.size
                    if abs(current.width - size.width) < 1, abs(current.height - size.height) < 1 {
                        if let scrim = pair.scrim, let blur = pair.blur {
                            self.applyMask(scrim: scrim, blur: blur, size: size)
                        }
                    } else {
                        // The field grew again while this ran; size to the new
                        // bounds, which dispatches a fresh generation.
                        self.regenerateMaskIfNeeded()
                    }
                }
            }
        }

        private func applyMask(scrim: CGImage, blur: CGImage, size: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrimMask.contents = scrim
            self.blur.maskImage = NSImage(cgImage: blur, size: size)
            CATransaction.commit()
        }

        /// The two mask images — full-strength for the scrim, `blurMix`-capped
        /// for the effect view — from **one pass** over the distance field: the
        /// SDF is identical for both, only the alpha ceiling differs, so the
        /// loop writes both buffers per pixel. Byte-for-byte the same output as
        /// the two-pass loop this replaced (`WashMaskCostTests` proves it).
        ///
        /// A rounded-rect signed-distance field, feathered by `smooth` across
        /// `feather` — one falloff width everywhere, corners included.
        ///
        /// The images are premultiplied RGBA of black pixels at varying alpha
        /// rather than an `alphaOnly` gray: that format is read correctly by
        /// both `CALayer.mask` and `NSVisualEffectView.maskImage`, and the two
        /// consumers here have to agree.
        ///
        /// `exponent` is passed rather than read from `WashView`, because this
        /// is `nonisolated` and `WashView` is main-actor-isolated through
        /// `NSViewRepresentable` — touching it here is a Swift 6 error.
        nonisolated static func washMasks(
            width: Int, height: Int, feather: CGFloat, radius: CGFloat,
            exponent n: CGFloat, ceilings: (scrim: CGFloat, blur: CGFloat)
        ) -> (scrim: CGImage?, blur: CGImage?) {
            let w = CGFloat(width), h = CGFloat(height)
            let f = max(feather, 1)
            let r = max(min(radius, min(w, h) / 2), 0)
            let halfW = w / 2, halfH = h / 2
            let flatW = halfW - r, flatH = halfH - r

            var dataScrim = [UInt8](repeating: 0, count: width * height * 4)
            var dataBlur = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let qy = abs(CGFloat(y) + 0.5 - halfH) - flatH
                for x in 0..<width {
                    let qx = abs(CGFloat(x) + 0.5 - halfW) - flatW
                    // Distance to the rounded rect: the superellipse norm in
                    // the corner quadrant, the nearer straight run elsewhere.
                    let signed: CGFloat = (qx > 0 && qy > 0)
                        ? pow(pow(qx, n) + pow(qy, n), 1 / n) - r
                        : max(qx, qy) - r
                    let s = smooth(-signed / f)
                    let i = (y * width + x) * 4 + 3
                    dataScrim[i] = UInt8((s * ceilings.scrim * 255).rounded())
                    dataBlur[i] = UInt8((s * ceilings.blur * 255).rounded())
                }
            }

            func makeImage(_ data: inout [UInt8]) -> CGImage? {
                var image: CGImage?
                data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                    let ctx = CGContext(
                        data: ptr.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    )
                    image = ctx?.makeImage()
                }
                return image
            }
            return (makeImage(&dataScrim), makeImage(&dataBlur))
        }

        nonisolated private static func smooth(_ t: CGFloat) -> CGFloat {
            let x = max(0, min(t, 1))
            return x * x * (3 - 2 * x)
        }
    }
}
