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
    var mode: Mode = .chat
    var showingSettings = false

    var settingsSection: SettingsSection = .general
    var columns: NavigationSplitViewVisibility = .all
}

/// §10.2's two top-level modes. Search is scoped to whichever is active — a
/// blended list would mix two result shapes for no benefit.
enum Mode: CaseIterable, Identifiable {
    case chat, audio

    var id: Self { self }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .audio: "waveform"
        }
    }
}

/// The settings sections, taken from spec §8 rather than invented: §8.4 puts
/// updates "in General", §8.1 owns everything dictation does, §8.2 owns per-model
/// chat settings, and §6 puts the MCP list in settings because enabling a server
/// is a deliberate act taken there. **§8.5 is why there is no Appearance section**
/// — no mode picker, no theme picker, no tint toggle, all delegated to System
/// Settings.
///
/// **Dictation and Chat are the two scopes §8 opens with**, named for what the
/// user is doing rather than for the mechanism. Profiles are the whole of the
/// dictation scope (§8.1) and appear inside **Dictation** as its profile list;
/// the chat scope has no profile concept at all — per-model overrides are its
/// only shape (§8.2), which is exactly why one section cannot serve both
/// (`DECISIONS.md`, 2026-08-15).
enum SettingsSection: CaseIterable, Identifiable {
    case general, dictation, chat, models, mcp

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .chat: "Chat"
        case .models: "Models"
        case .mcp: "MCPs"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        case .chat: "bubble.left.and.bubble.right"
        case .models: "cube"
        case .mcp: "puzzlepiece.extension"
        }
    }
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    /// Shared rather than owned: the ring can evict a recording while the window
    /// is closed, so the list has to be reloadable from outside any view's
    /// lifetime. `MainWindowController` refreshes it on open.
    @Bindable private var library = AudioLibrary.shared

    /// The Chat twin of `library` — same reload-on-open reason, and its own
    /// `search`, mirroring `AudioLibrary`'s rather than routing through
    /// `MainWindowState` (§10.2's one-field-per-mode rule still holds; the
    /// field just lives on the library each mode already owns).
    @Bindable private var chatLibrary = ChatLibrary.shared

    /// Ties the one selection capsule to whichever segment is current, so the
    /// capsule moves rather than being redrawn in a new place.
    @Namespace private var modeSelection

    /// The selection's position is the information; the slide is not. With Reduce
    /// Motion on, the capsule jumps and the picker still says the same thing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // **The search field is applied here and not inside the mode's list.**
        // `.searchable(placement: .sidebar)` always renders at the top of the
        // sidebar column no matter how deep it is written, so a per-mode field
        // appeared and vanished and the Chat/Audio pill moved underneath it.
        // Scoping is the binding — one field, one text per mode. Settings is a
        // page rather than a mode and has nothing to search.
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
                modePicker
                modeList
            }

            Divider()
            bottomRow
        }
    }

    private var searchText: Binding<String> {
        switch state.mode {
        case .chat: $chatLibrary.search
        case .audio: $library.search
        }
    }

    private var searchPrompt: Text {
        switch state.mode {
        case .chat: Text("Search Chats")
        case .audio: Text("Search Recordings")
        }
    }

    /// The Find My reference: a capsule spanning the sidebar with the selection
    /// drawn as a capsule that **slides** between segments.
    ///
    /// **This is §10.2's custom control after all, and it reverses the
    /// `Picker(.segmented)` decision logged on 2026-08-15** — see `DECISIONS.md`.
    /// The system control was tried first and got close: `.controlSize(.large)`
    /// draws the capsule bezel, and tinting it neutral gets the grey. What it will
    /// not do is keep the selected label light the way Find My does — AppKit picks
    /// the label colour for contrast against the tint, so a light-enough capsule
    /// forces a dark label and the two segments stop reading as one row of text.
    /// That is not reachable through the control's API, which is what moved this
    /// off the system control rather than a preference for hand-rolling.
    ///
    /// **One capsule, moved — not two backgrounds cross-fading.** The whole effect
    /// is a single always-present `Capsule` that adopts the selected segment's
    /// geometry through `matchedGeometryEffect`, so the labels never move and the
    /// capsule is never redrawn somewhere else.
    ///
    /// **Nothing here is authored colour.** The fills are the hierarchical system
    /// styles, which adapt to appearance, accent and increased contrast exactly as
    /// the control's own material would; the type derives from `.body`. The only
    /// authored measures are the two below, both geometry.
    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { mode in
                let selected = state.mode == mode
                Button {
                    state.mode = mode
                } label: {
                    Text(mode.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        // The pill's inner height. macOS publishes no metric for a
                        // label in a capsule, and the control-size ladder is not
                        // reachable outside a control.
                        .padding(.vertical, 6)
                        .contentShape(.capsule)
                        .matchedGeometryEffect(id: mode, in: modeSelection, isSource: true)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // The capsule is never inserted or removed — it exists once and adopts the
        // frame published by whichever segment is current, so its geometry is what
        // changes and SwiftUI interpolates it. Making it conditional inside each
        // segment instead produces a remove-and-insert pair that does not animate.
        .background {
            Capsule()
                .fill(.tertiary)
                .matchedGeometryEffect(id: state.mode, in: modeSelection, isSource: false)
        }
        // `.snappy` unmodified — a system spring preset, so the curve is macOS's
        // rather than a duration and easing pair chosen here.
        .animation(reduceMotion ? nil : .snappy, value: state.mode)
        // The gap between the selection capsule and the well around it — the second
        // authored measure, and the reason the two capsules read as nested rather
        // than as one thick stroke.
        .padding(2)
        .background(Capsule().fill(.quaternary))
        .padding(.horizontal)
        .padding(.bottom)
    }

    /// The recording list is slice 6's; the chat list is slice 10's. **Each
    /// mode owns its own search field** (§10.2) via `searchText`'s per-mode
    /// binding above — `.searchable` itself is applied once, on
    /// `sidebarContent`, because the modifier always renders at the sidebar's
    /// top regardless of how deep it is written (see `sidebar` below).
    @ViewBuilder
    private var modeList: some View {
        switch state.mode {
        case .chat:
            ChatSidebar(library: chatLibrary)
        case .audio:
            AudioSidebar(library: library)
        }
    }

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
            if state.settingsSection == .models {
                ModelsPane()
            } else {
                ContentUnavailableView(
                    state.settingsSection.title,
                    systemImage: state.settingsSection.symbol
                )
            }
        } else {
            switch state.mode {
            case .chat:
                ChatDetail(library: chatLibrary)
            case .audio:
                AudioDetail(library: library)
            }
        }
    }
}
