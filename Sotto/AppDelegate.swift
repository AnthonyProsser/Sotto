//
//  AppDelegate.swift
//  Sotto
//
//  Created by Anthony Prosser on 8/15/26.
//

import Cocoa

/// One of AppKit's three jobs in Sotto — the other two are the status item and the
/// `NSWindow`/`NSPanel` objects hosting SwiftUI. Every view is SwiftUI
/// (`DECISIONS.md`, 2026-08-15), and nothing here draws.
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    /// `.accessory` in *will* finish launching, not *did*: set later, macOS has
    /// already put a Dock icon up and takes it away again in front of the user.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        StatusItemController.shared.install()
        EventTap.shared.install()

        // Temporary: show HUD for design testing (2026-08-19)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            HUDPanel.shared.show(.recording(level: 0.6))
        }
    }

    /// Sotto lives in the menu bar; closing the main window is not quitting. Quit is
    /// the panic switch and it is deliberate (§10.5).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Actions

    /// `Cmd+,` from the app menu, and **Settings…** in the menu bar menu. Settings
    /// is a page inside the main window rather than a window of its own, so this
    /// toggles rather than opens — press it again and you are back where you were
    /// (`DECISIONS.md`, 2026-08-15, which supersedes §10.2's "open separately").
    @IBAction func toggleSettings(_ sender: Any?) {
        MainWindowController.shared.toggleSettings()
    }
}
