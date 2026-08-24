//
//  HUDPanel.swift
//  Sotto
//
//  Slice 3. The window the HUD lives in — one of AppKit's three jobs.
//

import AppKit
import SwiftUI

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

    private init() {}

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
        if panel?.isVisible != true { appearance = Self.appearanceNow() }
        self.state = state
        let panel = self.panel ?? make()
        running = true
        panel.alphaValue = 0
        position(panel)
        panel.orderFrontRegardless()
    }

    func show(_ state: HUDState) {
        dismissal?.cancel()
        if panel?.isVisible != true { appearance = Self.appearanceNow() }
        self.state = state
        running = true
        panel(orderingFront: true)
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
        guard panel == nil else { return }
        let panel = panel(orderingFront: false)
        panel.alphaValue = 0
        position(panel)
        panel.orderFrontRegardless()
        // Three frames at 60 Hz — enough for the first composite to happen before
        // the panel goes away again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            self?.running = false
        }
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
        panel?.orderOut(nil)
        running = false
    }

    // MARK: - The panel

    @discardableResult
    private func panel(orderingFront: Bool) -> NSPanel {
        let panel = self.panel ?? make()
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
