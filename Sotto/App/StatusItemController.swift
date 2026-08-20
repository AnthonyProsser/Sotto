//
//  StatusItemController.swift
//  Sotto
//
//  Slice 1. The menu bar item and the §10.1 menu.
//

import AppKit

/// The status item, its icon, and the `NSMenu` from §10.1.
///
/// **The menu is a system menu.** Sotto writes the structure; macOS draws it,
/// tints it, handles its keyboard access, and disables it correctly. Nothing here
/// is custom-drawn, and nothing here should become custom-drawn.
///
/// Everything below the first separator except **Settings…** is a stub for a later
/// slice. Stubs are disabled with a tooltip rather than hidden: §14.7 says a
/// control that cannot act takes the system disabled state with the reason in the
/// tooltip, and hiding them would lose the shape of the menu §10.1 specifies.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    /// `NSObject` and `NSMenuDelegate` for one reason: the Microphone submenu is
    /// rebuilt on open, because the device list changes when a headset is plugged
    /// in and a menu built at launch would be stale by the time it is used.
    private let microphones = NSMenu()

    private override init() {}

    func install() {
        item.menu = buildMenu()
        item.button?.image = MenuBarIcon.idle

        Activity.shared.observeIsIdle { [weak self] isIdle in
            self?.item.button?.image = isIdle ? MenuBarIcon.idle : MenuBarIcon.notIdle
        }
    }

    // MARK: - §10.1

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Actions.
        menu.addItem(stub("Toggle Recording", "The dictation gesture arrives in a later build."))

        menu.addItem(.separator())

        menu.addItem(stub("History…", "The audio workspace arrives in a later build."))
        menu.addItem(
            action("Settings…", #selector(AppDelegate.toggleSettings(_:)), key: ",")
        )

        menu.addItem(.separator())

        // Switchable state. Each is a submenu in the shipping app; the submenus have
        // nothing to list until the slice that owns them, so they are stubs with the
        // §10.1 labels intact.
        menu.addItem(stub("Profile", "Profiles arrive in a later build."))
        menu.addItem(stub("Chat Model", "Chat models arrive in a later build."))
        menu.addItem(microphoneItem())
        menu.addItem(stub("MCPs", "MCP servers arrive in a later build."))

        menu.addItem(.separator())

        menu.addItem(disabled(versionLabel))
        menu.addItem(stub("Check for Updates…", "The updater arrives in a later build."))
        menu.addItem(
            action("Quit", #selector(NSApplication.terminate(_:)), key: "q")
        )

        return menu
    }

    // MARK: - Microphone (§4.8)

    /// **The device is Sotto's, not the system's.** §4.8 puts it in the menu bar
    /// rather than in Settings because it changes with headset use rather than
    /// with task, and the menu bar is where the user already is when it changes.
    ///
    /// A selection made mid-recording is held and applied at the next one:
    /// `AudioCapture` pins the device for the length of a gesture, which is the
    /// same rule that stops the system default moving underneath an in-flight
    /// dictation.
    private func microphoneItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphones.delegate = self
        item.submenu = microphones
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === microphones else { return }
        menu.removeAllItems()

        let selected = AudioCapture.shared.selectedDevice
        let systemDefault = NSMenuItem(
            title: "System Default",
            action: #selector(AppDelegate.selectMicrophone(_:)),
            keyEquivalent: ""
        )
        systemDefault.state = selected == nil ? .on : .off
        menu.addItem(systemDefault)
        menu.addItem(.separator())

        for device in AudioCapture.inputDevices() {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(AppDelegate.selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.representedObject = device.id
            item.state = device.id == selected?.id ? .on : .off
            menu.addItem(item)
        }
    }

    /// Quit doubles as the shutdown path (§10.5) — event taps are per-process and
    /// die with the process, so there is no separate disarm state to build.
    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        // `target` stays nil so the item routes through the responder chain, which is
        // what lets Settings… work whether or not the main window is open.
        NSMenuItem(title: title, action: selector, keyEquivalent: key)
    }

    /// A nil action is what disables an item — `NSMenu.autoenablesItems` is on by
    /// default and owns `isEnabled`, so setting it here would be a no-op that reads
    /// like a decision.
    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func stub(_ title: String, _ reason: String) -> NSMenuItem {
        let item = disabled(title)
        item.toolTip = reason
        return item
    }

    private var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Version \(short ?? "—")"
    }
}
