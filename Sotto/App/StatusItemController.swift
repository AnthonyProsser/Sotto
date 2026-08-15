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
final class StatusItemController {
    static let shared = StatusItemController()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private init() {}

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
        menu.addItem(stub("Microphone", "Input device selection arrives in a later build."))
        menu.addItem(stub("MCPs", "MCP servers arrive in a later build."))

        menu.addItem(.separator())

        menu.addItem(disabled(versionLabel))
        menu.addItem(stub("Check for Updates…", "The updater arrives in a later build."))
        menu.addItem(
            action("Quit", #selector(NSApplication.terminate(_:)), key: "q")
        )

        return menu
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
