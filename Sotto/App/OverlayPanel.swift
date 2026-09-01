//
//  OverlayPanel.swift
//  Sotto
//
//  Slice 9, stage 1. The window the overlay lives in — one of AppKit's three
//  jobs.
//

import AppKit
import SwiftUI

/// A key-but-non-activating panel hosting `OverlayView`.
///
/// **This is the Spotlight pattern, and it is the one thing that has to be right
/// before anything else in the slice is built on it.** `HUDPanel` is the shape to
/// follow, with two deliberate inversions:
///
/// - **It takes mouse events.** The HUD has no controls; this is nothing but
///   controls.
/// - **It becomes key.** A borderless `NSPanel` refuses key by default, and a
///   panel that never becomes key cannot receive typed text — the field would
///   draw, the caret would not blink, and every keystroke would go to whatever
///   the user was in before. `.nonactivatingPanel` plus `canBecomeKey` is what
///   gives keyboard focus without going through the app the user was in.
///
/// **It must never flip the activation policy** (§10.2, `rules/input-and-insertion.md`
/// §4). Only the main window does that. Nothing here calls
/// `setActivationPolicy`, and nothing later in this slice may either — the
/// transition steals focus from the app the user is typing into, which is the
/// whole failure the overlay exists to avoid.
@MainActor
final class OverlayPanel {
    static let shared = OverlayPanel()

    /// **Gap 2, the overlay half, resolved as a rule rather than a value.** The
    /// bar's bottom edge sits this far above the bottom of
    /// `NSScreen.visibleFrame`.
    ///
    /// `visibleFrame` already subtracts the Dock on whichever edge it occupies,
    /// which is exactly the decomposition `rules/open-questions.md` predicted —
    /// "clears the Dock's current height by N pt" — with the Dock's height read
    /// from the system instead of assumed at 84. It also answers the two cases
    /// the decomposition did not cover, for free and without a branch: a Dock on
    /// the left or right subtracts nothing from the bottom, so the bar drops to
    /// the same clearance above the screen edge, and an auto-hidden Dock leaves
    /// only its few-point reveal strip, so the bar sits low until the Dock comes
    /// up over it — and the panel is at `.statusBar` level, above the Dock's, so
    /// the bar stays readable when it does.
    ///
    /// 16 pt is the design PDF's number ("16 pt clear of the dock"). The token
    /// sheet's 118 pt decomposes to 34 pt of clearance over an assumed 84 pt
    /// Dock; the two disagree and this takes the newer of them. One edit to
    /// change.
    static let dockClearance: CGFloat = 16

    /// Empty canvas **above** the bar, so the surface can grow without the window
    /// resizing — the same reason `HUDPanel`'s canvas is oversized, with the
    /// asymmetry that growth here is one-directional: the bar's bottom edge is
    /// pinned to the anchor and chips and extra text lines all push upward
    /// (§5.8). There is deliberately no slack below, or the anchor would have to
    /// subtract it back out.
    ///
    /// The canvas is sized once to `OverlayView.maxHeight` and never resized. A
    /// window that grows on every keystroke has to move its origin in the same
    /// frame to keep the bottom edge still, and the two do not always land
    /// together; growing the surface *inside* a fixed window has no such seam,
    /// and the empty part of the canvas is transparent, so it costs nothing on
    /// screen and passes its clicks through.
    private static let topSlack: CGFloat = 24

    /// Room **below** the bar for the drop shadow to paint into. Without it the
    /// SwiftUI `.shadow` extends beyond `contentView` and is clipped by the window
    /// edge, so the shadow reads as cut off (the white-background screenshot that
    /// prompted this). Exponential shadow (y4 r6 + y10 r16 + y18 r32) needs ~40 pt
    /// inclusive of blur, so this is 36 to keep the fade from hard-clipping.
    static let bottomSlack: CGFloat = 36

    /// Side slack, so the glass can bleed its rim and specular edge outside the
    /// bar's own rect without the window clipping them.
    private static let sideSlack: CGFloat = 24

    private var panel: Panel?
    var isVisible: Bool { panel?.isVisible == true }

    private init() {
        // FINDING 2026-08-27: panel stops putting windows on screen after sleep.
        // Cheapest mitigation: rebuild on wake.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.panel = nil }
    }

    // MARK: - Showing

    /// Double-tap Right Option (§5.1). A second double-tap while it is up puts it
    /// away, which is the cheapest way to reach the surface from the keyboard and
    /// leave again; Escape is the documented dismissal (§5.7).
    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    /// Whoever was frontmost when the overlay opened, so `hide()` can hand focus
    /// back. Held **strongly**, not weak — `NSWorkspace.frontmostApplication`
    /// returns an autoreleased instance and the weak slot was nil-ing by the time
    /// `hide()` ran (observed as focus not returning after Esc/double-Option).
    /// Stage 4's retarget needs the same reference for a different reason; one
    /// property, not two.
    private var previousApp: NSRunningApplication?

    func show() {
        let panel = self.panel ?? make()
        // Resize canvas if screen changed since panel was created (§5.8 cap rule).
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let desired = OverlayView.maxHeight(for: screen) + Self.topSlack + Self.bottomSlack
            if abs(panel.frame.height - desired) > 1 {
                var f = panel.frame
                // Keep bottom edge pinned — grow upward.
                f.origin.y -= desired - f.height
                f.size.height = desired
                panel.setFrame(f, display: false)
                panel.contentView?.frame = NSRect(origin: .zero, size: f.size)
            }
        }
        position(panel)
        // Resolve continuity target before showing (§5.3) — use B's resolver name
        // but keep A alias via DraftStore.applyContinuityIfNeeded.
        DraftStore.shared.resolveContinuityIfNeeded()
        previousApp = NSWorkspace.shared.frontmostApplication

        // **Sotto activates, and that is deliberate** (Anthony, 2026-08-27: "I
        // want the text indicator cursor only shown on the bar"). A key
        // `.nonactivatingPanel` takes keystrokes while the app behind still
        // believes it is active, so that app goes on drawing its own blinking
        // insertion point next to ours — two carets, one of which is lying about
        // where the next keystroke lands. Activating makes the other app resign
        // first responder and draw an inactive field, which is the same thing
        // Spotlight does.
        //
        // **This is not the activation-policy flip §10.2 forbids.** Sotto stays
        // `.accessory`; an accessory app has no menu bar, so activating it takes
        // nothing off the screen and adds nothing to it. `setActivationPolicy` is
        // never called here.
        //
        // **`ignoringOtherApps: true`, deprecated but not replaced.** macOS 14's
        // cooperative activation denies a plain `NSApp.activate()` from a
        // background process — measured 2026-08-27, the frontmost app never
        // changed — and there is no non-deprecated call that says "I am the
        // surface the user just summoned with a hotkey." That is the case this
        // parameter exists for.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The caret goes in the field on every show, not just the first — the
        // panel is built once and reused, so first responder does not reset
        // itself between showings (§5.8: the surface is summoned to be typed
        // into).
        Activity.shared.set(.overlay, true)
    }

    func hide() {
        let previous = previousApp
        previousApp = nil
        panel?.orderOut(nil)
        Activity.shared.set(.overlay, false)
        // Always hand focus back. The previous slot is now strong (was weak and
        // nil-ing before the handoff ran), so the app that was frontmost before
        // `show()` is reliably still there. `orderOut` first so the activation
        // does not fight `makeKeyAndOrderFront`. Try the cooperative
        // `activate(from:)` first (denied without it on macOS 14), fall back to
        // `activate(options:)`.
        guard let app = previous, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            // No previous or previous was Sotto — just resign.
            if NSApp.isActive { NSApp.deactivate() }
            return
        }
        DispatchQueue.main.async {
            if !app.activate(from: .current) {
                _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
    }

    // MARK: - The panel

    /// **Escape priority stack §10.4.** Exactly one action fires top-down:
    /// 1 abort gesture (GestureRecognizer), 2 cancel transcription (EventTap),
    /// 3 stop chat generation, 4 close overlay. Slice 13's scrim preempts all four.
    ///
    /// **No global monitor.** The panel is key while it is up, so Escape reaches
    /// it as `cancelOperation(_:)` through the responder chain and is never
    /// swallowed system-wide (§10.4's standing constraint). Items 1-2 live on the
    /// tap; 3-4 live here so priority 3 can be checked before 4 without a second
    /// mechanism.
    private final class Panel: NSPanel {
        /// The whole reason for the subclass. Borderless panels return false, and
        /// false here means no caret and no typing.
        override var canBecomeKey: Bool { true }

        override func cancelOperation(_ sender: Any?) {
            // §10.4 exactly one top-down: scrim preempts, then 1/2 already
            // handled on the tap, then 3/4 here. No global monitor when idle
            // is enforced in EventTap; this handler only runs when the panel
            // is key (spec: "panel cancelOperation is handler when key").
            if EventTap.escapeHandledOnMain {
                EventTap.escapeHandledOnMain = false
                return
            }
            // Scrim preempts all four (§10.4, slice 13).
            // if Scrim.shared.isPresented { Scrim.shared.dismiss(); return }
            // Priority 3: stop chat generation before closing.
            if Activity.shared.active.contains(.generating) {
                Activity.shared.set(.generating, false)
                NotificationCenter.default.post(name: .sottoCancelGeneration, object: nil)
                return
            }
            // Priority 4: close overlay.
            OverlayPanel.shared.hide()
        }

        /// **The caret goes into the composer on every show, not just the first.**
        /// The panel is built once and reused, so first responder does not reset
        /// itself between showings, and a search run straight after
        /// `makeKeyAndOrderFront` races the hosting view's first layout — it
        /// found nothing on a cold show, measured 2026-08-27. `becomeKey` fires
        /// every time and the deferral gives SwiftUI its layout pass.
        override func becomeKey() {
            super.becomeKey()
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = OverlayPanel.textView(in: contentView) else { return }
                makeFirstResponder(field)
            }
        }
    }

    private func make() -> Panel {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let cap = screen.map { OverlayView.maxHeight(for: $0) } ?? 320
        let size = NSSize(
            width: OverlayView.width + Self.sideSlack * 2,
            height: cap + Self.topSlack + Self.bottomSlack
        )
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: size),
            // **Not `.nonactivatingPanel`, as of 2026-08-27.** That flag is
            // what left a second caret blinking in the app behind: it tells the
            // window server to give this panel key input *without* deactivating
            // anyone, so the other app never resigns first responder and goes on
            // drawing an insertion point that no longer receives keystrokes.
            // With it off, `makeKeyAndOrderFront` activates Sotto the ordinary
            // way and the field behind draws inactive. Stage 1's brief named the
            // flag; the caret is the reason it came back off, and Sotto is still
            // `.accessory` either way.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Glass carries its own shading, and the window's shadow would fall from
        // the invisible canvas rather than from the bar inside it.
        panel.hasShadow = false
        // The inversion of `HUDPanel`: this surface is all controls.
        //
        // **Only the bar takes clicks; the canvas around it does not.** The
        // window is non-opaque and the slack is drawn at zero alpha, so the
        // window server routes a click there to whatever is behind — the user
        // keeps their screen while the overlay is up, which is the requirement.
        //
        // **§5.6's seam.** Screenshot mode wants the opposite: a click anywhere
        // outside the bar starts a selection. That is this panel grown to the
        // full screen with an opaque-enough scrim behind the bar, not a second
        // window — the scrim is what makes those pixels hit-testable, and
        // `rules/design.md` §4.3 already owns it. Nothing here needs undoing for
        // it.
        panel.ignoresMouseEvents = false
        // Above the Dock, which the bar deliberately sits close to, and above
        // ordinary floating windows.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: OverlayView())
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        return panel
    }

    /// Centred horizontally on the active screen, `dockClearance` above the
    /// bottom of its `visibleFrame`. Re-run on every show: the active screen
    /// changes, and so does the Dock.
    /// The composer is an `NSTextView` inside an `NSScrollView` inside the
    /// hosting view, and SwiftUI's `@FocusState` does not reach across an
    /// `NSViewRepresentable`, so the responder is found rather than declared.
    static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews {
            if let found = textView(in: child) { return found }
        }
        return nil
    }

    private func position(_ panel: Panel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        // Frame 2: right-docked 560pt wash column; Frame 3: centered bare bar (gap 1 closed).
        let isDocked: Bool = {
            if case .existing = DraftStore.shared.draft.target { return true }
            return false
        }()
        let x: CGFloat = isDocked
            ? screen.visibleFrame.maxX - panel.frame.width // right-docked, no panel edge
            : screen.frame.midX - panel.frame.width / 2 // centered bare bar
        panel.setFrameOrigin(NSPoint(
            x: x,
            y: screen.visibleFrame.minY + Self.dockClearance
        ))
    }
}
