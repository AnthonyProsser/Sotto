//
//  AppDelegate.swift
//  Sotto
//
//  Created by Anthony Prosser on 8/15/26.
//

import Cocoa
import CoreAudio

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
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCInjectBundleInto"] == nil,
              NSClassFromString("XCTestCase") == nil else {
            return
        }
        StatusItemController.shared.install()
        EventTap.shared.install()
        // Resolves the locale, claims it with `AssetInventory.reserve`, and caches
        // the analyzer's audio format — all of it before the first gesture, so
        // that starting a recording costs no `await`.
        Dictation.shared.prepare()
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

    /// The Microphone submenu (§4.8). `representedObject` is `nil` for the system
    /// default, which is also the stored default — a specific device is only
    /// remembered once the user has asked for one.
    @IBAction func selectMicrophone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else {
            AudioCapture.shared.selectedDevice = nil
            return
        }
        AudioCapture.shared.selectedDevice = AudioCapture.inputDevices().first { $0.id == id }
    }

    /// `Cmd+,` from the app menu, and **Settings…** in the menu bar menu. Settings
    /// is a page inside the main window rather than a window of its own, so this
    /// toggles rather than opens — press it again and you are back where you were
    /// (`DECISIONS.md`, 2026-08-15, which supersedes §10.2's "open separately").
    @IBAction func toggleSettings(_ sender: Any?) {
        MainWindowController.shared.toggleSettings()
    }

    /// **History…** in the menu bar (§10.1). Opens the main window on the Audio
    /// mode — §10.2's workspace, not a quick switch.
    @IBAction func showHistory(_ sender: Any?) {
        MainWindowController.shared.show(mode: .audio)
    }
}
