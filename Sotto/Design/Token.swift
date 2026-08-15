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
extension Token {
    enum Surface {
        /// The settings window's background.
        ///
        /// Tier 1 → `NSColor.windowBackgroundColor`. First consumer: the settings
        /// window, slice 1. Picks up the window-background wallpaper tint macOS 26
        /// applies, which a drawn fill would not.
        static var window: Color { Color(nsColor: .windowBackgroundColor) }
    }
}

/// Text. Expected source: `.labelColor`, `.secondaryLabelColor`,
/// `.tertiaryLabelColor`. **Empty** — no surface draws text yet.
extension Token {
    enum Text {}
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
/// **Empty** — nothing accented is built yet.
extension Token {
    enum Accent {}
}

/// Materials. Real system materials only, never blur plus a flat fill: Liquid
/// Glass supplies adaptive tint sampled from behind the surface, a specular
/// highlight along the lit edge, and refraction at the rim. Two deliberately
/// different materials arrive later — floating-panel glass for the overlay
/// (slice 9), Control Center–style glass for the HUD (slice 3).
///
/// **Empty** — neither surface exists yet.
extension Token {
    enum Material {}
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
