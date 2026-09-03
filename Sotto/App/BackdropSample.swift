//
//  BackdropSample.swift
//  Sotto
//
//  Slice 9. What the docked panel's light/dark polarity is keyed to —
//  DECISIONS.md 2026-09-02, Anthony's ruling on the row that had left the
//  panel keyed to the system appearance awaiting exactly this.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// The backdrop luminance behind the docked chat panel, and the polarity
/// decision made from it.
///
/// **Why this exists.** The bare bar is glass and the render server flips it
/// from the pixels behind it every frame; the panel's wash is not glass, so
/// nothing flips it — it sat keyed to the system setting and rendered dark
/// over a white document in Dark Mode. The app cannot read the glass's
/// conclusion (measured 2026-09-02, `rules/design.md` §6.7 — the flip is
/// invisible to every in-process API), so the panel gets the same *input* the
/// glass has by sampling the backdrop itself. `OverlayPanel` turns the result
/// into a window-appearance pin; this file only captures and classifies.
///
/// **The capture is ScreenCaptureKit's one-shot `SCScreenshotManager`, filtered
/// to the panel's display minus every Sotto window** — the wash and the HUD
/// can never sample themselves, and the desktop shows through wherever no
/// window covers. `nil` means no grant or a failed capture; callers fall back
/// to the system appearance, which is the behaviour this replaced.
///
/// **The synchronous `CGWindowListCreateImage` this replaces is obsoleted in
/// the installed SDK** (macOS 26.5 marks it unavailable), and with it went the
/// plan of sampling before the panel orders front. The cost is carried by
/// `OverlayPanel`: the docked panel orders front with its content hidden and
/// reveals on the first pin, so the wrong-polarity flash the sync call used to
/// prevent never renders. The other consequence of the modern API: the filter
/// is *excluding*, not *below-window*, so a window of another app floating
/// above the panel would be captured as if it were backdrop — the panel is
/// `.statusBar` level, so almost nothing qualifies, and the ~1 Hz refresh
/// converges when it goes away.
@MainActor
enum BackdropSample {

    /// Average sRGB luminance (0–1) of the screen region `rect` (global
    /// bottom-left-origin coordinates), or nil without the Screen Recording
    /// grant.
    ///
    /// **Averaged in sRGB on purpose, not lazily** — the window server does its
    /// blur and the glass its polarity flip in gamma-encoded sRGB
    /// (`rules/design.md` §4.3, measured), so the same encoding is what makes
    /// this sample agree with what the glass would have decided over the same
    /// backdrop.
    static func luminance(behind rect: NSRect) async -> CGFloat? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let (filter, configuration) = await capturePlan(for: rect) else { return nil }
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return meanLuminance(of: image)
        } catch {
            // A stale filter (windows opened/closed, display slept) heals by
            // re-enumerating on the next call.
            cachedFilter = nil
            return nil
        }
    }

    /// The polarity ruling: at or above `lightThreshold` the backdrop reads
    /// light and the panel pins aqua.
    static func isLight(_ luminance: CGFloat) -> Bool {
        luminance >= lightThreshold
    }

    /// The sRGB midpoint of the same scale the render server averages in. A
    /// backdrop split half light and half dark resolves to the majority side,
    /// which is the same behaviour the glass has; one edit to change.
    private static let lightThreshold: CGFloat = 0.5

    // MARK: - The capture plan

    private static var cachedFilter: SCContentFilter?
    private static var cachedDisplayID: CGDirectDisplayID = 0
    private static var cachedExclusions: Set<CGWindowID> = []

    /// A display filter for the screen showing `rect`, minus Sotto's own
    /// onscreen windows, plus a configuration cropping it to `rect` at 64×64 —
    /// a mean needs a mean's worth of pixels. The filter is cached across
    /// captures and re-enumerated when the display or the exclusion set
    /// changes; `SCShareableContent` enumeration is the expensive half of a
    /// sample and the ~1 Hz refresh would otherwise repeat it every tick.
    private static func capturePlan(for rect: NSRect) async -> (SCContentFilter, SCStreamConfiguration)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        let source = rect.intersection(screen.frame)
        guard !source.isEmpty else { return nil }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }
        let exclusions = Set(
            content.windows
                .filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
                .map(\.windowID)
        )
        if let cachedFilter, cachedDisplayID == displayID, cachedExclusions == exclusions {
            return (cachedFilter, configuration(for: source))
        }
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { exclusions.contains($0.windowID) })
        cachedFilter = filter
        cachedDisplayID = displayID
        cachedExclusions = exclusions
        return (filter, configuration(for: source))
    }

    private static func configuration(for source: CGRect) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Display-local, top-left origin — the frame ScreenCaptureKit expects.
        config.sourceRect = source
        config.width = 64
        config.height = 64
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 0
        return config
    }

    // MARK: - The ruling

    /// Downsamples to 32×32 and averages the three channels — the mean of a
    /// mean, which is all a polarity decision needs.
    static func meanLuminance(of image: CGImage) -> CGFloat? {
        let side = 32
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var total = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            total += Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])
        }
        return CGFloat(total) / CGFloat(side * side * 3 * 255)
    }

    // MARK: - The grant

    /// Same deferred-permission pattern as §5.6's screenshot gesture: the ask
    /// happens once, at the first docked open, and never while the bare bar is
    /// showing. Fire-and-forget — the TCC dialog is the system's own UI, and
    /// until the grant lands `luminance` returns nil and the panel falls back
    /// to the system appearance.
    static func requestAccessIfNeeded() {
        guard !accessRequested, !CGPreflightScreenCaptureAccess() else { return }
        accessRequested = true
        _ = CGRequestScreenCaptureAccess()
    }

    private static var accessRequested = false
}
