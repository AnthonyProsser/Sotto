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
    /// up over it — and the panel is at `.popUpMenu` level, above the Dock's, so
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

    /// `.fullScreenAuxiliary` makes it show over a full-screen app,
    /// `.canJoinAllSpaces` stops it being stranded on the Space the gesture
    /// fired from, and `.transient` keeps it out of Mission Control and orders
    /// it correctly among auxiliary windows — the HUD's set, verbatim.
    ///
    /// **One constant because it is set twice** — at `make()` and again on
    /// every `show()`, where the re-assertion is what survives a Space change.
    /// Two literals would be the pair that drifts.
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]

    private var panel: Panel?
    var isVisible: Bool { panel?.isVisible == true }

    private init() {
        // FINDING 2026-08-27: panel stops putting windows on screen after sleep.
        // Cheapest mitigation: rebuild on wake.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The observer's queue is .main, so the block is on the main actor.
            MainActor.assumeIsolated {
                self?.panel = nil
                self?.stopPolarityRefresh()
            }
        }
    }

    // MARK: - Showing

    /// Double-tap Right Option (§5.1). A second double-tap while it is up puts it
    /// away, which is the cheapest way to reach the surface from the keyboard and
    /// leave again; Escape is the documented dismissal (§5.7).
    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    /// Retarget while visible (§5.3): docked-vs-centred is a property of the
    /// draft's target, so switching chats in the picker has to move the window
    /// now, not on the next show. No-op when the overlay is down — `show()`
    /// positions anyway.
    func reposition() {
        guard let panel, panel.isVisible else { return }
        position(panel)
        // Retargeting can switch docked↔bare while visible; the polarity pin
        // follows the same property of the target that `position` just used.
        // No hiding here — the panel is already on screen, and a blink on
        // every chat switch would be worse than one tick on the old pin.
        applyBackdropPolarity(to: panel, hidingUntilSampled: false)
    }

    /// Whoever was frontmost when the overlay opened, so `hide()` can hand focus
    /// back. Held **strongly**, not weak — `NSWorkspace.frontmostApplication`
    /// returns an autoreleased instance and the weak slot was nil-ing by the time
    /// `hide()` ran (observed as focus not returning after Esc/double-Option).
    /// Stage 4's retarget needs the same reference for a different reason; one
    /// property, not two.
    private var previousApp: NSRunningApplication?

    func show() {
        // **Heal an orphan before anything reads the panel** — `HUDPanel
        // .ensurePanel`'s guard, for the same reason. A window-server
        // reconnect (wake, a Space change, a display reconfigure) leaves the
        // `NSPanel` object alive with an invalid `CGWindowID`, and every
        // `orderFront` on it is a silent no-op: `isVisible` stays false and
        // nothing appears. `isVisible == false` alone is not the test — the
        // overlay is normally hidden between showings — `windowNumber` is.
        if let existing = self.panel, existing.windowNumber <= 0 {
            existing.orderOut(nil)
            self.panel = nil
        }
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
        // Re-read by the hosted view: it refreshes its cached recent-chat list
        // on this, so every show sees chats created while it was hidden.
        // `onAppear` fires only for the panel's first lifetime — the panel is
        // built once and reused, and `orderOut`/`orderFront` never re-triggers
        // it — which is why the picker stayed empty until the first send.
        NotificationCenter.default.post(name: .sottoOverlayDidShow, object: nil)
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
        // **Re-asserted on every show, not just at `make()`** — the other half
        // of the HUD's `2b6ef70` fix (`HUDPanel.panel(orderingFront:)`). A panel
        // that has survived a Space change or a wake can come back without its
        // auxiliary status, and a level or collection behaviour set once at
        // construction is exactly what goes stale; re-stating them costs two
        // assignments and is what keeps the surface over a full-screen app for
        // the second and every later showing rather than only the first.
        panel.level = .popUpMenu
        panel.collectionBehavior = Self.collectionBehavior
        panel.makeKeyAndOrderFront(nil)
        // **Full-screen Spaces.** A plain order-front is clipped to the app's own
        // Space, and `.statusBar` level did not reliably sit above a full-screen
        // app's window ordering — the same finding `HUDPanel` records. The fix is
        // the HUD's, from commit `2b6ef70`: `.popUpMenu` level plus
        // `orderFrontRegardless()` (with the retry the HUD also carries for the
        // window-server-returns-nothing case). The overlay additionally becomes
        // key here, which the HUD never does, so `makeKeyAndOrderFront` stays and
        // this follows it.
        panel.orderFrontRegardless()
        if !panel.isVisible || panel.windowNumber <= 0 {
            panel.orderFrontRegardless()
        }
        // The caret goes in the field on every show, not just the first — the
        // panel is built once and reused, so first responder does not reset
        // itself between showings (§5.8: the surface is summoned to be typed
        // into).
        Activity.shared.set(.overlay, true)
        // Docked: hidden until the backdrop sample pins the polarity, so the
        // first visible frame already carries it — sampling a visible panel
        // too late would flash the system polarity for a frame or two (the
        // polarity MARK below).
        applyBackdropPolarity(to: panel, hidingUntilSampled: true)
        // The docked panel lands on its newest turn — posted on every show
        // because re-showing onto an already-docked chat does not remount the
        // conversation view (`ConversationView.onReceive`).
        NotificationCenter.default.post(name: .sottoOverlayDidShow, object: nil)
    }

    func hide() {
        // Flush the draft before the surface goes away — saves coalesce, and
        // hide is the boundary where the user expects every keystroke kept.
        DraftStore.shared.forceSave()
        let previous = previousApp
        previousApp = nil
        panel?.orderOut(nil)
        // Lift the window-wide polarity pin — the bare state is never governed
        // by it, and a pin held across showings would freeze what the glass is
        // free to flip.
        stopPolarityRefresh()
        panel?.appearance = nil
        Activity.shared.set(.overlay, false)
        // Put the user back where they were — but only if they are still here.
        // If they clicked into something else while the overlay was up, that is
        // now their focus, and yanking it back would be the theft this surface
        // exists to avoid (Anthony's conflict ruling: finish-slice-9-overlay's
        // hide wins). The reference is still held strongly — the weak slot was
        // observed nil-ing before the handoff ran. `activate(from:)` rather than
        // the bare `activate()` for the mirror of the reason `show()` needs
        // `ignoringOtherApps:` — Sotto is the active app here, so this is the
        // one call allowed to give focus away; without it activation falls to
        // the Finder (measured 2026-08-27).
        guard NSApp.isActive else { return }
        if let app = previous, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            if !app.activate(from: .current) {
                _ = app.activate(options: [.activateIgnoringOtherApps])
            }
        } else {
            // No previous, or previous was Sotto — just resign.
            NSApp.deactivate()
        }
    }

    /// **§10.4 priorities 2–4**, dispatched here by the tap's Esc handoff
    /// (`EventTap.handle`). Runs on main. Priority 2 fires wherever the press
    /// happened — dictation is system-wide, so an Escape in another app still
    /// cancels an in-flight transcription. 3 and 4 only while Sotto is
    /// frontmost: an Escape inside another app is that app's, and must not stop
    /// a chat or close this overlay. When the panel is key its `cancelOperation`
    /// has already stood down, so this is the one runner either way.
    func escRemainderFromTap() {
        if Dictation.shared.cancelTranscription() { return }
        guard NSApp.isActive else { return }
        // Scrim preempts all four (§10.4, slice 13).
        // if Scrim.shared.isPresented { Scrim.shared.dismiss(); return }
        // Priority 3: stop chat generation before closing.
        if Activity.shared.active.contains(.generating) {
            Activity.shared.set(.generating, false)
            NotificationCenter.default.post(name: .sottoCancelGeneration, object: nil)
            return
        }
        // Priority 4: close overlay — only if it is up. `hide()` hands focus
        // back to `previousApp`, which must not run for a press that arrived
        // while the overlay was down.
        guard panel?.isVisible == true else { return }
        hide()
    }

    // MARK: - Backdrop polarity

    /// **The docked panel's light/dark follows the backdrop, not the system
    /// setting** (Anthony, 2026-09-02, `DECISIONS.md`). The bare bar is glass,
    /// and the render server flips it from the pixels behind it; the wash is
    /// not glass, so nothing flipped it — it read `effectiveAppearance` and
    /// rendered dark over a white document in Dark Mode. The fix gives the
    /// panel the glass's *input*: `BackdropSample` captures what is behind the
    /// column, and the window's appearance is pinned to the result, which
    /// drives the wash's scrim, the conversation's semantic colours, and the
    /// specular rim from one seam. The glass composer riding on the wash needs
    /// no branch of its own — it samples the wash's darkened or lightened
    /// field and flips with it.
    ///
    /// **The bare state is never pinned.** The pin is a window-wide property
    /// and the bare bar deliberately has no light/dark branch (OverlayView
    /// header) — pinning it would freeze what the glass is free to flip, so
    /// every path that leaves the docked state unpins.
    ///
    /// **The capture is async and the show path hides the panel until its
    /// first pin lands.** The synchronous one-shot that could have sampled
    /// before ordering front (`CGWindowListCreateImage`) is obsoleted in the
    /// installed SDK; ordering front invisible costs the same — the surface
    /// appears a capture's width later, key and typeable the whole time — and
    /// the wrong-polarity flash never renders. A capture that stalls reveals
    /// anyway after 1.5 s. **The Screen Recording grant is requested once, at
    /// the first docked open** — the same deferred-to-first-use pattern as
    /// §5.6's screenshot. An ungranted machine gets nil samples and falls back
    /// to the system appearance, which is the behaviour this replaced.

    private var isDocked: Bool {
        if case .existing = DraftStore.shared.draft.target { return true }
        return false
    }

    private var polarityTimer: Timer?
    private var sampleInFlight = false

    /// **The show is hiding the panel until a sample lands, and it is a
    /// property of the showing rather than of the sample.** It was a parameter
    /// carried into the capture's completion, which is what let a docked
    /// overlay come back invisible: a capture still running from the previous
    /// showing carries that showing's `reveal: false`, the in-flight guard
    /// below returned before the insurance timer was scheduled, and the panel
    /// sat at zero alpha with nothing left to raise it. Reading it as state at
    /// completion means whichever sample lands first reveals.
    private var awaitingReveal = false

    /// Sample the backdrop and pin (or lift) the window appearance to match.
    private func applyBackdropPolarity(to target: Panel, hidingUntilSampled: Bool) {
        guard isDocked else {
            target.appearance = nil
            awaitingReveal = false
            target.alphaValue = 1
            stopPolarityRefresh()
            return
        }
        if hidingUntilSampled {
            target.alphaValue = 0
            awaitingReveal = true
            // **Reveal insurance, scheduled before the in-flight guard.** A
            // capture that never lands must not hold the panel invisible:
            // after 1.5 s the system appearance governs and the panel shows —
            // the behaviour this feature replaced. It has to be armed on every
            // hiding show, including the ones that find a sample already
            // running, or that show has no route back to visible at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.awaitingReveal else { return }
                    self.awaitingReveal = false
                    self.sampleInFlight = false
                    target.appearance = nil
                    target.alphaValue = 1
                }
            }
        }
        BackdropSample.requestAccessIfNeeded()
        startPolarityRefresh()
        // One sample at a time: a wedged capture never returns, and an
        // unguarded 1 Hz tick would bury the process in suspended tasks.
        guard !sampleInFlight else { return }
        sampleInFlight = true
        let rect = backdropRect(for: target.frame)
        Task { [weak self] in
            let luminance = await BackdropSample.luminance(behind: rect)
            self?.sampleInFlight = false
            self?.apply(luminance, to: target)
        }
    }

    /// A nil sample leaves the current pin alone — flapping back to the
    /// system setting mid-showing is worse than holding a possibly stale one
    /// for a tick — except at show time, where there is no pin yet and the
    /// system setting governs, as before the sample existed.
    private func apply(_ luminance: CGFloat?, to target: Panel) {
        let reveal = awaitingReveal
        if let luminance {
            let named: NSAppearance.Name = BackdropSample.isLight(luminance) ? .aqua : .darkAqua
            if target.appearance?.name != named {
                target.appearance = NSAppearance(named: named)
            }
        } else if reveal {
            // No grant or failed capture: the system setting governs, as before.
            target.appearance = nil
        }
        if reveal {
            awaitingReveal = false
            target.alphaValue = 1
        }
    }

    /// The docked wash column's rect in screen coordinates — the window frame
    /// narrowed to the column (right-aligned in the canvas) and cut above the
    /// empty top slack. Sampling the full canvas would dilute the average with
    /// backdrop the panel never covers; this is the region it actually
    /// occludes.
    private func backdropRect(for frame: NSRect) -> NSRect {
        let columnWidth = WashView.columnWidth + 20
        let width = min(frame.width, columnWidth)
        return NSRect(
            x: frame.maxX - width,
            y: frame.minY,
            width: width,
            height: frame.height - Self.topSlack
        )
    }

    private func startPolarityRefresh() {
        guard polarityTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // The timer was added to the main run loop from the main actor, so
            // its block really is on the main actor; stating it beats spawning
            // a Task per tick.
            MainActor.assumeIsolated {
                self?.refreshPolarity()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        polarityTimer = timer
    }

    private func stopPolarityRefresh() {
        polarityTimer?.invalidate()
        polarityTimer = nil
    }

    /// One backdrop re-check per tick. The docked panel is stationary, so the
    /// backdrop only changes when the user moves or scrolls windows under it —
    /// nothing Sotto can observe — hence the poll rather than an observer. The
    /// timer ends itself the moment the docked state does.
    private func refreshPolarity() {
        guard let panel, panel.isVisible, isDocked else {
            stopPolarityRefresh()
            return
        }
        applyBackdropPolarity(to: panel, hidingUntilSampled: false)
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
            // §10.4 exactly one top-down. 1 runs on the tap; 2–4 run from the
            // tap's main-queue block (`escRemainderFromTap`), which the tap
            // dispatches for every Esc it did not abort. Every Esc the tap sees
            // is therefore marked before it is delivered, and this handler —
            // which only runs while the panel is key — has nothing of its own
            // to do: consuming the mark is the whole job. An unmarked Esc here
            // means the press bypassed the tap; doing nothing keeps exactly-one
            // honest (the mark's doc comment has the cases).
            if EventTap.shared.consumeEscapeHandled() { return }
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
        // **`.popUpMenu` (101), not `.statusBar` (25)** — the overlay has to be
        // visible over a full-screen app the same way the HUD is, and `.statusBar`
        // "was not reliably above a full-screen Space's window ordering"
        // (`HUDPanel`, commit `2b6ef70`). Still above the Dock, which the bar sits
        // close to, and still below `.screenSaver` (1000).
        panel.level = .popUpMenu
        panel.collectionBehavior = Self.collectionBehavior

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
        let x: CGFloat = isDocked
            ? screen.visibleFrame.maxX - panel.frame.width // right-docked, no panel edge
            : screen.frame.midX - panel.frame.width / 2 // centered bare bar
        panel.setFrameOrigin(NSPoint(
            x: x,
            y: screen.visibleFrame.minY + Self.dockClearance
        ))
    }
}

extension Notification.Name {
    /// Posted on main from `OverlayPanel.show()` after continuity resolves and
    /// before the panel orders front. The hosted `OverlayView` is built once
    /// and reused, so its `onAppear` runs a single time per process lifetime;
    /// this is the per-show signal it refreshes its cached recent-chat list on.
    static let sottoOverlayDidShow = Notification.Name("SottoOverlayDidShow")
}
