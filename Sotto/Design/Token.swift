//
//  Token.swift
//  Sotto
//
//  Slice 1. The token layer from sotto-spec.md §14.2 and sotto-tokens.md §0.
//

import SwiftUI

/// The only thing components read. Never `NSColor.controlBackgroundColor` at a
/// call site, never a hex, never a literal — a component names a role and this
/// file decides what the role resolves to. That indirection is the entire point:
/// the inherited-vs-authored boundary stays auditable in one place.
///
/// **A thin mapping, not a runtime system.** There is no theme struct — v0.13
/// required one, v0.14 cut it, and appearance is inherited wholesale from System
/// Settings. Nothing here is stored, observed, or switched at runtime.
///
/// **Two tiers, no third.** Every role tries tier 1 first:
///
/// | Tier | Resolves to |
/// |---|---|
/// | 1. Inherited | An AppKit/SwiftUI semantic color, material, font, or metric. Light/dark, accent, and high-contrast adaptation come free |
/// | 2. Authored | A value Sotto owns because no system value fits |
///
/// Tier 3 existed through v0.17, held `state.error` and `state.network`, and was
/// deleted in v0.18 along with the `state.*` namespace. Do not reintroduce it.
///
/// **A token is authored the first time a feature needs it, and never before.**
/// A value written ahead of its consumer is a guess defended by nothing, and six
/// months later it is indistinguishable from a real decision. That is why this
/// file is nearly empty and why staying nearly empty is success rather than debt.
///
/// **Adding a member is a four-part claim, all four required:** a semantic role
/// name (`surface.raised`, not `gray12`); the first consumer, named in the doc
/// comment; for tier 2, the system value ruled out and what it got wrong; and
/// the slice. Then log the row in `DECISIONS.md` — `docs/sotto-tokens.md` is a
/// read-only copy and cannot be amended here.
///
/// Colors are SwiftUI `Color` and nothing else. Every view in Sotto is SwiftUI;
/// AppKit is confined to the app delegate, the status item, and the window and
/// panel objects that host SwiftUI. One form per role, so two definitions cannot
/// drift (`DECISIONS.md`, 2026-08-15).
enum Token {}

// MARK: - Tier 1 — Inherited

/// Surfaces. Expected source: `NSColor` semantic backgrounds —
/// `.windowBackgroundColor`, `.controlBackgroundColor`,
/// `.selectedContentBackgroundColor`.
///
/// **Empty.** It held `surface.window` for one day, authored for "the settings
/// window"; settings became a page inside the main window the same day, and the
/// shell that shipped in slice 1 names no color at all — the sidebar, the list,
/// the picker, and the empty states are system components that already resolve
/// to the right semantic values. Deleted rather than kept, on Anthony's ruling
/// (`DECISIONS.md`, 2026-08-15): a row without a consumer is the lazy rule's
/// whole target.
extension Token {
    enum Surface {}
}

/// Text. Expected source: `.labelColor`, `.secondaryLabelColor`,
/// `.tertiaryLabelColor` for colour; `NSFont.preferredFont(forTextStyle:)` and
/// its SwiftUI equivalents for type.
///
/// **No colour rows.** Every surface built so far draws its text with
/// `.primary`/`.secondary`, which are the semantic styles under another name and
/// resolve correctly against glass without a branch (`rules/design.md` §6.7). A
/// row would be indirection over an alias.
extension Token {
    enum Text {}
}

extension Token.Text {
    /// `text.transcript` — **first consumer: `TranscriptBody`, slice 6.**
    ///
    /// Tier 1. §14.4 names five type roles and singles this one out: it is the
    /// role that is *not* UI chrome — long-form reading text in the audio
    /// workspace, "tuned for that rather than inherited from `body`."
    ///
    /// **It resolves to `.body` anyway, and the tuning is deliberately not
    /// authored.** §14.4 puts the burden of proof on fixing a size, and there is
    /// no evidence yet for what the tuning should be — that judgement needs a
    /// real transcript read at real size on Anthony's display, which is §8.6's
    /// handoff and not something a build session can settle. The role exists so
    /// that when it is settled there is one place to change it and every word in
    /// the pane follows.
    ///
    /// Rejected: `.title3`, the next style up, which reads as a heading in a pane
    /// that already has one; and a fixed point size, which loses the accessibility
    /// text-size tracking `.body` gets for free.
    static var transcript: Font { .body }
}

/// Borders and separators. Expected source: `.separatorColor`.
/// **Empty** — no surface draws one yet.
extension Token {
    enum Border {}
}

/// Accent. Expected source: `.controlAccentColor`, including the
/// wallpaper-derived "This Mac" accent.
///
/// **The accent is never authored.** Every accent in `Design.pdf` — the send
/// button's `#0A84FF` included — is system blue standing in for
/// `.controlAccentColor`. Reading that hex out of the mockup and writing it into
/// tier 2 is exactly the mistake tier 2 exists to prevent.
///
extension Token {
    enum Accent {}
}

extension Token.Accent {
    /// `accent.primary` — **first consumer: the HUD waveform's bars, slice 3.**
    ///
    /// Tier 1. `.controlAccentColor` follows the user's accent, including the
    /// wallpaper-derived "This Mac" setting, and it is what every system control
    /// that means *this is live right now* already uses. The alternative
    /// considered was `.labelColor`, which is what Control Center gives a glyph
    /// at rest — rejected because a resting glyph and a running capture are not
    /// the same claim, and the waveform is the only confirmation the user gets
    /// that Sotto is hearing them.
    static var primary: Color { Color(nsColor: .controlAccentColor) }
}

/// Materials. Real system materials only, never blur plus a flat fill: Liquid
/// Glass supplies adaptive tint sampled from behind the surface, a specular
/// highlight along the lit edge, and refraction at the rim. Two deliberately
/// different materials arrive later — floating-panel glass for the overlay
/// (slice 9), Control Center–style glass for the HUD (slice 3).
///
extension Token {
    enum Material {}
}

extension Token.Material {
    /// `material.hud` — **first consumer: `HUDView`, slice 3.**
    ///
    /// Tier 1, and one of the two `Glass` cases rather than an authored value.
    ///
    /// **`.clear`, on Anthony's ruling (2026-08-19).** `.regular` shipped first,
    /// on the argument that it is the default and `.clear` is documented for
    /// surfaces over media that guarantees its own contrast. He overruled it on
    /// the renders: `.clear` refracts visibly harder, and the refraction is what
    /// makes the surface read as glass at 36 pt tall rather than as a grey pill.
    /// Legibility is not at risk because the glass adapts to its backdrop —
    /// measured, see `rules/design.md` §6.7.
    ///
    /// **Not `.interactive()`**: that adds the press-and-flex response, and the
    /// HUD has no controls at all.
    static var hud: Glass { .clear }
}

// MARK: - Tier 2 — Authored

/// **Empty, and the shorter this stays the better.** Every authored value is
/// permanent maintenance debt: it silently stops matching macOS on the next
/// release, and the failure is invisible because a stale token looks exactly
/// like a live one.
///
/// Three entries are pre-approved, each with its values already decided and
/// parked in `sotto-tokens.md` §6 until its slice converts them:
///
/// - Waveform bar geometry and resting treatment — slice 3. The one element with
///   no system precedent (§14.3).
/// - `scrim.fill` / `scrim.text` — slice 13. The app's only full-bleed non-glass
///   surface; Sotto draws the wash, so the text sits on a known dark background
///   in both appearance modes — one fixed pair, not a light/dark branch.
/// - Overlay intrusiveness values — slice 9. Width ratio, internal padding,
///   stroke weight, shadow lift, vertical position, density. macOS has no opinion
///   because no system surface is shaped like the overlay.
///
/// A fourth proposal is a signal to look harder at tier 1, not a reason to write
/// the row. If it survives that, make the four-part claim out loud and let
/// Anthony rule on it before it lands here.
extension Token {
    enum Authored {}
}

extension Token.Authored {
    /// `waveform.*` — **first consumer: `Waveform`, slice 3.** The first of the
    /// three pre-approved tier-2 entries, and the one with the strongest case:
    /// macOS ships no waveform. `NSLevelIndicator` is the closest system control
    /// and fails on all three counts — it is a filled gauge rather than a set of
    /// bars, it has no idle treatment other than empty, and it is a control, so
    /// it draws a focus ring and a hit region for a surface that has neither.
    ///
    /// **Every number here is provisional.** `sotto-tokens.md` §6.2 is unlocked
    /// (`DECISIONS.md`, 2026-08-18) and Anthony has not ruled on `peak`; §6.2's
    /// 28 filled 78 % of the surface, and the reference he called calm fills
    /// 42 %. `count` is already settled at eight, down from §6.2's twelve.
    enum Waveform {
        static let count = 8
        static let barWidth: CGFloat = 3.5
        static let barGap: CGFloat = 4.5
        static let peak: CGFloat = 20
        /// Resting height. Equal to the width, so an idle bar is a dot rather
        /// than a gap — §6.2's resting band was 3.5–6.7 and drifting.
        static let resting: CGFloat = 3.5

        /// `waveform.playbackHeight` — **first consumer: `PlaybackWaveform`,
        /// slice 6.** The drawn envelope of a finished recording, which is a
        /// different object from the five values above it: those describe the
        /// live HUD waveform reporting the microphone, this one describes a
        /// static picture of a file you can scrub.
        ///
        /// **Rejected system value: there is none, and it is the same absence
        /// that pre-approved the rows above.** macOS publishes no waveform metric
        /// and no waveform view; `NSLevelIndicator` was already ruled out for the
        /// HUD and fails here for the same reasons plus one more — it shows a
        /// single current value, and this shows a whole recording at once.
        ///
        /// **`barWidth` and `barGap` are reused rather than re-authored**, so the
        /// two waveforms are the same drawing at two sizes and there is one
        /// number here instead of three. Bar *count* is not authored at all: it
        /// falls out of the pane's width, which is what lets the envelope keep
        /// its density when the window is resized.
        ///
        /// 48 is a starting value on the same footing as `peak` above — §6.2 is
        /// unlocked and Anthony has not seen this surface at size.
        static let playbackHeight: CGFloat = 48
    }
}

extension Token.Authored {
    /// `specular.*` — **first consumer: `HUDView`'s rim, slice 3.** The fourth
    /// tier-2 entry and the first not pre-approved by §9. Anthony asked for it by
    /// name against a Control Center reference (2026-08-19).
    ///
    /// **Rejected system value: there is none.** `Glass` has exactly five members
    /// — `.regular`, `.clear`, `.identity`, `.tint(_:)`, `.interactive(_:)` — and
    /// none is a knob on the specular pass; `grep -i specular` across the
    /// installed SDK returns OpenGL, RealityKit, and SpriteKit, nothing in
    /// SwiftUI or AppKit. Real glass draws its own specular edge, but measured on
    /// screen at 36 pt it is not carrying the surface, which is what produced
    /// this row. The nearest semantic value, `.separatorColor`, fails on kind
    /// rather than strength: a separator is one flat colour the whole way round,
    /// and this is a lit bevel.
    ///
    /// **Bright at top-left and bottom-right, dark at top-right and bottom-left**
    /// (Anthony, from the reference). One light source above and to the left; the
    /// rim is brightest where the surface turns to face it, which happens twice
    /// on opposite sides because the far edge catches it again. Hence a period of
    /// 180° rather than one revolution.
    ///
    /// **Not a symmetric white-to-black pair**, which would read as piping. The
    /// dark lobes are weak so the shadow side reads as *unlit* rather than drawn.
    enum Specular {
        /// Hairline. `strokeBorder` insets by half of this and draws inward, so
        /// the rim sits on the glass instead of straddling its edge.
        static let width: CGFloat = 1

        static let highlight = Color.white.opacity(0.5)
        static let shadow = Color.black.opacity(0.12)

        /// SwiftUI's angular gradient starts at 3 o'clock and runs clockwise in a
        /// y-down space: 45° bottom-right, 135° bottom-left, 225° top-left,
        /// 315° top-right. Locations are those angles over 360.
        static var rim: AngularGradient {
            let mid = Color.white.opacity(0.08)
            return AngularGradient(
                stops: [
                    .init(color: mid, location: 0),
                    .init(color: highlight, location: 0.125),   //  45° bottom-right
                    .init(color: shadow, location: 0.375),      // 135° bottom-left
                    .init(color: highlight, location: 0.625),   // 225° top-left
                    .init(color: shadow, location: 0.875),      // 315° top-right
                    .init(color: mid, location: 1),
                ],
                center: .center
            )
        }
    }
}

// MARK: - Geometry

extension Token {
    /// Every rounded corner in Sotto, without exception.
    ///
    /// A circular arc jumps from zero to maximum curvature at a point, and that
    /// seam is most of what makes a rounded rectangle read as Material Design
    /// rather than Apple. `RoundedRectangle(cornerRadius:)` defaults to the
    /// circular arc, which is why no call site should construct one directly
    /// (§14.1).
    ///
    /// Nested corners are concentric: a chip inside the compose bar takes the
    /// bar's radius minus the inset. Where a surface should match the display's
    /// own corner, use `ConcentricRectangle` instead of this.
    ///
    /// The radius is passed in rather than tokenised because no radius has a
    /// consumer yet. `radius.control`, `radius.card`, and `radius.surface` are
    /// named in `sotto-tokens.md` §4 with no values, and whether `radius.surface`
    /// is a number or a ratio of surface height is an open call for slice 9.
    static func shape(radius: CGFloat) -> RoundedRectangle {
        .rect(cornerRadius: radius, style: .continuous)
    }
}
