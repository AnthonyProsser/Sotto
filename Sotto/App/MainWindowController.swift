//
//  MainWindowController.swift
//  Sotto
//
//  Slice 1. The main window's AppKit half — §10.2, as amended by DECISIONS.md
//  on 2026-08-15.
//

import AppKit
import SwiftUI

/// The `NSWindow` that hosts the main window's SwiftUI content, and the **only**
/// place in Sotto that touches the activation policy.
///
/// `.fullSizeContentView` plus a transparent, title-hidden titlebar leaves the
/// sidebar running edge to edge with the traffic lights over it — the
/// Safari/Finder/Mail shape (DECISIONS.md, 2026-08-15). On macOS 26 the system
/// still creates an `AXToolbar` for `NavigationSplitView`'s sidebar toggle, but
/// no band is drawn; the detail's toolbar (Models) populates that existing
/// toolbar's trailing region, so the detail no longer needs an in-content header
/// strip and the empty titlebar gap above it is gone.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()

    /// Held here rather than in the view so `Cmd+,` can toggle the settings page
    /// from outside SwiftUI, and so the mode and selection the user was on survive
    /// the round trip. "Returns to exactly where you were" is a property of this
    /// object outliving the toggle, not of anything the view does.
    private let state = MainWindowState()

    private init() {
        // First-launch size only; `setFrameAutosaveName` below hands every later
        // launch to the system. macOS publishes no default-window-size metric, so
        // this is a starting proportion for a two-column workspace and nothing more.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        // **Visible, as of Slice 10** (`DECISIONS.md`) — the chat/audio name and
        // date moved off an in-content header strip into the title chrome, with
        // the pin as a toolbar item. This un-hides the half of the 2026-08-15
        // Safari-shape note that hid the title; the transparent titlebar,
        // full-size content, and edge-to-edge sidebar are unchanged, and Safari
        // and Mail show a title in exactly this shape. SwiftUI's
        // `.navigationTitle` / `.navigationSubtitle` on each detail drive it.
        window.titleVisibility = .visible
        window.title = "Sotto"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SottoMainWindow")

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: MainWindowView(state: state))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Opening and closing

    func show() {
        setActivationPolicy(regular: true)
        NSApp.activate()
        moveToActiveScreen()
        window?.makeKeyAndOrderFront(nil)
        Activity.shared.set(.mainWindow, true)
        // The window is usually closed while dictations are being recorded and
        // evicted, so what the list last held is stale by definition.
        AudioLibrary.shared.refresh()
    }

    /// **History…** in the menu bar (§10.1), which is a workspace action: it leaves
    /// settings if settings were up, because the recordings list is what the menu
    /// item names. There is no mode to select any more — Audio is the window.
    func showHistory() {
        state.showingSettings = false
        show()
    }

    /// `Cmd+,` and the menu's **Settings…** both land here. Opening the window when
    /// it is closed opens it *on* the settings page; toggling with it already open
    /// returns to the selection and scroll position the user left.
    func toggleSettings() {
        if window?.isVisible == true {
            state.showingSettings.toggle()
        } else {
            state.showingSettings = true
            show()
        }
    }

    func windowWillClose(_ notification: Notification) {
        setActivationPolicy(regular: false)
        Activity.shared.set(.mainWindow, false)
    }

    /// **The window opens where the user is, not where it was closed** (Anthony,
    /// 2026-09-18). `setFrameAutosaveName` restores the frame onto whichever
    /// display it was last used on, which is the right default for an app you
    /// launch and the wrong one for a menu-bar app summoned from wherever the
    /// pointer already is — **History…** otherwise opens a window on a screen the
    /// user is not looking at, and nothing on the screen they *are* looking at
    /// says anything opened.
    ///
    /// **The mouse is the signal, not `NSScreen.main`.** `main` is the screen
    /// holding the key window, and an `.accessory` app being asked to open its
    /// first one has no key window to read; `NSEvent.mouseLocation` is where the
    /// menu click or the pointer actually is. `main` stays as the fallback for a
    /// pointer parked in the gap between two displays.
    ///
    /// **Nothing moves while the window is already on that screen**, so the
    /// position the user dragged it to survives on one display and on the display
    /// they stayed on. Crossing screens centres it, which is what `window.center()`
    /// does on first launch — the same answer, on the screen being looked at.
    private func moveToActiveScreen() {
        guard let window, let target = Self.activeScreen(), window.screen !== target else { return }
        let bounds = target.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, bounds.width)
        frame.size.height = min(frame.height, bounds.height)
        frame.origin = CGPoint(x: bounds.midX - frame.width / 2, y: bounds.midY - frame.height / 2)
        window.setFrame(window.constrainFrameRect(frame, to: target), display: false)
    }

    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    // MARK: - The activation policy, and the overlay guard

    /// **Nothing else in Sotto may call `setActivationPolicy`.** The flip steals
    /// focus, which is what the main window wants and what the overlay must never
    /// do (§10.2, `rules/input-and-insertion.md` §4). Keeping the call private to
    /// this controller — built now, before there is an overlay to forget it in — is
    /// the guard: slice 9's overlay is a non-activating `NSPanel` and has no reach
    /// into this type.
    private func setActivationPolicy(regular: Bool) {
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
    }

}
