//
//  HUDPanel.swift
//  Sotto
//
//  Slice 3. The window the HUD lives in — one of AppKit's three jobs.
//

import AppKit
import SwiftUI
import os

/// A non-activating panel that hosts `HUDView` and never takes focus.
///
/// **Nothing here draws.** The panel is transparent and oversized; the visible
/// surface is the glass inside it, which is what lets the HUD change width by
/// morphing rather than by resizing a window (`HUDView`).
///
/// **It cannot be clicked.** The build order is explicit that the HUD has no
/// controls at all, so it ignores mouse events outright — a transparent panel
/// that swallowed clicks would put a dead 480 pt rectangle across the top of the
/// user's screen for the whole of every dictation.
///
/// **It must not flip the activation policy** (§10.2). It does not, because it
/// never activates: `.nonactivatingPanel` plus `orderFrontRegardless()`.
@MainActor
final class HUDPanel {
    static let shared = HUDPanel()

    private let log = Logger(subsystem: "com.anthonyprosser.Sotto", category: "hud")

    /// Distance from the top of `NSScreen.frame` — the physical top of the
    /// display, not `visibleFrame`'s top, which moves with the menu bar.
    ///
    /// **A constant, not a percentage and not menu-bar-relative**
    /// (`DECISIONS.md`, 2026-08-18). Anchoring below the menu bar puts the HUD
    /// hard against the screen edge in the one case that motivated the rule —
    /// fullscreen, where there is no menu bar. A percentage is wrong for a
    /// different reason: nothing about the HUD scales with the display, so on a
    /// large screen the same percentage is simply lower down.
    ///
    /// Provisional pending Anthony's ruling. §6.2's 8 % of a 1024 pt display is
    /// 82 pt, about one HUD height lower than this.
    static let topInset: CGFloat = 52

    /// Deliberately wider and taller than any state, so the glass can grow into
    /// it without the window ever resizing. Invisible: the panel has no
    /// background and no shadow of its own.
    private static let canvas = NSSize(width: 480, height: 80)

    private var panel: NSPanel?

    /// **Guarded on inequality, and that is not a micro-optimisation of the level
    /// path** — every level update carries a genuinely new value, so the guard
    /// never fires there. What it catches is the redundant re-assignment: the
    /// reveal at recognition repeats the state the armed window already set, and
    /// `stop()` repeats it again. Each of those would otherwise re-evaluate the
    /// whole body, glass container included, for no change.
    private var state: HUDState = .recording(level: 0) {
        didSet { if state != oldValue { render() } }
    }

    /// Chosen when the HUD appears and not revisited until it has gone away —
    /// a state morph part-way through a showing must not re-pin it, or the
    /// "Copied to clipboard" step becomes the flip the pin exists to prevent.
    ///
    /// It renders on its own rather than leaning on the state write above: a
    /// showing that re-pins the appearance without changing the state would
    /// otherwise keep the old one, which is the bug the equality guard would
    /// introduce if this were left to `state`'s `didSet`.
    private var appearance: ColorScheme = .light {
        didSet { if appearance != oldValue { render() } }
    }
    /// Drives the waveform's display link, and is the reason `hide()` is not just
    /// an `orderOut`. False while the panel is off screen; see `HUDView.running`.
    private var running = false {
        didSet { if running != oldValue { render() } }
    }
    private var host: NSHostingView<HUDView>?
    private var dismissal: DispatchWorkItem?
    private var warmupTeardown: DispatchWorkItem?

    private init() {
        // Wake/sleep invalidation lives here so the panel heals even if
        // AppDelegate's observer is removed. The panel is a singleton, so
        // these tokens live for the process lifetime.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        // Display reconfiguration (dock moved, screen added) transiently empties
        // NSScreen.screens — not a wake, but the same position fallback applies.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private nonisolated func handleWake() {
        // NSWorkspace posts on the main thread, but NotificationCenter
        // delivers on the posting thread — defensively hop. AppKit must
        // stay on main; mirrors AppDelegate's Task { @MainActor }.
        Task { @MainActor in HUDPanel.shared.invalidateForWake(reason: "wake") }
    }
    @objc private nonisolated func handleSleep() {
        Task { @MainActor in HUDPanel.shared.invalidateForWake(reason: "sleep") }
    }
    @objc private nonisolated func handleScreensChanged() {
        // No invalidation — screen set just changed; next position() will
        // re-resolve NSScreen.main. Logged only if position() finds no screen.
    }

    /// Drop the retained panel after the window server has torn it down.
    /// Next gesture rebuilds via `ensurePanel()`. Called from wake/sleep
    /// observers and from `AppDelegate`.
    func invalidateForWake(reason: String = "external") {
        guard let existing = panel else { return }
        log.notice("HUDPanel invalidate reason=\(reason, privacy: .public) windowNumber=\(existing.windowNumber, privacy: .public) isVisible=\(existing.isVisible, privacy: .public)")
        existing.orderOut(nil)
        panel = nil
        host = nil
    }

    /// Window-server reconnect orphans the retained NSPanel: the Swift object
    /// lives but its CGWindowID is invalid, so `orderFrontRegardless` is a
    /// silent no-op (`isVisible` stays false, `windowNumber <= 0`).
    private var isOrphaned: Bool {
        guard let existing = panel else { return false }
        return existing.windowNumber <= 0
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel, existing.windowNumber <= 0 {
            log.notice("HUDPanel rebuild orphan windowNumber=\(existing.windowNumber, privacy: .public) isVisible=\(existing.isVisible, privacy: .public)")
            existing.orderOut(nil)
            panel = nil
            host = nil
        }
        // `isVisible==false` alone is not orphan — panel is normally hidden
        // between dictations — but a retained panel that is *supposed* to be
        // visible and isn't after `orderFront` is the observed failure. The
        // guard is on `windowNumber` which is the invariant that survives that
        // distinction.
        return panel ?? make()
    }

    private func render() { host?.rootView = HUDView(state: state, appearance: appearance, running: running) }

    // MARK: - Showing

    /// **The armed window's half of the show.** Right Cmd is down and nothing is
    /// classified yet, so the surface is put on screen fully transparent: the
    /// window server composites it, the glass rasterises, and the waveform starts
    /// tracking the level — all of it inside the 250 ms the user is holding the
    /// key anyway. `show(_:)` at recognition then has one alpha change left.
    ///
    /// It draws nothing. A press that turns out to be a chord or half a double-tap
    /// orders the panel back out having never been visible.
    func prepare(_ state: HUDState) {
        dismissal?.cancel()
        warmupTeardown?.cancel()
        // Heal orphan before deciding appearance — `isVisible` is false for
        // both "hidden between dictations" and "orphaned after wake"; the
        // windowNumber check inside ensurePanel distinguishes them.
        let resolved = ensurePanel()
        if !resolved.isVisible { appearance = Self.appearanceNow() }
        self.state = state
        running = true
        resolved.alphaValue = 0
        position(resolved)
        resolved.orderFrontRegardless()
        if !resolved.isVisible || resolved.windowNumber <= 0 {
            log.error("HUDPanel prepare orderFront failed isVisible=\(resolved.isVisible, privacy: .public) windowNumber=\(resolved.windowNumber, privacy: .public) windows=\(NSApp.windows.count, privacy: .public)")
        }
    }

    func show(_ state: HUDState) {
        dismissal?.cancel()
        warmupTeardown?.cancel()
        let wasVisible = panel?.isVisible == true
        if !wasVisible { appearance = Self.appearanceNow() }
        self.state = state
        running = true
        let resolved = panel(orderingFront: true)
        // Defensive log — the overnight repro's diagnostic was `count of
        // windows → 0` immediately after orderFront with no exception.
        if !resolved.isVisible || resolved.windowNumber <= 0 {
            log.error("HUDPanel show orderFront failed isVisible=\(resolved.isVisible, privacy: .public) windowNumber=\(resolved.windowNumber, privacy: .public) windows=\(NSApp.windows.count, privacy: .public)")
        }
    }

    /// Build the panel and render it once at launch, so the first gesture pays
    /// for neither. Measured cold, those are the two largest costs on the path to
    /// the HUD appearing: ~107 ms to create the window and start the UI framework,
    /// and ~241 ms for the first render, which is mostly rasterising the glass.
    ///
    /// **Rendered at zero alpha rather than off-screen.** A window placed outside
    /// the display's bounds may never be composited at all, which would warm
    /// nothing; a transparent one on the screen it will really appear on takes the
    /// same path the first gesture does. **Measured 2026-08-24 and it does hold:**
    /// the first order-in costs 141–375 ms, and every order-in after it costs one
    /// display refresh — 8.8 ms, 16.5 ms — with no penalty for the first one having
    /// been transparent. That is what `prepare(_:)` above relies on.
    func warm() {
        // If an orphan survived until warm (e.g. immediate relaunch after
        // wake), heal it rather than returning the orphan.
        if isOrphaned {
            log.notice("HUDPanel warm healing orphan windowNumber=\(self.panel?.windowNumber ?? -999, privacy: .public)")
            self.panel?.orderOut(nil)
            self.panel = nil
            self.host = nil
        }
        guard panel == nil else { return }
        let resolved = panel(orderingFront: false)
        resolved.alphaValue = 0
        position(resolved)
        resolved.orderFrontRegardless()
        // Three frames at 60 Hz — enough for the first composite to happen before
        // the panel goes away again.
        //
        // **Held so a gesture landing inside the window can cancel it.** Arming
        // fires on every Right Cmd press, so a press about half a second after
        // launch reaches `prepare(_:)` while this is still pending, and an
        // uncancellable teardown ordered the panel out from under a live
        // dictation. It also no longer clears `running`: `warm()` never sets it,
        // so the only value it could ever have cleared was a gesture's.
        let teardown = DispatchWorkItem { [weak resolved] in
            resolved?.orderOut(nil)
            resolved?.alphaValue = 1
        }
        warmupTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: teardown)
    }

    /// **The seam, and the part that is not finished.** Anthony asked for the
    /// appearance to be taken from what is *behind* the HUD. Reading that means
    /// sampling the screen, and sampling the screen means the Screen Recording
    /// grant, which `CLAUDE.md` §4 defers to the first screenshot — dictation
    /// would pull that prompt forward to first launch. Put to him 2026-08-19;
    /// until he rules, the pin is taken from the system appearance, which gives
    /// the same two versions and the same hold-once behaviour and costs nothing.
    ///
    /// The mismatch case is real and is the whole of what the sample would buy:
    /// a Dark-mode user typing into a white document gets light-on-light.
    private static func appearanceNow() -> ColorScheme {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    /// Level updates, which arrive about twelve times a second while capture is
    /// running. Separate from `show` because they must not re-pin the appearance,
    /// must not cancel a pending dismissal, and must not disturb a message or
    /// error morph that has already replaced the waveform.
    func level(_ level: Double) {
        guard case .recording = state, panel?.isVisible == true else { return }
        state = .recording(level: level)
    }

    /// Show a terminal message and take the HUD away on its own. The two
    /// completion messages and the error morph all end this way — the HUD has no
    /// dismiss control because nothing in it is worth keeping on screen.
    func show(_ state: HUDState, thenHideAfter delay: TimeInterval) {
        show(state)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        warmupTeardown?.cancel()
        warmupTeardown = nil
        panel?.orderOut(nil)
        running = false
    }

    // MARK: - The panel

    @discardableResult
    private func panel(orderingFront: Bool) -> NSPanel {
        let panel = ensurePanel()
        if orderingFront {
            // Undoes `prepare(_:)`, and is the whole of the reveal when the armed
            // window already put the surface on screen.
            panel.alphaValue = 1
            position(panel)
            // Not `makeKeyAndOrderFront`: the HUD appears while the user is typing
            // into another app, and taking key would move focus out from under
            // them mid-sentence.
            panel.orderFrontRegardless()
        }
        return panel
    }

    private func make() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Glass carries its own shading. A window shadow underneath it is the
        // second treatment §14.3 asks you to justify, and it cannot be — the
        // shadow would fall from the canvas, not from the visible surface.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar, so the HUD is not clipped by it at small top
        // insets, and above ordinary floating windows.
        panel.level = .statusBar
        // `.fullScreenAuxiliary` is what makes the HUD visible over a fullscreen
        // app, and `.canJoinAllSpaces` is what stops it being left behind on the
        // Space the gesture started in. Dictation into a fullscreen editor is a
        // first-class case, so neither is optional.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView(state: state, appearance: appearance, running: running))
        host.frame = NSRect(origin: .zero, size: Self.canvas)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.host = host
        self.panel = panel
        return panel
    }

    /// Centred horizontally on the active screen, `topInset` below its physical
    /// top edge. Re-run on every show: the active screen changes.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            log.error("HUDPanel position no screen NSScreen.main=nil screens.count=\(NSScreen.screens.count, privacy: .public) — panel not positioned, will be off-screen")
            return
        }
        let frame = screen.frame
        // The glass sits centred in the canvas, so the canvas top is half the
        // slack above it.
        let slack = (Self.canvas.height - HUDView.height) / 2
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.canvas.width / 2,
            y: frame.maxY - Self.topInset + slack - Self.canvas.height
        ))
    }
}
