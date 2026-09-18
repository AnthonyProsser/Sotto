//
//  MainWindowView.swift
//  Sotto
//
//  Slice 1. The main window's SwiftUI half — §10.2, as amended by DECISIONS.md
//  on 2026-08-15.
//

import SwiftUI

/// Everything the window shows, and everything `Cmd+,` has to preserve across a
/// toggle. Owned by `MainWindowController` so it outlives the settings round trip.
@Observable
final class MainWindowState {
    var showingSettings = false

    var settingsSection: SettingsSection = .general
    var columns: NavigationSplitViewVisibility = .all
}

/// The settings sections, taken from spec §8 rather than invented: §8.4 puts
/// updates "in General" and §8.1 owns everything dictation does. Profiles are the
/// whole of the dictation scope (§8.1) and appear inside **Dictation** as its
/// profile list.
///
/// **Chat, Models, MCPs, and Appearance are gone** (Anthony, 2026-09-18,
/// `DECISIONS.md`). The first three were the chat scope §8.2 and §6 opened;
/// Appearance existed for exactly one control — which surface is drawn behind the
/// docked overlay — and went out with the overlay, which restores spec §8.5's
/// original "Appearance — none".
enum SettingsSection: CaseIterable, Identifiable {
    case general, dictation

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        }
    }
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    /// Shared rather than owned: the ring can evict a recording while the window
    /// is closed, so the list has to be reloadable from outside any view's
    /// lifetime. `MainWindowController` refreshes it on open.
    @Bindable private var library = AudioLibrary.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columns) {
            sidebar
                // Unset, `NavigationSplitView` collapses this column to ~140 pt,
                // which truncates the search field's own placeholder — "Search
                // Recordings" is 114 pt of text before the magnifier, the clear
                // button, and the field's insets. There is no system metric for a
                // sidebar width (`rules/design.md` §1), so this is the ordinary
                // layout dimension that rule sends to a local constant: the ideal
                // is the placeholder plus that chrome, the minimum is where it
                // starts to truncate, and the user can still drag it.
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 400)
        } detail: {
            detail
        }
    }

    // MARK: - Sidebar

    /// Runs the full height of the window with the traffic lights over its top-left
    /// corner. SwiftUI insets the sidebar's content below them on its own, and draws
    /// the sidebar toggle at the trailing end of the same strip — so neither the
    /// inset nor the toggle is authored here.
    @ViewBuilder
    private var sidebar: some View {
        // **The search field is applied here and not inside the list.**
        // `.searchable(placement: .sidebar)` always renders at the top of the
        // sidebar column no matter how deep it is written. Settings is a page
        // rather than a mode and has nothing to search.
        if state.showingSettings {
            sidebarContent
        } else {
            sidebarContent
                .searchable(text: searchText, placement: .sidebar, prompt: searchPrompt)
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            if state.showingSettings {
                settingsSections
            } else {
                AudioSidebar(library: library)
            }

            Divider()
            bottomRow
        }
    }

    private var searchText: Binding<String> { $library.search }

    private var searchPrompt: Text { Text("Search Recordings") }

    private var settingsSections: some View {
        List(SettingsSection.allCases, selection: $state.settingsSection) { section in
            Label(section.title, systemImage: section.symbol)
        }
        .listStyle(.sidebar)
    }

    /// **Settings**, or **Back** while the settings page is up (DECISIONS.md,
    /// 2026-08-15). One row, one binding, so the two cannot drift apart.
    private var bottomRow: some View {
        Button {
            state.showingSettings.toggle()
        } label: {
            Label(
                state.showingSettings ? "Back" : "Settings",
                systemImage: state.showingSettings ? "chevron.backward" : "gearshape"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding()
        // No `Cmd+,` here. The app menu owns that key equivalent (§8.3) and routes
        // it through the responder chain, so the shortcut works with the window
        // closed. A second binding on this button would be a second source of truth
        // for one gesture.
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if state.showingSettings {
            switch state.settingsSection {
            case .dictation:
                DictationPane()
            case .general:
                // Still a stub, and honestly so: §8.4's single updates row is the
                // whole of General, and the updater itself is a stub menu item.
                // A pane holding one control that does nothing is worse than one
                // that says there is nothing here yet.
                ContentUnavailableView(
                    state.settingsSection.title,
                    systemImage: state.settingsSection.symbol
                )
                // Every settings pane names the window, or the Audio title (and
                // subtitle) it replaced leaks through.
                .navigationTitle(state.settingsSection.title)
                .navigationSubtitle("")
            }
        } else {
            AudioDetail(library: library)
        }
    }
}
