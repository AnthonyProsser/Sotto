//
//  SettingsToolbar.swift
//  Sotto
//
//  Slice 8 put the Models header into the title bar to close the empty-titlebar
//  gap; this factors that one treatment so every real settings pane wears it the
//  same way, and so the fixes for the doubled "Sotto" title and the clipped
//  header live in one place.
//

import SwiftUI

extension View {
    /// The pane's name in the toolbar's leading (navigation) region, so the
    /// detail's scroll content starts flush under the toolbar with no empty
    /// band above it.
    ///
    /// `.headline`, not `.title2` — the system draws a bordered capsule around a
    /// `.navigation` item on macOS 26 and `.title2` is too tall for it (the
    /// "does not fit in its capsule" report, 2026-09-03). The visible **"Sotto"**
    /// beside it was the `NSWindow.title` leaking past `titleVisibility = .hidden`
    /// through toolbar bridging; `MainWindowController` now clears the window
    /// title so this item is the only title drawn.
    func settingsToolbar(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .navigation) {
                Text(title).font(.headline)
            }
        }
    }
}
