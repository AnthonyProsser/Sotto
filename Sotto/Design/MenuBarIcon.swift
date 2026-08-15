//
//  MenuBarIcon.swift
//  Sotto
//
//  Slice 1. Decision 03, locked in Design.pdf and transcribed to
//  sotto-tokens.md §6.3. Converts here.
//

import AppKit

/// The two menu bar states, drawn rather than shipped as assets so the locked
/// §6.3 measurements stay readable next to the drawing that consumes them.
///
/// **One capsule, not two.** The app icon is two capsules forming an S; this is
/// not a shrunken version of it. Outline-to-fill reads as the bar going live,
/// which is a better idea at 18 pt than a wordmark nobody can resolve.
///
/// **Both are template images**, so menu bar tint, Reduce Transparency, and high
/// contrast are the system's problem and not Sotto's (§14.8).
enum MenuBarIcon {
    static let idle = capsule(filled: false)
    static let notIdle = capsule(filled: true)

    /// Every literal below is a §6.3 row. The canvas is 18 × 18 pt, the glyph is
    /// 15.6 × 7.2 at r 3.6, and the idle stroke is 1.5 — quoted there as a floor,
    /// not a preference, because thinner disappears against a light menu bar.
    ///
    /// `r 3.6` is exactly half the glyph height, so the shape is a stadium and the
    /// continuous-vs-circular distinction §14.1 polices does not arise: both
    /// constructions produce the same semicircular cap at r = h/2. Any other radius
    /// here would have to go through `Token.shape(radius:)`.
    private static func capsule(filled: Bool) -> NSImage {
        let canvas = NSSize(width: 18, height: 18)
        let glyph = NSSize(width: 15.6, height: 7.2)
        let stroke: CGFloat = 1.5

        let image = NSImage(size: canvas, flipped: false) { _ in
            // A stroke is centred on its path, so the idle state insets by half the
            // width to keep the outer edge at 15.6 × 7.2 and the interior at the
            // 4.2 pt §6.3 quotes. The filled state takes the glyph rect as drawn.
            let inset = filled ? 0 : stroke / 2
            let rect = NSRect(
                x: (canvas.width - glyph.width) / 2 + inset,
                y: (canvas.height - glyph.height) / 2 + inset,
                width: glyph.width - inset * 2,
                height: glyph.height - inset * 2
            )
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            )
            NSColor.black.set()
            if filled {
                path.fill()
            } else {
                path.lineWidth = stroke
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
