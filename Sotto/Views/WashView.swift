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

/// Right-docked wash field behind the chat panel — 500 pt wide, right edge
/// 20 pt in from the screen edge, bottom edge at the panel anchor (16 pt above
/// `visibleFrame` bottom, the drawn 15 within rounding). The field hugs the
/// conversation and composer above it; the parent lays it out, this view only
/// draws.
///
/// **Uniform interior, one narrow gradient band on all four sides** (Anthony,
/// 2026-09-01): the treatment where the text sits is the same throughout — the
/// increase-toward-the-centre plateau read as a visible edge and he did not
/// like it — and the fade to nothing is confined to a band as wide as the
/// field's own edge margin (~20 pt), the same on every side: "let's say it's
/// 20 pixels from the bottom to the chat bar, then there's 20 point padding,
/// all around the panel of gradient until the background, which is all
/// uniform."
///
/// **One blur, one tint, one gradient mask — no stacked passes.** The drawing
/// specifies six blur passes (2/5/10/18/30/46 pt) each inset further; public
/// AppKit cannot vary a behind-window blur's radius spatially, and Anthony
/// ruled against layered passes anyway: the field is a single strong material
/// whose mask falls to nothing across `feather` on all four sides —
/// alpha(x, y) = fx(x)·fy(y), smoothstep — plus one tint layer under the same
/// mask (light 42 % white, dark 34 % #0A0A0C, appearance-adaptive).
struct WashView: NSViewRepresentable {
    static let columnWidth: CGFloat = 500
    /// The gradient band's width on each side — the field's own edge margin,
    /// per the 2026-09-01 uniform-interior ruling. Was the drawing's 90–118 pt
    /// plateau feather, which put the ramp across a third of the field.
    static let feather: CGFloat = 20

    func makeNSView(context: Context) -> FieldView {
        let view = FieldView()
        view.install(context: context.coordinator)
        return view
    }

    func updateNSView(_ view: FieldView, context: Context) {
        view.resolveTint()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var maskSize: CGSize = .zero }

    /// The field: one material, one tint layer, one shared alpha mask.
    @MainActor
    final class FieldView: NSView {
        private let effect = NSVisualEffectView()
        private let tint = CALayer()
        private let mask = CALayer()
        private var context: Coordinator?

        func install(context: Coordinator) {
            self.context = context
            wantsLayer = true
            layer?.masksToBounds = true

            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.translatesAutoresizingMaskIntoConstraints = false
            addSubview(effect)
            NSLayoutConstraint.activate([
                effect.topAnchor.constraint(equalTo: topAnchor),
                effect.bottomAnchor.constraint(equalTo: bottomAnchor),
                effect.leadingAnchor.constraint(equalTo: leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            tint.frame = bounds
            layer?.addSublayer(tint)

            mask.contentsGravity = .resize
            layer?.mask = mask
            resolveTint()
        }

        /// The tint is appearance-specific and `CALayer` will not re-resolve a
        /// dynamic colour on its own, so the appearance flip drives it.
        func resolveTint() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if dark {
                tint.backgroundColor = NSColor(srgbRed: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0C / 255.0, alpha: 0.34).cgColor
            } else {
                tint.backgroundColor = NSColor(white: 1.0, alpha: 0.42).cgColor
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
            tint.frame = bounds
            // The mask frame must track the field: a zero-frame mask renders
            // no alpha, and the whole field — material and tint — was invisible
            // until this line existed (the "no blur, no darken" report).
            mask.frame = bounds
            regenerateMaskIfNeeded()
            CATransaction.commit()
        }

        /// The mask image is regenerated only when the field's size changes —
        /// the pixel loop is a one-shot cost per layout, not per frame.
        private func regenerateMaskIfNeeded() {
            guard let context else { return }
            let size = bounds.size
            if abs(context.maskSize.width - size.width) < 1,
               abs(context.maskSize.height - size.height) < 1, mask.contents != nil { return }
            context.maskSize = size
            let scale = window?.backingScaleFactor ?? 2
            let w = max(Int(size.width * scale), 1)
            let h = max(Int(size.height * scale), 1)
            let featherPx = WashView.feather * scale
            mask.contents = Self.plateauImage(width: w, height: h, feather: featherPx)
        }

        /// alpha(x, y) = fx(x)·fy(y), each axis a smoothstep from the edge to
        /// full at `feather` inset — the continuous form of the drawing's
        /// outside-in accumulation.
        nonisolated static func plateauImage(width: Int, height: Int, feather: CGFloat) -> CGImage? {
            var data = [UInt8](repeating: 0, count: width * height)
            let f = max(feather, 1)
            let lastX = CGFloat(width - 1)
            let lastY = CGFloat(height - 1)
            for y in 0..<height {
                let gy = smooth(min(min(CGFloat(y), lastY - CGFloat(y)) / f, 1))
                let row = y * width
                for x in 0..<width {
                    let gx = smooth(min(min(CGFloat(x), lastX - CGFloat(x)) / f, 1))
                    data[row + x] = UInt8((gx * gy * 255.0).rounded())
                }
            }
            var image: CGImage?
            data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                let ctx = CGContext(
                    data: ptr.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue)
                )
                image = ctx?.makeImage()
            }
            return image
        }

        nonisolated private static func smooth(_ t: CGFloat) -> CGFloat {
            let x = max(0, min(t, 1))
            return x * x * (3 - 2 * x)
        }
    }
}
